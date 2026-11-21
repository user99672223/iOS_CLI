#!/usr/bin/env bash
# Build harbor-host.exe (aarch64 Windows) into out/host/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MINGW_BIN="$("$ROOT/tools/ci/setup-mingw.sh")"
mkdir -p "$ROOT/out/host"
"$MINGW_BIN/aarch64-w64-mingw32-gcc" -O2 -Wall -municode -Wl,--no-insert-timestamp \
  -o "$ROOT/out/host/harbor-host.exe" "$ROOT/host/harbor-host.c"
"$MINGW_BIN/aarch64-w64-mingw32-strip" "$ROOT/out/host/harbor-host.exe"
ls -la "$ROOT/out/host"
