#!/bin/bash
#
# scripts/release.sh — build and publish a Cinch release
#
# Usage:
#   scripts/release.sh              Full release: build, package, update cask,
#                                   tag, create the GitHub release and attach
#                                   the .zip and .pkg artifacts
#   scripts/release.sh --no-publish # Build and package only; print the sha256
#                                   without tagging or touching GitHub
#
# What it does:
#   1. Release build via scripts/build.sh
#   2. Zip the .app with ditto (preserves symlinks, permissions and
#      code-signature metadata — Finder's "Compress" does not)
#   3. Build an installer .pkg with pkgbuild (installs to /Applications)
#   4. Update version + sha256 in Casks/cinch.rb and commit it
#   5. Tag v<version> and create the GitHub release via `gh`, attaching
#      Cinch-<version>.zip and Cinch-<version>.pkg
#      (GitHub also auto-provides Source code zip/tar.gz links for the tag.)
#
# Requires: Xcode, `gh` (authenticated: `gh auth login`), pkgbuild (part of macOS)
#
# Before distributing publicly, the app should be signed with a
# "Developer ID Application" certificate and notarized BEFORE packaging:
#   codesign --force --deep --options runtime --sign "Developer ID Application: …" build/Cinch.app
#   xcrun notarytool submit build/Cinch-<version>.zip --apple-id … --team-id … --password … --wait
#   xcrun stapler staple build/Cinch.app
# then re-run this script so the zip/pkg carry the notarized app.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT_DIR="$ROOT/build"
PUBLISH=1
if [[ "${1:-}" == "--no-publish" ]]; then
  PUBLISH=0
fi

VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' Cinch.xcodeproj/project.pbxproj | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from the project file" >&2
  exit 1
fi
TAG="v${VERSION}"

echo "==> Building Cinch (Release, version ${VERSION})"
"$ROOT/scripts/build.sh" release

APP="$OUT_DIR/Cinch.app"
ZIP="$OUT_DIR/Cinch-${VERSION}.zip"
PKG="$OUT_DIR/Cinch-${VERSION}.pkg"

echo "==> Zipping ${ZIP}"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Building installer ${PKG}"
rm -f "$PKG"
pkgbuild \
  --identifier "com.kdekorte.Cinch" \
  --version "$VERSION" \
  --install-location "/Applications" \
  --component "$APP" \
  "$PKG"

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "    zip sha256: ${SHA256}"

echo "==> Updating Casks/cinch.rb"
sed -i '' -E \
  -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"${SHA256}\"/" \
  "Casks/cinch.rb"

if [[ $PUBLISH -eq 0 ]]; then
  echo ""
  echo "==> Done (not published):"
  echo "    ${ZIP}  (sha256 ${SHA256})"
  echo "    ${PKG}"
  exit 0
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "error: tag ${TAG} already exists. Bump MARKETING_VERSION or delete the tag first:" >&2
  echo "  git tag -d ${TAG} && git push origin :refs/tags/${TAG}" >&2
  exit 1
fi

echo "==> Committing cask update"
git add "Casks/cinch.rb"
git diff --cached --quiet -- "Casks/cinch.rb" || \
  git commit -m "Bump cask to ${VERSION} (sha256 ${SHA256:0:12}…)"

echo "==> Tagging ${TAG}"
git tag "${TAG}"

echo "==> Creating GitHub release ${TAG}"
gh release create "$TAG" \
  --repo kdekorte/Cinch \
  --title "Cinch ${VERSION}" \
  --generate-notes \
  "$ZIP" \
  "$PKG"

echo "==> Pushing branch and tag"
git push origin HEAD
git push origin "$TAG"

echo ""
echo "==> Released ${TAG}: https://github.com/kdekorte/Cinch/releases/tag/${TAG}"
echo "    Artifacts: ${ZIP}, ${PKG} (source zip/tar.gz are auto-provided by GitHub)"
