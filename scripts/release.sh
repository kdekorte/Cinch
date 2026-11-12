#!/bin/bash
#
# scripts/release.sh — build a distributable Cinch release
#
# Usage:
#   scripts/release.sh              Build, zip and print the sha256 for the cask
#
# Steps performed:
#   1. Release build via scripts/build.sh (set ZIP=1 to also zip)
#   2. Zip the .app with ditto (preserves symlinks, permissions and
#      code-signature metadata — Finder's "Compress" does not)
#   3. Print the zip path and its sha256, to paste into Casks/cinch.rb
#
# Before distributing publicly, the app should be signed with a
# "Developer ID Application" certificate and notarized:
#   codesign --force --deep --options runtime --sign "Developer ID Application: …" build/Cinch.app
#   xcrun notarytool submit build/Cinch-<version>.zip --apple-id … --team-id … --password … --wait
#   xcrun stapler staple build/Cinch.app
# then re-zip with this script.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT_DIR="$ROOT/build"
VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' Cinch.xcodeproj/project.pbxproj | head -1)"

echo "==> Building Cinch (Release, version ${VERSION})"
"$ROOT/scripts/build.sh" release

APP="$OUT_DIR/Cinch.app"
ZIP="$OUT_DIR/Cinch-${VERSION}.zip"

echo "==> Zipping ${ZIP}"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ""
echo "==> Done: ${ZIP}"
echo "    sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo ""
echo "Next steps:"
echo "  1. Attach ${ZIP} to the GitHub release v${VERSION} of kdekorte/Cinch"
echo "  2. Update 'version' and 'sha256' in Casks/cinch.rb (sha above)"
echo "  3. Commit and push — users then run:"
echo "       brew tap kdekorte/cinch https://github.com/kdekorte/Cinch"
echo "       brew install --cask kdekorte/cinch/cinch"
