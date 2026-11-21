# Sourced by the native build scripts. Selects the Apple platform the Wine
# unix side is compiled for: WINE_IOS_PLATFORM=iphoneos (device, default) or
# iphonesimulator. Outputs go to out/<platform>/, objects to obj-<platform>/.
PLATFORM="${WINE_IOS_PLATFORM:-iphoneos}"
case "$PLATFORM" in
    iphoneos) TRIPLE=arm64-apple-ios17.0 ;;
    iphonesimulator) TRIPLE=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown WINE_IOS_PLATFORM=$PLATFORM" >&2; exit 1 ;;
esac
SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
_PLAT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$_PLAT_ROOT/out/$PLATFORM"
mkdir -p "$OUT_DIR"
export PLATFORM TRIPLE SDK OUT_DIR
