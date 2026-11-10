#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TEMP_ROOT="${TMPDIR:-/private/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
TEST_DIR="$(mktemp -d "$TEMP_ROOT/headphone-monitor-tests.XXXXXX")"
TEST_BINARY="$TEST_DIR/metrics_test"

xcrun clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$TEST_DIR/ModuleCache" \
    -O2 \
    -Wall \
    -Wextra \
    -mmacosx-version-min=11.0 \
    -isysroot "$SDK_PATH" \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    "$ROOT_DIR/tests/metrics_test.m" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
