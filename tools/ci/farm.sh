#!/usr/bin/env bash
# Build the aarch64-windows DLL farm into out/farm/aarch64-windows (Linux or macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MINGW_BIN="$("$ROOT/tools/ci/setup-mingw.sh")"
export PATH="$MINGW_BIN:$PATH"
# macOS: the same arm64 host tree the unix side uses (wine-host.sh), as Madeira.
# Linux (x86_64 host) works for most modules but not Wine's host-arch helpers.
if [ "$(uname -s)" = Darwin ]; then B="$ROOT/wine/build-macos"; else B="$ROOT/wine/build-farm"; fi
mkdir -p "$B"
if [ ! -f "$B/Makefile" ]; then
  (cd "$B" && ../configure --enable-archs=aarch64 --disable-tests --without-x \
     --without-freetype --without-gnutls)
fi
JOBS=$(getconf _NPROCESSORS_ONLN)
make -C "$B" -j"$JOBS" tools/all tools/widl/all tools/winebuild/all tools/wrc/all include/all
rm -rf "$ROOT/out/farm"
python3 "$ROOT/build/build-farm.py" "$B" "$ROOT/out/farm/aarch64-windows" \
  --strip "$MINGW_BIN/aarch64-w64-mingw32-strip" --jobs "$JOBS" ${FARM_EXTRA:+--extra $FARM_EXTRA}
