# Cinch

Cinch is a native macOS archive editor for `.zip`, `.tar` and `.tar.gz` files, built with SwiftUI and AppKit. It lets you browse, edit, and extract the contents of archives in a familiar Finder-style multi-column outline view — without ever dropping to the command line.

## Features

- **Browse archives** — Finder-like multi-column outline view (Name, Kind, Size, Date Modified) with sortable, resizable, and reorderable columns. Supports zip, tar and gzip-compressed tar (`tar.gz` / `tgz`) archives.
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

Release management is handled by `scripts/release.sh` (modeled on the basika
release script):

```sh
scripts/release.sh            # show current version and release status
scripts/release.sh tag        # create and push the v<version> git tag
scripts/release.sh package    # build Cinch-<version>.zip and Cinch-<version>.pkg
scripts/release.sh release    # create the GitHub release and upload both artifacts
scripts/release.sh cask       # update Casks/cinch.rb version and SHA256
scripts/release.sh all        # run tag, release and cask in sequence
```

Release notes: write `ReleaseNotes/v<version>.md` and commit it with the version
bump — it becomes the GitHub release body. Without one, the release is created
with generated notes (a Highlights placeholder plus every commit since the
previous tag), which you can curate afterwards with
`gh release edit v<version> --notes-file ReleaseNotes/v<version>.md`.

The zip is built with `ditto` (preserving signing metadata; used by the
Homebrew cask), the `.pkg` with `pkgbuild` (installs to `/Applications`), and
the source zip with `git archive` (from the release tag). The `cask` step
downloads the published zip to compute the SHA256, so the cask always matches
the release artifact. Requires `gh` authenticated via `gh auth login`.

For distribution to other people, sign the app with a "Developer ID Application"
certificate and notarize it before running the release script (`codesign`,
`xcrun notarytool`, `xcrun stapler`); the script's header documents the commands.

## MCP server (`cinch-mcp`)

Cinch's archive engines are also exposed as an **MCP (Model Context Protocol) server** over stdio, so AI agents such as Cline, Claude Code or Claude Desktop can browse, create, edit and extract zip and tar/tar.gz archives through the same battle-tested code the app uses (libzip for zip incl. AES-256 passwords, the built-in ustar/gzip engine for tar).

### Bundled with the app

`scripts/build.sh` builds the server **into the app bundle** — a universal (arm64 + x86_64) binary at `Cinch.app/Contents/MacOS/cinch-mcp`, signed without the app's sandbox entitlements so MCP clients can launch it directly with full file access. Every build, release zip and .pkg therefore ships it:

```sh
scripts/build.sh                 # build/Cinch.app/Contents/MacOS/cinch-mcp
```

After installing Cinch to `/Applications`, point clients at:

```
/Applications/Cinch.app/Contents/MacOS/cinch-mcp
```

### Building it standalone

The package reuses the engine sources in `Cinch/` via Swift Package Manager:

```sh
swift build            # debug binary at .build/debug/cinch-mcp
swift build -c release # release binary at .build/.../Release/cinch-mcp
```

Run the full end-to-end smoke test (handshake + every tool, verified against the system `zip`/`tar` tools; set `MCP_BIN` to test a specific binary such as the bundled one):

```sh
scripts/mcp-smoke.sh
```

### Tools

| Tool | What it does |
|---|---|
| `archive_list` | List entries (path, kind, size, mtime, zip encryption) |
| `archive_read` | Read one entry — text as UTF-8, binary as base64 (password support) |
| `archive_extract` | Extract entries (or everything) to a directory; unsafe paths are skipped |
| `archive_create` | Create a new zip / tar / tar.gz from disk files/folders |
| `archive_add` | Add disk files/folders to an existing archive |
| `archive_write_file` | Write text or base64 content into an entry |
| `archive_delete` | Delete entries (folders recursively) |
| `archive_rename` | Rename entries/folders |
| `archive_new_folder` | Create a folder inside an archive |
| `archive_set_password` | Re-encrypt a zip AES-256 (empty password removes encryption) |

### Configuring clients

Cline (`cline_mcp_settings.json`) or Claude Desktop (`claude_desktop_config.json`) — using the bundled binary once Cinch is installed in `/Applications`:

```json
{
  "mcpServers": {
    "cinch": {
      "command": "/Applications/Cinch.app/Contents/MacOS/cinch-mcp"
    }
  }
}
```

Claude Code:

```sh
claude mcp add cinch -- /Applications/Cinch.app/Contents/MacOS/cinch-mcp
```

Passwords are passed per tool call and never persisted, matching the app's session-memory-only policy. macOS metadata entries (`__MACOSX`, `._*` AppleDouble files) are hidden from listings, as in the app.

## Project structure

```
Cinch/
├── Package.swift                 # SPM package: CinchCore (engines) + cinch-mcp server
├── Cinch/
│   ├── CinchApp.swift            # App entry point, menu commands, AppModel intents
│   ├── ContentView.swift         # Main UI: archive browsing, editing, drag & drop, saving
│   ├── LibzipArchive.swift       # libzip facade (zip engine, passwords) — shared with cinch-mcp
│   ├── TarArchive.swift          # ustar/tar.gz engine — shared with cinch-mcp
│   ├── GzipArchive.swift         # RFC 1952 gzip container — used by TarArchive
│   └── MultiColumnOutlineView.swift  # NSOutlineView-backed multi-column list (macOS only)
├── cinch-mcp/                    # MCP stdio server for AI agents (Cline, Claude, …)
├── Casks/
│   └── cinch.rb                  # Homebrew cask (this repo is the tap)
├── scripts/
│   ├── build.sh                  # Command-line build script
│   ├── mcp-smoke.sh              # End-to-end test of the cinch-mcp server
│   └── release.sh                # Build, zip and checksum a release artifact
├── CinchTests/                   # Swift Testing unit tests
├── CinchUITests/                 # UI launch tests
└── LICENSE
```

The core data model is `ZipNode` — a lightweight tree node representing a file or directory inside the archive, with name, size, and modification date. `MultiColumnOutlineView` is an `NSViewRepresentable` wrapper around `NSOutlineView`; on non-macOS platforms a stub view is compiled in its place.

## License

[MIT](LICENSE) © 2026 Kevin DeKorte
