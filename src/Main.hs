{-# LANGUAGE OverloadedStrings, BangPatterns, PatternGuards, ScopedTypeVariables #-}

module Main where

import qualified Aws
import qualified Aws.S3 as S3

import qualified Data.Attoparsec.Text as Atto
import           Control.Applicative
import           Control.Concurrent ( threadDelay )
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import qualified Control.Concurrent.MSem as Sem
import           Control.Concurrent.ParallelIO.Local ( withPool, parallel )
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBQueue
import           Control.Monad ( when, forM, forM_, unless )
import           Control.Monad.IO.Class
import           Control.Exception ( catch, throwIO )
import qualified Data.ByteString.Char8 as B
import           Data.Conduit ( runResourceT, ResourceT )
import           Data.Maybe ( fromMaybe, catMaybes )
import           Data.Monoid
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Text as T
import           Network.HTTP.Conduit ( withManager, Manager,
                                        HttpException(..) )
import           System.Environment
import           System.Exit ( exitFailure )
import           System.IO
import           System.IO.Streams ( InputStream, Generator, yield )
import qualified System.IO.Streams as Streams

import           DateMatch

data Config = Config 
  { cfgAwsCfg     :: !Aws.Configuration
  , cfgS3Cfg      :: !(S3.S3Configuration Aws.NormalQuery)
  , cfgLoggerLock :: !(MVar ())
  , cfgManager    :: !Manager
  , cfgBucketName :: !T.Text
  , cfgReadFileThrottle :: !(Sem.MSem Int)
  }

data Range = Range !DatePattern !DatePattern

msg :: Config -> String -> IO ()
msg Config{ cfgLoggerLock = lock } text =
  withMVar lock (\_ -> hPutStrLn stderr text)

defaultMaxKeys :: Maybe Int
defaultMaxKeys = Just 1000

printUsage :: IO ()
printUsage = do
    hPutStrLn stderr $
      "USAGE: colog s3://BUCKETNAME/LOGROOT/ FROMDATE[/TODATE]"

bucketParser :: Atto.Parser (T.Text, T.Text)
bucketParser = do
  Atto.string "s3://"
  bucketName <- Atto.takeWhile (/= '/')
  Atto.char '/'
  rootPath <- Atto.takeText
  return (bucketName, rootPath)


main :: IO ()
main = do
  access_key <- fromMaybe "" <$> lookupEnv "AWS_ACCESS_KEY"
  secret_key <- fromMaybe "" <$> lookupEnv "AWS_SECRET_KEY"

  args <- getArgs
  when (length args < 3) $ do

  bucketNameAndrootPath : otherArgs <- getArgs

  (bucketName, rootPath)
     <- case (Atto.parseOnly bucketParser (T.pack bucketNameAndrootPath)) of
          Right (b, r) -> return (b, r)
          Left msg -> do
            printUsage
            error "Failed to parse bucket"

  when (any null [access_key, secret_key]) $ do
    putStrLn $ "ERROR: Access key or secret key missing\n" ++
               "Ensure that environment variables AWS_ACCESS_KEY and " ++
               "AWS_SECRET_KEY\nare defined"
    exitFailure

  let awsCfg = Aws.Configuration
                  { Aws.timeInfo = Aws.Timestamp
                  , Aws.credentials =
                      Aws.Credentials (B.pack access_key)
                                      (B.pack secret_key)
                  , Aws.logger = Aws.defaultLog Aws.Warning }

  let s3cfg = Aws.defServiceConfig :: S3.S3Configuration Aws.NormalQuery

  loggerLock <- newMVar ()

  withManager $ \mgr -> liftIO $ do

    throttle <- Sem.new 4

    let cfg = Config { cfgAwsCfg = awsCfg
                     , cfgS3Cfg = s3cfg
                     , cfgLoggerLock = loggerLock
                     , cfgManager = mgr
                     , cfgBucketName = bucketName
                     , cfgReadFileThrottle = throttle
                     }

    let (fromDateText, toDateText)
          | [] <- otherArgs
          = ("2013-03-10T10:10", "2013-03-10T10:14")
          | datePattern : _ <- otherArgs
          = case T.splitOn "/" (T.pack datePattern) of
              [start] -> (start, "")
              start:end:_ -> (start, end)
              _ -> error "splitOn returned empty list"

    let Just fromDate = parseDatePattern fromDateText
        Just toDate   = parseDatePattern toDateText
        range = Range fromDate toDate

    all_servers <- Streams.toList =<< lsS3 cfg rootPath
    let !servers = {- take 10 -} all_servers

    queues <- forM servers $ \server -> do
                q <- newTBQueueIO 1
                worker <- async (processServer cfg server range q)
                return (server, q, worker)

    grabAndDistributeFiles queues

    -- objects <- withPool 4 $ \pool -> parallel pool $
    --              [ Streams.toList =<< lsObjects cfg serverPath range
    --              | serverPath <- servers
    --              ]

    -- mapM_ print objects
    -- print (length (filter (not . null) objects))

grabAndDistributeFiles :: [(S3Path, TBQueue (Maybe S3ObjectKey), Async ())]
                       -> IO ()
grabAndDistributeFiles [] = return ()
grabAndDistributeFiles queues = do
  nextAvailMinutes <- forM queues $ \queue@(_, q, _) -> do
                        mb_minute <- atomically (peekTBQueue q)
                        case mb_minute of
                          Nothing -> return Nothing
                          Just minute ->
                            return (Just (minute, queue))
  let queues' = catMaybes nextAvailMinutes

  unless (null queues') $ do
    let !nextMinute = minimum (map fst queues')
    forM_ [ server | (_, (server, _, _)) <- queues' ] $ \server -> do
      putStrLn $ T.unpack server ++ T.unpack nextMinute
    -- print (nextMinute, [ server | (_, (server, _, _)) <- queues' ])
    queues'' <- forM queues' $ \(minute, queue@(_, q, _)) -> do
                  when (minute == nextMinute) $ do
                    _ <- atomically (readTBQueue q)
                    return ()
                  return queue
    grabAndDistributeFiles queues''

processServer :: Config -> S3Path -> Range -> TBQueue (Maybe S3ObjectKey)
              -> IO ()
processServer cfg serverPath range queue = do
  let !srvLen = T.length serverPath
  keys <- lsObjects cfg serverPath range
  let writeOne key = do
          let !file = T.drop srvLen key
          atomically (writeTBQueue queue (Just file))
  Streams.skipToEof =<< Streams.mapM_ writeOne keys
  atomically (writeTBQueue queue Nothing)

type S3Path = T.Text
type S3ObjectKey = T.Text

lsS3 :: Config -> T.Text -> IO (InputStream T.Text)
lsS3 cfg path = Streams.fromGenerator (chunkedGen (lsS3_ cfg path))

-- | Return a stream of minute file names matching the given date
-- range.  Files are returned in ASCII-betical order.
--
-- The resulting stream is not thread-safe.
lsObjects :: Config
          -> S3Path -- ^ Absolute path of server's log directory
          -> Range  -- ^ Range requested
          -> IO (InputStream S3ObjectKey)
lsObjects cfg serverPath (Range startDate endDate) = do
  keys <- Streams.fromGenerator
    (chunkedGen (matching_ cfg serverPath startDate))
  let !srvLen = T.length serverPath
  let inRange path = isBefore endDate (Date (T.drop srvLen path))
  takeWhileStream inRange keys

--- Internals ----------------------------------------------------------

data Response a
  = Done
  | Full !a
  | More !a (IO (Response a))

runRequest :: Config -> ResourceT IO a -> IO a
runRequest cfg act0 = withRetries 3 300 act0
 where
   withRetries :: Int -> Int -> ResourceT IO a -> IO a
   withRetries !n !delayInMS act =
     runResourceT act `catch` (\(e :: HttpException) -> do
                    if n > 0 then do
                       msg cfg $ "HTTP-Error: " ++ show e ++ "\nRetrying in "
                                  ++ show delayInMS ++ "ms..."
                       threadDelay (delayInMS * 1000)
                       withRetries (n - 1) (delayInMS + delayInMS) act
                      else do
                        msg cfg $ "HTTP-Error: " ++ show e
                                   ++ "\nFATAL: Giving up"
                        throwIO e)

takeWhileStream :: (a -> Bool) -> InputStream a -> IO (InputStream a)
takeWhileStream predicate input = Streams.fromGenerator go
 where
   go = do mb_a <- liftIO (Streams.read input)
           case mb_a of
             Nothing -> return ()
             Just a -> if predicate a then yield a >> go else return ()

lsS3_ :: Config -> S3Path -> IO (Response [S3Path])
lsS3_ cfg0@(Config cfg s3cfg _ mgr bucket _throttle) path = go Nothing
 where
   go marker = do
      runRequest cfg0 $ do
        liftIO $ msg cfg0 ("REQ: " ++ show path ++
                           maybe "" ((" FROM: "++) . show) marker)
        rsp <- Aws.pureAws cfg s3cfg mgr $!
                 S3.GetBucket{ S3.gbBucket = bucket
                             , S3.gbPrefix = Just path
                             , S3.gbDelimiter = Just "/"
                             , S3.gbMaxKeys = defaultMaxKeys
                             , S3.gbMarker = marker
                             }
        --liftIO (print rsp)
        case S3.gbrCommonPrefixes rsp of
          [] -> return Done
          entries
           | Just maxKeys <- S3.gbrMaxKeys rsp , length entries < maxKeys
           -> return (Full entries)
           | otherwise
           -> do
             let !marker' = last entries
             return $! More entries (go $! Just marker')

matching_ :: Config -> S3Path -> DatePattern -> IO (Response [S3ObjectKey])
matching_ cfg@(Config awsCfg s3Cfg _ mgr bucket throttle) serverPath fromDate =
  go (Just (serverPath <> toMarker fromDate))
 where
   go marker = Sem.with throttle $ do
     runRequest cfg $ do
       liftIO $ msg cfg ("REQ: " ++ show serverPath ++
                          maybe "" ((" FROM: "++) . show) marker)
       rsp <- Aws.pureAws awsCfg s3Cfg mgr $!
                 S3.GetBucket{ S3.gbBucket = bucket
                             , S3.gbPrefix = Just serverPath
                             , S3.gbDelimiter = Nothing
                             , S3.gbMaxKeys = defaultMaxKeys
                             , S3.gbMarker = marker
                             }
       case map S3.objectKey (S3.gbrContents rsp) of -- REVIEW: Data.Vector?
         [] -> return Done
         entries
          | Just maxKeys <- S3.gbrMaxKeys rsp , length entries < maxKeys
          -> return (Full entries)
          | otherwise
          -> do
            let !marker' = last entries
            return $! More entries (go $! Just marker')

chunkedGen :: IO (Response [a]) -> Generator a ()
chunkedGen action0 = go action0
 where
   go action = do
     mb_entries <- liftIO action
     case mb_entries of
       Done -> return ()
       Full entries ->
         mapM_ yield entries
       More entries action' -> do
         mapM_ yield entries
         go action'
