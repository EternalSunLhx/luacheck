#!/usr/bin/env bash
set -eu
set -o pipefail

# Builds the following binaries:
# * luacheck (Linux x86-64)
# * luacheck32 (Linux x86)
# * luacheck.exe (Windows x86-64)
# * luacheck32.exe (Windows x86)
# Should be executed from root Luacheck directory.
# Resulting binaries will be in `build/bin/`.

cd build

make fetch

function build {
    label="$1"
    shift

    echo
    echo "=== Building Luacheck ($label) ==="
    echo

    make clean "$@"
    make "-j$(nproc)" "$@"
}

build "Windows x86-64" SUFFIX=.exe
# build "Windows x86-64" CROSS=x86_64-w64-mingw32- SUFFIX=.exe
