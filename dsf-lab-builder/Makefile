BINARY   := dsf-lab-builder
DIST     := dist
CMD      := ./cmd/server

.PHONY: run build build-all build-mac-arm build-mac-intel build-linux clean

## Run locally (hot: just recompile and restart)
run:
	go run $(CMD)

## Build for the current platform
build:
	go build -o $(BINARY) $(CMD)
	@echo "Built ./$(BINARY)"

## Cross-compile for all platforms into dist/
build-all: build-mac-arm build-mac-intel build-linux
	@echo "All binaries in $(DIST)/"

build-mac-arm:
	GOOS=darwin  GOARCH=arm64 go build -o $(DIST)/$(BINARY)-darwin-arm64   $(CMD)

build-mac-intel:
	GOOS=darwin  GOARCH=amd64 go build -o $(DIST)/$(BINARY)-darwin-amd64   $(CMD)

build-linux:
	GOOS=linux   GOARCH=amd64 go build -o $(DIST)/$(BINARY)-linux-amd64    $(CMD)

clean:
	rm -rf $(DIST) $(BINARY)
