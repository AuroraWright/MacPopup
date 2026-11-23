#!/bin/zsh
# build.sh <tool>...: compiles tools/<tool>.swift into build/test/tools/<tool> when it's missing or older than its
# source, and prints the path of the last one. For drivers (launch.sh's "// driver:"), which use them beside the
# test instance.
set -euo pipefail
TOOLS=${0:A:h} OUT=${0:A:h:h:h:h:h}/build/test/tools
mkdir -p "$OUT"
for tool in "$@"; do
    if [[ ! -x "$OUT/$tool" || "$TOOLS/$tool.swift" -nt "$OUT/$tool" ]]; then
        swiftc -O -o "$OUT/$tool.tmp.$$" "$TOOLS/$tool.swift" >&2 && mv "$OUT/$tool.tmp.$$" "$OUT/$tool"
    fi
done
echo "$OUT/${@[-1]}"
