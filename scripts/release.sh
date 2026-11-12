#!/bin/bash
#
# scripts/release.sh - Release management for Cinch
#
# Usage:
#   scripts/release.sh              Show current version and status
#   scripts/release.sh tag          Tag the current commit and push
#   scripts/release.sh package      Build the distribution zip, pkg and source zip
#   scripts/release.sh release      Create GitHub release and upload assets
#   scripts/release.sh cask         Update the Homebrew cask with the correct version and SHA256
#   scripts/release.sh all          Run all steps: tag, release and cask update
#
# Requires: gh (GitHub CLI), authenticated via `gh auth login`
#

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' Cinch.xcodeproj/project.pbxproj | head -1)
TAG="v${VERSION}"
CASK="Casks/cinch.rb"
ZIP="Cinch-${VERSION}.zip"
PKG="Cinch-${VERSION}.pkg"
SRC="Cinch-${VERSION}-source.zip"
ZIP_URL="https://github.com/kdekorte/Cinch/releases/download/${TAG}/${ZIP}"
PKG_URL="https://github.com/kdekorte/Cinch/releases/download/${TAG}/${PKG}"
SRC_URL="https://github.com/kdekorte/Cinch/releases/download/${TAG}/${SRC}"

info()    { printf "\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
success() { printf "\033[1;32m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
error()   { printf "\033[1;31mError:\033[0m %s\n" "$1" >&2; exit 1; }

show_status() {
    info "Cinch release status"
    echo "  Version:     ${VERSION}"
    echo "  Tag:         ${TAG}"
    echo "  Cask:        ${CASK}"
    echo "  Zip URL:     ${ZIP_URL}"
    echo "  Pkg URL:     ${PKG_URL}"
    echo "  Src URL:     ${SRC_URL}"
    echo ""

    if git rev-parse "${TAG}" >/dev/null 2>&1; then
        success "Tag ${TAG} exists locally"
    else
        echo "  Tag ${TAG} has not been created yet"
    fi

    if command -v gh >/dev/null 2>&1; then
        if gh release view "${TAG}" --repo kdekorte/Cinch >/dev/null 2>&1; then
            success "GitHub release ${TAG} exists"
        else
            echo "  GitHub release ${TAG} has not been created yet"
        fi
    fi
}

do_tag() {
    info "Tagging release ${TAG}"

    if git rev-parse "${TAG}" >/dev/null 2>&1; then
        error "Tag ${TAG} already exists. Bump MARKETING_VERSION in Cinch.xcodeproj first."
    fi

    if ! git diff --quiet || ! git diff --cached --quiet; then
        error "Working tree is dirty. Commit all changes before tagging."
    fi

    git tag -a "${TAG}" -m "Release ${VERSION}"
    info "Pushing tag ${TAG} to origin"
    git push origin "${TAG}"
    success "Tag ${TAG} created and pushed"
}

# Build the distribution artifacts in build/: the ditto zip (its signature
# survives; used by the Homebrew cask) and the pkgbuild installer.
do_package() {
    info "Building distribution package"
    scripts/build.sh release
    rm -f "build/${ZIP}" "build/${PKG}"
    ditto -c -k --sequesterRsrc --keepParent build/Cinch.app "build/${ZIP}"
    success "Created build/${ZIP}"

    info "Building installer package"
    pkgbuild \
        --identifier "com.kdekorte.Cinch" \
        --version "${VERSION}" \
        --install-location "/Applications" \
        --component build/Cinch.app \
        "build/${PKG}"
    success "Created build/${PKG}"

    # Source archive: from the release tag when it exists, otherwise HEAD
    if git rev-parse "${TAG}" >/dev/null 2>&1; then
        info "Building source package from ${TAG}"
        git archive --format=zip -o "build/${SRC}" "${TAG}"
    else
        info "Building source package from HEAD (tag ${TAG} not created yet)"
        git archive --format=zip -o "build/${SRC}" HEAD
    fi
    success "Created build/${SRC}"
}


do_release() {
    info "Creating GitHub release ${TAG}"

    command -v gh >/dev/null 2>&1 || error "GitHub CLI (gh) is required. Install with: brew install gh"
    gh auth status >/dev/null 2>&1 || error "Not authenticated. Run: gh auth login"

    if ! git rev-parse "${TAG}" >/dev/null 2>&1; then
        error "Tag ${TAG} does not exist. Run 'scripts/release.sh tag' first."
    fi

    if gh release view "${TAG}" --repo kdekorte/Cinch >/dev/null 2>&1; then
        error "GitHub release ${TAG} already exists. Bump MARKETING_VERSION in Cinch.xcodeproj first."
    fi

    # Build the artifacts
    do_package

    if [ ! -f "build/${ZIP}" ]; then
        error "Package 'build/${ZIP}' not found after build."
    fi
    if [ ! -f "build/${PKG}" ]; then
        error "Package 'build/${PKG}' not found after build."
    fi
    if [ ! -f "build/${SRC}" ]; then
        error "Package 'build/${SRC}' not found after build."
    fi

    # Create the release and upload the assets
    info "Uploading ${ZIP}, ${PKG} and ${SRC} to release ${TAG}"
    gh release create "${TAG}" \
        --repo kdekorte/Cinch \
        --title "Cinch ${VERSION}" \
        --generate-notes \
        "build/${ZIP}" \
        "build/${PKG}" \
        "build/${SRC}"

    success "Release ${TAG} created:"
    echo "  ${ZIP_URL}"
    echo "  ${PKG_URL}"
    echo "  ${SRC_URL}"
}

do_cask() {
    info "Updating Homebrew cask for ${TAG}"

    if ! git rev-parse "${TAG}" >/dev/null 2>&1; then
        error "Tag ${TAG} does not exist. Run 'scripts/release.sh tag' first."
    fi

    info "Downloading ${ZIP} to compute SHA256..."
    SHA256=$(curl -sfL "${ZIP_URL}" | shasum -a 256 | awk '{print $1}')

    # An empty download hashes to e3b0c442...; treat it as missing.
    if [ -z "${SHA256}" ] || [ "${#SHA256}" -ne 64 ] || [ "${SHA256}" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        error "Failed to download ${ZIP_URL}. Has the release been published? Run 'scripts/release.sh release' first."
    fi

    info "SHA256: ${SHA256}"
    sed -i '' "s|^  version \".*\"|  version \"${VERSION}\"|" "${CASK}"
    sed -i '' "s|^  sha256 \".*\"|  sha256 \"${SHA256}\"|" "${CASK}"

    success "Cask updated:"
    echo "  Version: ${VERSION}"
    echo "  SHA256:  ${SHA256}"
    echo ""
    echo "Don't forget to commit the updated cask:"
    echo "  git add ${CASK}"
    echo "  git commit -m \"Update cask for ${VERSION}\""
    echo "  git push"
}

do_all() {
    do_tag
    echo ""
    do_release
    echo ""
    do_cask
}

# --- Main ---

case "${1:-status}" in
    status)   show_status ;;
    tag)      do_tag ;;
    package)  do_package ;;
    release)  do_release ;;
    cask)     do_cask ;;
    all)      do_all ;;
    *)
        echo "Usage: $0 {status|tag|package|release|cask|all}"
        echo ""
        echo "Commands:"
        echo "  status    Show current version and release status (default)"
        echo "  tag       Create and push a git tag for the current version"
        echo "  package   Build the Cinch-VERSION.zip, .pkg and -source.zip artifacts"
        echo "  release   Create GitHub release and upload the zip, pkg and source"
        echo "  cask      Update the Homebrew cask version and SHA256"
        echo "  all       Run tag, release and cask in sequence"
        exit 1
        ;;
esac
