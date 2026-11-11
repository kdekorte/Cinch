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

## Project structure

```
Cinch/
├── Cinch/
│   ├── CinchApp.swift            # App entry point, menu commands, AppModel intents
│   ├── ContentView.swift         # Main UI: archive browsing, editing, drag & drop, saving
│   └── MultiColumnOutlineView.swift  # NSOutlineView-backed multi-column list (macOS only)
├── CinchTests/                   # Swift Testing unit tests
├── CinchUITests/                 # UI launch tests
└── LICENSE
```

The core data model is `ZipNode` — a lightweight tree node representing a file or directory inside the archive, with name, size, and modification date. `MultiColumnOutlineView` is an `NSViewRepresentable` wrapper around `NSOutlineView`; on non-macOS platforms a stub view is compiled in its place.

## License

[MIT](LICENSE) © 2026 Kevin DeKorte
