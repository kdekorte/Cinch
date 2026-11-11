#!/bin/bash
#
# scripts/build.sh — build Cinch from the command line and package it as an .app
#
# Usage:
#   scripts/build.sh              Debug build
#   scripts/build.sh release      Release build
#   scripts/build.sh clean        Remove build artifacts
#
# Output: build/Cinch.app (and build/Cinch.app.dSYM if present)
# Optional: set ZIP=1 to also produce build/Cinch-<version>.zip

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJECT="Cinch.xcodeproj"
SCHEME="Cinch"
CONFIGURATION="Debug"
OUT_DIR="$ROOT/build"

for arg in "$@"; do
  case "$arg" in
    release) CONFIGURATION="Release" ;;
    debug)   CONFIGURATION="Debug" ;;
    clean)
      rm -rf "$OUT_DIR"
      echo "Removed $OUT_DIR"
      exit 0
      ;;
    *) echo "Usage: $0 [debug|release|clean]" >&2; exit 1 ;;
  esac
done

echo "==> Building $SCHEME ($CONFIGURATION)"
DERIVED="$OUT_DIR/DerivedData"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION/Cinch.app"
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found" >&2
  exit 1
fi

# Copy the .app (and dSYM if it exists) out of DerivedData
rm -rf "$OUT_DIR/Cinch.app" "$OUT_DIR/Cinch.app.dSYM"
cp -R "$APP" "$OUT_DIR/Cinch.app"
if [[ -d "$APP.dSYM" ]]; then
  cp -R "$APP.dSYM" "$OUT_DIR/Cinch.app.dSYM"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$OUT_DIR/Cinch.app/Contents/Info.plist" 2>/dev/null || echo 1.0)"

echo
echo "==> Done: $OUT_DIR/Cinch.app (version $VERSION)"

if [[ "${ZIP:-0}" == "1" ]]; then
  ZIP_PATH="$OUT_DIR/Cinch-$VERSION.zip"
  rm -f "$ZIP_PATH"
  (cd "$OUT_DIR" && ditto -c -k --keepParent Cinch.app "$ZIP_PATH")
  echo "==> Archive: $ZIP_PATH"
fi
