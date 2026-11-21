#!/usr/bin/env bash
# Zip an unsigned device build into dist/Harbor.ipa (Payload/Harbor.app).
set -euo pipefail
APP="$1"; DEST="${2:-dist}"
rm -rf "$DEST/Payload" && mkdir -p "$DEST/Payload"
cp -R "$APP" "$DEST/Payload/"
(cd "$DEST" && rm -f Harbor.ipa && zip -qry Harbor.ipa Payload && rm -rf Payload)
shasum -a 256 "$DEST/Harbor.ipa" | tee "$DEST/Harbor.ipa.sha256"
