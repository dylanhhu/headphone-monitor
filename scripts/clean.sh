#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"

for build_dir in "$ROOT_DIR"/.build.*(N); do
    if [[ -d "$build_dir" ]]; then
        rm -r "$build_dir"
    fi
done

if [[ -d "$ROOT_DIR/dist" ]]; then
    rm -r "$ROOT_DIR/dist"
fi

printf 'Removed generated build output\n'
