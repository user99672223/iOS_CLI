#!/usr/bin/env bash
# Build the Wine unix-side static libraries for one platform:
#   native.sh iphoneos|iphonesimulator   -> out/<platform>/lib{ntdll_unix,wineserver,win32u_unix}.a
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export WINE_IOS_PLATFORM="$1"
MINGW_BIN="$("$ROOT/tools/ci/setup-mingw.sh")"
export PATH="$MINGW_BIN:$PATH"   # llvm-objcopy for the wineserver symbol renames
bash "$ROOT/build/ntdll-unix/build.sh"
bash "$ROOT/build/wineserver/build.sh"
bash "$ROOT/build/win32u-unix/build.sh"
ls -la "$ROOT/out/$1"
