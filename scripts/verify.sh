#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Headphone Monitor.app"
ENTITLEMENTS_FILE="$ROOT_DIR/HeadphoneMonitor.entitlements"

plutil -lint "$ROOT_DIR/Info.plist" "$ENTITLEMENTS_FILE"

if [[ ! -x "$APP_DIR/Contents/MacOS/HeadphoneMonitor" ]]; then
    printf 'Missing application executable: %s\n' "$APP_DIR" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP_DIR" 2>/dev/null)"
if [[ "$ENTITLEMENTS" != *'com.apple.security.app-sandbox'* ]]; then
    printf 'App Sandbox entitlement is missing\n' >&2
    exit 1
fi
if [[ "$ENTITLEMENTS" != *'com.apple.security.device.audio-input'* ]]; then
    printf 'Microphone input entitlement is missing\n' >&2
    exit 1
fi
if [[ "$ENTITLEMENTS" == *'com.apple.security.network.client'* ]] ||
   [[ "$ENTITLEMENTS" == *'com.apple.security.network.server'* ]]; then
    printf 'Unexpected network entitlement found\n' >&2
    exit 1
fi
if [[ "$ENTITLEMENTS" == *'com.apple.security.files.'* ]]; then
    printf 'Unexpected filesystem entitlement found\n' >&2
    exit 1
fi

if grep -Eq 'NS(URLSession|URLConnection|FileHandle)|socket\(|connect\(' "$ROOT_DIR/HeadphoneMonitor.m"; then
    printf 'Potential network or file API found in the audio application source\n' >&2
    exit 1
fi

printf 'Verification passed: %s\n' "$APP_DIR"
