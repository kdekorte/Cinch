# Cinch

Cinch is a native macOS archive editor for `.zip` files, built with SwiftUI and AppKit. It lets you browse, edit, and extract the contents of zip archives in a familiar Finder-style multi-column outline view — without ever dropping to the command line.

## Features

- **Browse archives** — Finder-like multi-column outline view (Name, Kind, Size, Date Modified) with sortable, resizable, and reorderable columns.
- **Create new archives** — start a fresh zip with File ▸ New Zip Archive (⌘N).
- **Open existing archives** — via the open panel (⌘O) or by dropping a `.zip` onto the window.
- **Add files and folders**
  - File ▸ Add Files to Zip… (⌘A)
  - Drag and drop files or entire folders (added recursively) into the window or onto a selected folder in the tree.
- **Delete entries** — remove files or folders from the archive.
- **Rename entries** — rename files and folders inside the archive.
- **New folders** — create folders inside the archive.
- **Extract / Save** — save entries to disk, including recursive folder extraction, with progress feedback.
- **Drag out** — drag files and folders from the outline view out to the Finder.
- **Full menu support** — New, Open, Save (⌘S), Save As (⇧⌘S), and Add Files commands, plus keyboard shortcuts.

## Installation

### Homebrew (recommended)

Cinch ships its own Homebrew cask from this repository's GitHub releases:

```sh
brew tap kdekorte/cinch https://github.com/kdekorte/Cinch
brew install --cask kdekorte/cinch/cinch
```

To upgrade to a new release:

```sh
brew update
brew upgrade --cask kdekorte/cinch/cinch
```

To uninstall:

```sh
brew uninstall --cask kdekorte/cinch/cinch
brew untap kdekorte/cinch
```

> **Note:** the cask downloads the release artifact attached to the
> [GitHub releases](https://github.com/kdekorte/Cinch/releases) page, so it
> requires a published release (see *Releasing* below).

### Manual

Download `Cinch-<version>.zip` from the
[releases page](https://github.com/kdekorte/Cinch/releases), unzip it, and drag
`Cinch.app` to `/Applications`.

## Requirements

- macOS (AppKit-based UI; see *Project structure* below)
- Xcode with the [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) Swift package dependency

## Building

**From Xcode:** open `Cinch.xcodeproj`, select the **Cinch** scheme and build & run (⌘R). The ZIPFoundation dependency resolves automatically via Swift Package Manager.

**From the command line:** use the build script, which compiles a configuration and packages it as `build/Cinch.app` (a universal x86_64 + arm64 binary, ad-hoc signed):

```sh
scripts/build.sh              # Debug build -> build/Cinch.app
scripts/build.sh release      # Release build -> build/Cinch.app (+ .dSYM)
scripts/build.sh clean        # Remove build artifacts
ZIP=1 scripts/build.sh release  # also produce build/Cinch-<version>.zip
```

## Releasing

To cut and publish a new release:

```sh
scripts/release.sh
```

This builds a Release configuration, packages the app twice — a `ditto` zip
(preserving signing metadata; used by the Homebrew cask) and a `.pkg` installer
(via `pkgbuild`, installs to `/Applications`) — updates `version` and `sha256`
in [`Casks/cinch.rb`](Casks/cinch.rb), commits the cask, tags `v<version>`,
creates the GitHub release with both artifacts attached, and pushes the branch
and tag. GitHub automatically provides Source code (zip/tar.gz) links for the
tag. Use `scripts/release.sh --no-publish` to build and package only, without
touching git or GitHub.

For distribution to other people, sign the app with a "Developer ID Application"
certificate and notarize it before running the release script (`codesign`,
`xcrun notarytool`, `xcrun stapler`); the script's header documents the commands.

## Project structure

```
Cinch/
├── Cinch/
│   ├── CinchApp.swift            # App entry point, menu commands, AppModel intents
│   ├── ContentView.swift         # Main UI: archive browsing, editing, drag & drop, saving
│   └── MultiColumnOutlineView.swift  # NSOutlineView-backed multi-column list (macOS only)
├── Casks/
│   └── cinch.rb                  # Homebrew cask (this repo is the tap)
├── scripts/
│   ├── build.sh                  # Command-line build script
│   └── release.sh                # Build, zip and checksum a release artifact
├── CinchTests/                   # Swift Testing unit tests
├── CinchUITests/                 # UI launch tests
└── LICENSE
```

The core data model is `ZipNode` — a lightweight tree node representing a file or directory inside the archive, with name, size, and modification date. `MultiColumnOutlineView` is an `NSViewRepresentable` wrapper around `NSOutlineView`; on non-macOS platforms a stub view is compiled in its place.

## License

[MIT](LICENSE) © 2026 Kevin DeKorte
