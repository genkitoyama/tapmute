APP          := TapMute
BUNDLE_ID    := io.github.genkitoyama.tapmute
BUILD_DIR    := build
APP_BUNDLE   := $(BUILD_DIR)/$(APP).app
MACOS_DIR    := $(APP_BUNDLE)/Contents/MacOS
SOURCES      := $(wildcard Sources/*.swift)
TARGET_ARCH  := arm64-apple-macos13.0
SWIFTFLAGS   := -O -target $(TARGET_ARCH) -framework Cocoa -framework SwiftUI \
                -framework CoreAudio -framework IOKit -framework ServiceManagement \
                -framework MediaPlayer -framework AVFoundation
# TCC（権限）はコード署名の同一性で紐づく。アドホック署名（-）だとバイナリが変わる
# たびに cdhash が変わり、再ビルドのたびに権限を付け直す羽目になる。
# 安定した署名 ID があればそれを自動で使う。
DETECTED_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | \
                       grep -m1 -E "Developer ID Application|Apple Development" | \
                       sed -E 's/.*"(.*)".*/\1/')
SIGN_IDENTITY ?= $(if $(DETECTED_IDENTITY),$(DETECTED_IDENTITY),-)

.PHONY: all run install clean probe-keys probe-windows

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Resources/Info.plist
	@mkdir -p $(MACOS_DIR)
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(MACOS_DIR)/$(APP)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "built: $(APP_BUNDLE)"

run: all
	@pkill -x $(APP) || true
	@open $(APP_BUNDLE)

install: all
	@pkill -x $(APP) || true
	@rm -rf /Applications/$(APP).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "installed: /Applications/$(APP).app"

# ターミナルの権限で仕組みだけ先に確認するためのプローブ
probe-keys: $(BUILD_DIR)/probe
	@$(BUILD_DIR)/probe --probe-keys

probe-windows: $(BUILD_DIR)/probe
	@$(BUILD_DIR)/probe --probe-windows

$(BUILD_DIR)/probe: $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BUILD_DIR)/probe

clean:
	rm -rf $(BUILD_DIR)
