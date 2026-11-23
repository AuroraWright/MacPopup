#!/bin/zsh
# build.sh <tool>...: compiles tools/<tool>.swift into build/test/tools/<tool> when it's missing or older than its
# source, and prints the path of the last one. For drivers (launch.sh's "// driver:"), which use them beside the
# test instance. A <tool> ending in .swift is a path to a source elsewhere (e.g. a test window in
# Tests/App/ocr-windows/windows/ for "// beside:"), compiled under its name without .swift.
set -euo pipefail
TOOLS=${0:A:h} OUT=${0:A:h:h:h:h:h}/build/test/tools
mkdir -p "$OUT"
for tool in "$@"; do
    if [[ $tool == *.swift ]]; then source=${tool:A} name=${tool:t:r}; else source=$TOOLS/$tool.swift name=$tool; fi
    if [[ ! -x "$OUT/$name" || "$source" -nt "$OUT/$name" ]]; then
        swiftc -O -o "$OUT/$name.tmp.$$" "$source" >&2 && mv "$OUT/$name.tmp.$$" "$OUT/$name"
    fi
done
echo "$OUT/$name"
