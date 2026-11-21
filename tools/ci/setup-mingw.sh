#!/usr/bin/env bash
# Download the pinned llvm-mingw (same release as Madeira) into toolchains/.
# Prints the bin directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=20260421
case "$(uname -s)" in
  Darwin) NAME="llvm-mingw-${VERSION}-ucrt-macos-universal"
          SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7 ;;
  Linux)  NAME="llvm-mingw-${VERSION}-ucrt-ubuntu-22.04-x86_64"; SHA="" ;;
esac
DEST="$ROOT/toolchains/$NAME"
if [ ! -x "$DEST/bin/aarch64-w64-mingw32-clang" ]; then
  mkdir -p "$ROOT/toolchains"
  curl -fsSL --retry 3 -o "$ROOT/toolchains/$NAME.tar.xz" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/${VERSION}/${NAME}.tar.xz"
  if [ -n "$SHA" ]; then
    echo "$SHA  $ROOT/toolchains/$NAME.tar.xz" | shasum -a 256 -c - >&2
  fi
  tar -xJf "$ROOT/toolchains/$NAME.tar.xz" -C "$ROOT/toolchains"
  rm -f "$ROOT/toolchains/$NAME.tar.xz"
fi
echo "$DEST/bin"
