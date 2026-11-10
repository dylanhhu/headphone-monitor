#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Headphone Monitor.app"
ARCHIVE_PATH="$ROOT_DIR/dist/HeadphoneMonitor-macOS.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"
HASH="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$HASH" 'HeadphoneMonitor-macOS.zip' > "$CHECKSUM_PATH"
printf '%s\n%s\n' "$ARCHIVE_PATH" "$CHECKSUM_PATH"
