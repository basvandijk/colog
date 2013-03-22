DIST ?=dist
EXEC ?=colog

default: $(DIST)/build/$(EXEC)/$(EXEC)

$(DIST)/setup-config: colog.cabal
	cabal configure

HSSRCS := $(shell find . -name '*.hs')

$(DIST)/build/$(EXEC)/$(EXEC): $(DIST)/setup-config $(HSSRCS)
	cabal build

.PHONY: run
run: $(DIST)/build/$(EXEC)/$(EXEC)
	time ./$(DIST)/build/$(EXEC)/$(EXEC)

colog:
	cabal install
