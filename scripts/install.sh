#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_APP="$ROOT_DIR/dist/Headphone Monitor.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST_APP="$INSTALL_DIR/Headphone Monitor.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    printf 'Build the app first with make build\n' >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"

if [[ -e "$DEST_APP" ]]; then
    TEMP_ROOT="${TMPDIR:-/private/tmp}"
    TEMP_ROOT="${TEMP_ROOT%/}"
    BACKUP_DIR="$(mktemp -d "$TEMP_ROOT/headphone-monitor-install.XXXXXX")"
    mv "$DEST_APP" "$BACKUP_DIR/previous.app"
    printf 'Moved existing installation to %s\n' "$BACKUP_DIR/previous.app"
fi

/usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DEST_APP"
printf 'Installed %s\n' "$DEST_APP"
