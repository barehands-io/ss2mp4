PREFIX ?= $(HOME)/.local
APPDIR ?= $(HOME)/Applications
# Oldest macOS the app is built for.
MACOS_MIN ?= 13.0

CORE := $(wildcard Sources/Core/*.swift)
CLI := $(wildcard Sources/ss2mp4/*.swift)
APP_SRC := $(wildcard Sources/App/*.swift)
BIN := .build/ss2mp4
APP := .build/ss2mp4.app
APP_BIN := $(APP)/Contents/MacOS/ss2mp4

# -swift-version 5: the pump callbacks are not Swift 6 concurrency-safe.
# -suppress-warnings: AVFoundation reader/writer APIs are deprecated in macOS 26/27 SDKs but still work.
SWIFTC := swiftc -O -swift-version 5 -suppress-warnings

.PHONY: build app install install-app uninstall uninstall-app clean

build: $(BIN)

$(BIN): $(CORE) $(CLI) Makefile
	mkdir -p .build
	$(SWIFTC) $(CORE) $(CLI) -o $(BIN)

app: $(APP_BIN)

# The executable is the target, so a missing or stale bundle is always rebuilt.
$(APP_BIN): $(CORE) $(APP_SRC) Sources/App/Info.plist Makefile
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	$(SWIFTC) -parse-as-library -target $(shell uname -m)-apple-macos$(MACOS_MIN) $(CORE) $(APP_SRC) -o $(APP_BIN)
	cp Sources/App/Info.plist $(APP)/Contents/Info.plist
	plutil -replace LSMinimumSystemVersion -string $(MACOS_MIN) $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

install: $(BIN)
	install -d "$(PREFIX)/bin"
	install -m 755 "$(BIN)" "$(PREFIX)/bin/ss2mp4"

install-app: $(APP_BIN)
	install -d "$(APPDIR)"
	rm -rf "$(APPDIR)/ss2mp4.app"
	cp -R $(APP) "$(APPDIR)/ss2mp4.app"

uninstall:
	rm -f "$(PREFIX)/bin/ss2mp4"

uninstall-app:
	rm -rf "$(APPDIR)/ss2mp4.app"

clean:
	rm -rf .build
