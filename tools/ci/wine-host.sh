#!/usr/bin/env bash
# Configure wine/build-macos (Madeira's tools/build/build-wine.sh): config.h,
# the build tools and every generated header the iOS unix-side libraries read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MINGW_BIN="$("$ROOT/tools/ci/setup-mingw.sh")"
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$MINGW_BIN:$PATH"
B="$ROOT/wine/build-macos"
mkdir -p "$B"
if [ ! -f "$B/Makefile" ]; then
  (cd "$B" && ../configure --enable-archs=aarch64 --disable-tests --without-x \
     --without-freetype --without-gnutls --enable-winegstreamer)
fi
make -C "$B" -j"$(sysctl -n hw.ncpu)" tools/all tools/widl/all tools/winebuild/all include/all
for h in include/config.h include/wtypes.h; do
  test -f "$B/$h" || { echo "missing $B/$h" >&2; exit 1; }
done
