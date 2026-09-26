PREFIX ?= $(HOME)/.local
SRC := $(wildcard Sources/ss2mp4/*.swift)
BIN := .build/ss2mp4

.PHONY: build install uninstall clean

build: $(BIN)

# -swift-version 5: the pump callbacks are not Swift 6 concurrency-safe.
# -suppress-warnings: AVFoundation reader/writer APIs are deprecated in macOS 26/27 SDKs but still work.
$(BIN): $(SRC)
	mkdir -p .build
	swiftc -O -swift-version 5 -suppress-warnings $(SRC) -o $(BIN)

install: $(BIN)
	install -d "$(PREFIX)/bin"
	install -m 755 "$(BIN)" "$(PREFIX)/bin/ss2mp4"

uninstall:
	rm -f "$(PREFIX)/bin/ss2mp4"

clean:
	rm -rf .build
