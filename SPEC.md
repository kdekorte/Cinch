# Cinch — Specification

Cinch is a native macOS archive browser and editor for **zip** and **tar / tar.gz** archives, built with SwiftUI and AppKit. It lets users open, browse, edit, extract, and create archives — including password-protected zips — in a Finder-style multi-column outline view, without dropping to the command line.

- **Version**: 1.1 (from `MARKETING_VERSION` in `Cinch.xcodeproj/project.pbxproj`)
- **License**: MIT © 2026 Kevin DeKorte
- **Platform**: macOS only (AppKit-backed UI; non-macOS platforms compile a stub outline view)
- **Sandboxing**: App Sandbox enabled, with read-write access to user-selected files and the Downloads folder

---

## 1. Supported formats

| Format | Extensions | Browse | Edit | Passwords | Engine |
|---|---|---|---|---|---|
| Zip | `.zip` | ✅ | ✅ | ✅ read + write | libzip (via [SwiftZip](https://github.com/SwiftZip/SwiftZip) SPM package) |
| Zip containers (jar, war, ear, apk, ipa, cbz, zipx) | various | ✅ (viewer) | ✅ | — | libzip |
| Tar | `.tar` | ✅ | ✅ | — | Built-in `TarArchive` |
| Gzip-compressed tar | `.tar.gz`, `.tgz` | ✅ | ✅ | — | Built-in `TarArchive` + `Gzip` |
| 7z, RAR, other | — | ❌ | ❌ | — | Not supported |

Notes:

- 7z/RAR are not supported (would require libarchive or similar; see "Non-goals").
- `.zipx` files using non-deflate compression (PPMd, LZMA) may fail to open.
- Format detection is by filename (`TarArchive.isTarURL`); compression follows the file's own extension when writing.

### Password-protected zips

- **Reading**: both legacy **ZipCrypto** (Info-ZIP `zip -e`) and **AES-128/192/256** are supported. Opening an encrypted archive prompts for the password, verified by trial-decrypting one entry (3 attempts before failing). The password is held in memory for the session only — never persisted.
- **Writing**: **File ▸ Set Password…** repacks the archive with every entry AES-256 encrypted. An empty password removes encryption. ⌘S/Save applies the currently-set password.
- **Renaming/moving** entries uses libzip's native entry rename, so encrypted entries keep their encryption and data untouched.
- Passwords apply to zip archives only; tar archives have no password concept.

---

## 2. Features

### Browsing
- Finder-like multi-column outline view (Name, Kind, Size, Date Modified) with sortable, resizable, and reorderable columns (`NSOutlineView` via `MultiColumnOutlineView`).
- macOS metadata entries — AppleDouble `._name` companions and Finder-zip `__MACOSX` folders — are hidden from the tree (they remain inside the archive, untouched).
- Expansion state and selection are tracked by entry path and survive every tree reload.
- File preview pane (images, text, file info) for entries up to 5 MB.

### Editing (zip and tar)
- **Add files**: drag-and-drop from Finder (into a folder row, a file row's parent, or the root), File ▸ Add Files to Zip… (⌘A), or paste (⌘V).
- **Add folders**: recursive; dropped folders are staged into the app's temp container synchronously (sandbox drag grants expire after the drop operation).
- **Move entries between folders**: drag within the outline (custom pasteboard flavor `com.kdekorte.cinch.zipnode`); drop on a folder row = into it, file row = its parent, empty area = root. Guards: no moving a folder into itself, duplicate names rejected.
- **Rename**: context menu flow; rewrites entry paths (folders recursively).
- **Delete**: context menu; files and folders (with contents).
- **New folder**: context menu or toolbar; targets the right-clicked folder (or the selection / root).
- **Extract**: single file or whole folder to a chosen directory.
- **Save / Save As**: Save repacks the archive atomically; Save As duplicates to a new location.

### Creating archives
- **File ▸ New Zip Archive** (⌘N) and **File ▸ New tar.gz Archive** (⌥⌘N), plus buttons on the empty-state screen.
- Empty archives are valid from the first save (verified against system `tar`/`unzip`).

### Drag out
- Rows can be dragged from the outline to Finder (file-URL pasteboard flavor backed by temp extraction).

### Context menu (right-click)
- Selects the row under the cursor (Finder behavior), then: **New Folder**, **Rename**, **Delete**. Archive-level actions (New, Open, Set Password) live in the File menu only.

---

## 3. Architecture

```
Cinch/
├── CinchApp.swift            # @main, menu commands, AppModel intents
├── ContentView.swift         # All UI + archive operations (SwiftUI)
├── MultiColumnOutlineView.swift  # NSOutlineView wrapper: columns, sorting,
│                              #   drag & drop, context menu, expansion state
├── LibzipArchive.swift       # Facade over the libzip C API (zip operations,
│                              #   encryption read/write, rename/delete/add)
├── TarArchive.swift          # Tar reader/writer (ustar format)
├── GzipArchive.swift         # Gzip container (RFC 1952) over Apple Compression
├── Info.plist                # Bundle config + document types + icon
├── Cinch.icns                # App icon (CFBundleIconFile)
├── Casks/cinch.rb            # Homebrew cask (this repo is the tap)
└── scripts/
    ├── build.sh              # xcodebuild wrapper -> build/Cinch.app
    └── release.sh            # status | tag | package | release | cask | all
```

### Layers

1. **Engines** (no UI):
   - `Libzip` — facade over the libzip C API. All mutations open read-write, apply changes, and `zip_close` to commit; a thrown error triggers `zip_discard` (full rollback). `zip_source_buffer` memory is malloc'd with `freep=1` (libzip does not copy buffers).
   - `TarArchive` — ustar 512-byte headers, octal fields, checksums, prefix-field long paths; GNU/pax metadata entries skipped on read. All edits are read-all → transform → atomic rewrite.
   - `Gzip` — RFC 1952 container over Apple's `Compression` framework raw DEFLATE, with CRC32/ISIZE verification and full header-flag parsing.
2. **View layer** (`MultiColumnOutlineView`): `NSViewRepresentable` wrapping `OutlineViewWithMenu` (an `NSOutlineView` subclass overriding `menu(for:)`). The coordinator is the data source and delegate, and communicates upward via callbacks (`onSelect`, `onRemove`, `onDropFiles`, `onMoveNodes`, `onCreateFolder`, `onRename`).
3. **App logic** (`ContentView`): `@State`-driven; menu commands arrive as `AppModel.Intent` values handled in `.onChange`.

### Key invariants

- **Zip mutations never interleave in-place add+remove** — libzip's close-time commit replaced ZIPFoundation's in-place `.update` mode after it corrupted a central directory in the field.
- **Tar mutations always rewrite via a temp file** then atomically replace the original.
- **Drag-granted file access is used synchronously** during the drop callback (files staged to `NSTemporaryDirectory()`), because sandbox grants expire when the drag session ends.
- `ZipNode` identity (UUID) is unstable across reloads; anything that must survive a reload (expansion, selection, drop targets) is keyed by **entry path**.

### Error handling
- All user-visible failures surface in a dismissible error banner at the top of the window (`zipReadError`); extraction errors use an alert. Diagnostics log to the `com.cinch.dragdrop` os_log subsystem.

---

## 4. Document types (Launch Services)

| Type | Role | Rank | Notes |
|---|---|---|---|
| Zip Archive (`public.zip-archive` …) | Editor | Owner | `LSIsAppleDefaultForType` |
| Tar Archive (`public.tar-archive` …) | Editor | Alternate | `.tar`, `.tar.gz`, `.tgz` |
| Gzip Compressed Tar (`org.gnu.gnu-zip-archive`) | Viewer | Alternate | needed because macOS types `.tar.gz` by its final `.gz` extension |
| Zip-based containers (jar/war/ear/apk/ipa/cbz/zipx) | Viewer | Alternate | |

Double-click / Open With / Dock-drop open via `.onOpenURL` → `loadZip`.

---

## 5. Release process

`scripts/release.sh` (modeled on the basika release script) provides subcommands:

```
status | tag | package | release | cask | all
```

- Version comes from `MARKETING_VERSION` in the project file.
- `package` builds `Cinch-<v>.zip` (ditto — preserves signing metadata), `Cinch-<v>.pkg` (pkgbuild, installs to /Applications) and `Cinch-<v>-source.zip` (git archive from the tag).
- `release` requires the tag, refuses existing releases, and uploads all three artifacts via `gh release create --generate-notes` (GitHub auto-provides source links for the tag).
- `cask` downloads the published zip to compute the SHA256 and updates `Casks/cinch.rb`.
- Installation: `brew tap kdekorte/cinch https://github.com/kdekorte/Cinch` then `brew install --cask kdekorte/cinch/cinch`.
- For public distribution the app should be signed with a "Developer ID Application" certificate and notarized before packaging (`codesign`, `xcrun notarytool`, `xcrun stapler` — documented in the script header).

---

## 6. Testing & verification

The engines are verified by round-trip tests against system tools (harnesses in the git history):

- **tar**: system `tar -czf` → parse → mutate (rename folder, move file, delete) → rewrite passes `gzip -t` and `tar -tzvf`; plain `.tar` round-trips.
- **libzip**: decrypts system-created ZipCrypto; writes AES-256 entries that round-trip through the engine; wrong passwords rejected; mutations leave archives that pass `unzip -t`. (Info-ZIP `unzip` cannot read AES at all — expected, not a defect.)
- `CinchTests` contains a Swift Testing smoke test.

---

## 7. Non-goals / known limitations

- No 7z, RAR, or other archive formats.
- No password cracking; passwords are held in session memory only (no Keychain persistence).
- Tar edits rewrite the whole archive and hold entries in memory (fine for typical archives; streaming is a future optimization).
- Single selection in the outline (the move plumbing accepts arrays for future multi-select).
- `.zipx` files with exotic compression methods may not decompress.
- English UI only.
