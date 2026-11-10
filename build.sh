#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$(mktemp -d "$ROOT_DIR/.build.XXXXXX")"
APP_DIR="$BUILD_DIR/Headphone Monitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
DEST_DIR="$ROOT_DIR/dist/Headphone Monitor.app"

mkdir -p "$CONTENTS_DIR/MacOS"

xcrun clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
    -O3 \
    -Wall \
    -Wextra \
    -mmacosx-version-min=11.0 \
    -isysroot "$SDK_PATH" \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    "$ROOT_DIR/HeadphoneMonitor.m" \
    -o "$CONTENTS_DIR/MacOS/HeadphoneMonitor"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

/usr/bin/codesign \
    --force \
    --sign - \
    --entitlements "$ROOT_DIR/HeadphoneMonitor.entitlements" \
    "$APP_DIR"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$ROOT_DIR/dist"
if [[ -e "$DEST_DIR" ]]; then
    mv "$DEST_DIR" "$BUILD_DIR/previous.app"
fi
/usr/bin/ditto "$APP_DIR" "$DEST_DIR"

printf '%s\n' "$DEST_DIR"
