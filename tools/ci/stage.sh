#!/usr/bin/env bash
# Stage bundle resources that are generated or come from the Wine tree:
# app/Resources/nls (Wine's NLS tables) and app/Resources/aarch64-windows (the farm).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
R="$ROOT/app/Resources"
rm -rf "$R/nls" "$R/aarch64-windows"
mkdir -p "$R/nls/extra"
for f in c_1252 c_20127 c_28591 c_437 c_850 l_intl locale normidna normnfc normnfd normnfkc normnfkd sortdefault; do
  cp "$ROOT/wine/nls/$f.nls" "$R/nls/"
done
for f in c_10000 c_932 c_936 c_949 c_950; do cp "$ROOT/wine/nls/$f.nls" "$R/nls/extra/"; done
cp -R "$ROOT/out/farm/aarch64-windows" "$R/aarch64-windows"
rm -f "$R/aarch64-windows/.farm-manifest"
echo "staged: $(ls "$R/aarch64-windows" | wc -l) farm files, $(du -sh "$R/aarch64-windows" | cut -f1)"
