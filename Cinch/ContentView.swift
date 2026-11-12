import SwiftUI
import Foundation
import ZIPFoundation
import UniformTypeIdentifiers
import os
#if canImport(AppKit)
import AppKit
#endif

struct ZipNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    var children: [ZipNode]? = nil
    let fullPath: String
    var size: Int64? = nil
    var modificationDate: Date? = nil
}

struct ContentView: View {
    @State private var zipNodes: [ZipNode] = []
    @State private var zipFileURL: URL? = nil
    @State private var showingFileImporter = false
    @State private var zipReadError: String? = nil
    @State private var selectedNode: ZipNode? = nil
    @State private var isSaving: Bool = false
    @State private var saveProgress: Double = 0.0
    @State private var saveProgressText: String = ""
    @State private var showingExtractErrorAlert: Bool = false // NEW: Extract Feature
    @State private var extractErrorMessage: String? = nil // NEW: Extract Feature
    @Environment(AppModel.self) private var appModel

    // New folder state
    @State private var showNewFolderPrompt: Bool = false
    @State private var newFolderName: String = "New Folder"

    // --- RENAME FEATURE ---
    @State private var showRenamePrompt: Bool = false
    @State private var pendingRenameNode: ZipNode? = nil
    @State private var newNodeName: String = ""

    @State private var sortOrder: [KeyPathComparator<ZipNode>] = [
        .init(\.name, order: .forward)
    ]

    // Formats Cinch can open: zip plus tar / tar.gz / tgz
    static let openableContentTypes: [UTType] = [
        .zip,
        .gzip,
        UTType("public.tar-archive") ?? .data,
        UTType(filenameExtension: "tar") ?? .data,
        UTType(filenameExtension: "tgz") ?? .gzip,
        UTType(filenameExtension: "tar.gz") ?? .gzip,
    ]

    static func isArchiveURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip" || TarArchive.isTarURL(url)
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header: archive icon, name and location
                HStack(spacing: 12) {
                    Image(systemName: "doc.zipper")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zipFileURL?.lastPathComponent ?? "No Archive Open")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let url = zipFileURL {
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Inline, dismissible error banner
                if let errorMessage = zipReadError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(errorMessage)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            zipReadError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08))
                    .overlay(alignment: .top) { Divider() }
                    .overlay(alignment: .bottom) { Divider() }
                }

                Divider()

                // Main content: list like Finder
                if zipNodes.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.zipper")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.tertiary)
                            .symbolRenderingMode(.hierarchical)
                        Text(zipFileURL != nil ? "This Archive Is Empty" : "No Archive Open")
                            .font(.title2.weight(.semibold))
                        Text(zipFileURL != nil
                             ? "Add files, drop them anywhere in the window, or create a folder."
                             : "Create a new zip archive or open an existing one to get started.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            if zipFileURL == nil {
                                Button {
                                    Task { await createNewZip() }
                                } label: {
                                    Label("New Zip", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                                Button {
                                    Task { await createNewTar() }
                                } label: {
                                    Label("New tar.gz", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    presentOpenPanel()
                                } label: {
                                    Label("Open…", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    presentAddFilesPanel()
                                } label: {
                                    Label("Add Files…", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    #if canImport(AppKit)
                    MultiColumnOutlineView(
                        roots: zipNodes,
                        selected: Binding(get: { selectedNode }, set: { selectedNode = $0 }),
                        onRemove: { removeSelectedEntry() },
                        onSelect: { node in
                            selectedNode = node
                        },
                        onDropFiles: { urls, targetFolder in
                            // Copy now, while the drop's sandbox grant is still valid
                            let staged = stageDroppedFiles(urls)
                            Task { @MainActor in
                                for url in staged {
                                    await ingestURL(url, into: targetFolder)
                                }
                            }
                        },
                        onMoveNodes: { nodes, targetFolder in
                            Task { @MainActor in
                                await moveZipNodes(nodes, into: targetFolder)
                            }
                        }
                    )
                    // NEW: Context menu for Add Folder on directories and Rename option for any node
                    .contextMenu {
                        if let selected = selectedNode {
                            if selected.isDirectory {
                                Button("Add Folder…") {
                                    showNewFolderPrompt = true
                                }
                            }
                            Button("Rename") {
                                pendingRenameNode = selected
                                newNodeName = selected.name
                                showRenamePrompt = true
                            }
                        }
                    }
                    #else
                    Text("Multi-column outline is only available on macOS.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                }

                // Optional preview below list
                if let node = selectedNode, zipFileURL != nil, node.isDirectory == false {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                                .font(.caption2)
                            Text(node.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        self.previewForZipEntry(url: zipFileURL!, node: node)
                            .frame(maxWidth: .infinity, maxHeight: 260, alignment: .topLeading)
                    }
                    .background(.thinMaterial)
                }

                // Status bar
                Divider()
                HStack(spacing: 16) {
                    Text("\(zipNodes.count) item\(zipNodes.count == 1 ? "" : "s")")
                    if let total = totalUncompressedSize {
                        Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            .monospacedDigit()
                    }
                    Spacer()
                    if let url = zipFileURL {
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await createNewZip() }
                    } label: {
                        Label("New", systemImage: "doc.badge.plus")
                    }
                    .help("Create a new zip archive")

                    Button {
                        presentOpenPanel()
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .help("Open an existing zip archive")

                    Button {
                        if zipFileURL != nil { presentAddFilesPanel() }
                    } label: {
                        Label("Add Files", systemImage: "plus")
                    }
                    .disabled(zipFileURL == nil)
                    .help("Add files to the archive")

                    Button {
                        showNewFolderPrompt = true
                    } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(zipFileURL == nil)
                    .help("Add a new folder to the archive")

                    Button {
                        Task { await extractSelectedEntry() }
                    } label: {
                        Label("Extract", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedNode == nil || zipFileURL == nil)
                    .help("Extract the selected entry")

                    Button {
                        Task { await repackCurrentZipWithProgress() }
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(zipFileURL == nil)
                    .help("Save changes to the archive")

                    Button(role: .destructive) {
                        removeSelectedEntry()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(selectedNode == nil || zipFileURL == nil)
                    .help("Remove the selected entry")

                    Button {
                        // Close current zip
                        zipFileURL = nil
                        zipNodes = []
                        selectedNode = nil
                        zipReadError = nil
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                    .disabled(zipFileURL == nil)
                    .help("Close the current archive")
                }
            }
            .onChange(of: appModel.intent) { _, newValue in
                guard let intent = newValue else { return }
                switch intent {
                case .newDocument:
                    Task { await createNewZip() } // NEW: New Zip Creation // FIX: Added missing await to async call
                case .newTarDocument:
                    Task { await createNewTar() }
                case .open:
                    presentOpenPanel()
                case .saveAs:
                    saveAsCopy()
                case .save:
                    Task { await repackCurrentZipWithProgress() }
                case .quit:
                    break
                case .addFiles:
                    if zipFileURL != nil { presentAddFilesPanel() }
                }
                appModel.intent = nil
            }

            if isSaving {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView(value: saveProgress) {
                        Text("Saving…")
                            .font(.headline)
                    } currentValueLabel: {
                        Text(saveProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 280)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            }
        }
        // NEW: Extract Feature - Alert for extraction errors
        .alert("Extraction Failed", isPresented: $showingExtractErrorAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(extractErrorMessage ?? "Unknown error")
        })
        // New Folder Alert with text field
        .alert("New Folder", isPresented: $showNewFolderPrompt, actions: {
            TextField("Folder Name", text: $newFolderName)
            Button("Add") {
                Task {
                    await addNewFolder(toParent: (selectedNode?.isDirectory == true) ? selectedNode : nil)
                }
            }
            Button("Cancel", role: .cancel) { }
        }, message: {
            Text("Enter a name for the new folder.")
        })
        // --- RENAME FEATURE ---
        .alert("Rename Entry", isPresented: $showRenamePrompt, actions: {
            TextField("New Name", text: $newNodeName)
            Button("Rename") {
                guard let node = pendingRenameNode else { return }
                Task {
                    await renameZipNode(node, to: newNodeName)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRenameNode = nil
                newNodeName = ""
            }
        }, message: {
            Text("Enter a new name for \"\(pendingRenameNode?.name ?? "")\".")
        })
        // NEW: Drag and Drop Add - accept drops anywhere in the window,
        // including the empty state shown for a new/empty archive
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            Task {
                await handleDroppedProvidersAsync(providers)
            }
            return true
        }
        // Document handler: open zips launched via Finder, "Open With" or the Dock icon
        .onOpenURL { url in
            Task { @MainActor in
                await loadZip(at: url)
            }
        }
        // NEW: Paste (⌘V) support - add files/folders from the pasteboard to the open archive
        #if canImport(AppKit)
        .onAppear {
            PasteRouter.handlePaste = { self.handlePasteFromPasteboard() }
            PasteRouter.installMonitor()
        }
        .onDisappear {
            PasteRouter.removeMonitor()
        }
        #endif
    }

    // NEW: Extract Feature - Extract selected entry
    @MainActor
    private func extractSelectedEntry() async {
        #if canImport(AppKit)
        guard let zipURL = zipFileURL, let node = selectedNode else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Destination Folder"
        panel.title = "Extract To Folder"
        panel.begin { response in
            if response == .OK, let destinationURL = panel.url {
                do {
                    // tar archives: write entry data directly to the destination
                    if TarArchive.isTarURL(zipURL) {
                        let fm = FileManager.default
                        let entries = try TarArchive.read(url: zipURL)
                        if node.isDirectory {
                            let prefix = node.fullPath.hasSuffix("/") ? node.fullPath : node.fullPath + "/"
                            for entry in entries where entry.path == prefix || entry.path.hasPrefix(prefix) {
                                let dest = destinationURL.appendingPathComponent(entry.path)
                                if entry.isDirectory {
                                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                                } else {
                                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                                    try entry.data.write(to: dest)
                                }
                            }
                        } else if let entry = entries.first(where: { $0.path == node.fullPath }) {
                            let dest = destinationURL.appendingPathComponent(entry.path)
                            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try entry.data.write(to: dest)
                        } else {
                            setExtractError("Selected file not found in archive.")
                        }
                        return
                    }
                    guard let archive = try? Archive(url: zipURL, accessMode: .read, pathEncoding: nil) else {
                        setExtractError("Could not open archive for reading.")
                        return
                    }
                    if node.isDirectory {
                        // Extract all entries under this directory
                        let prefix = node.fullPath.hasSuffix("/") ? node.fullPath : node.fullPath + "/"
                        for entry in archive {
                            if entry.path == prefix || entry.path.hasPrefix(prefix) {
                                _ = try archive.extract(entry, to: destinationURL.appendingPathComponent(entry.path))
                            }
                        }
                    } else {
                        // Extract single file
                        if let entry = archive.first(where: { $0.path == node.fullPath }) {
                            _ = try archive.extract(entry, to: destinationURL.appendingPathComponent(entry.path))
                        } else {
                            setExtractError("Selected file not found in archive.")
                            return
                        }
                    }
                } catch {
                    setExtractError(error.localizedDescription)
                }
            }
        }
        #endif
    }

    // NEW: Extract Feature - Helper to set and show extract error alert
    @MainActor
    private func setExtractError(_ message: String) {
        extractErrorMessage = message
        showingExtractErrorAlert = true
    }

    // NEW: New Zip Creation
    @MainActor
    private func createNewZip() async {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.nameFieldStringValue = "NewArchive.zip"
        panel.canCreateDirectories = true
        panel.title = "Create New ZIP Archive"
        panel.prompt = "Create"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    // Create empty archive
                    let fm = FileManager.default
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                    }
                    // Create empty archive (result unused; we only need the file to exist)
                    guard (try? Archive(url: url, accessMode: .create, pathEncoding: nil)) != nil else {
                        zipReadError = "Failed to create archive at \(url.path)"
                        return
                    }
                    DispatchQueue.main.async {
                        zipFileURL = url
                        zipNodes = []
                        selectedNode = nil
                        zipReadError = nil
                    }
                } catch {
                    DispatchQueue.main.async {
                        zipReadError = "Failed to create new zip: \(error.localizedDescription)"
                    }
                }
            }
        }
        #else
        // Fallback for other platforms: clear state
        zipFileURL = nil
        zipNodes = []
        selectedNode = nil
        zipReadError = nil
        #endif
    }

    // NEW: New tar.gz Creation
    @MainActor
    private func createNewTar() async {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType("public.tar-archive") ?? .data,
            UTType(filenameExtension: "tgz") ?? .gzip,
            UTType(filenameExtension: "tar.gz") ?? .gzip,
        ]
        panel.nameFieldStringValue = "NewArchive.tar.gz"
        panel.canCreateDirectories = true
        panel.title = "Create New tar.gz Archive"
        panel.prompt = "Create"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                    }
                    // Write an empty (gzip-compressed) tar
                    try TarArchive.write([], to: url)
                    DispatchQueue.main.async {
                        zipFileURL = url
                        zipNodes = []
                        selectedNode = nil
                        zipReadError = nil
                    }
                } catch {
                    DispatchQueue.main.async {
                        zipReadError = "Failed to create new archive: \(error.localizedDescription)"
                    }
                }
            }
        }
        #else
        // Fallback for other platforms: clear state
        zipFileURL = nil
        zipNodes = []
        selectedNode = nil
        zipReadError = nil
        #endif
    }

    // NEW: RENAME FEATURE - Rename node (file or folder) in the zip
    @MainActor
    private func renameZipNode(_ node: ZipNode, to newName: String) async {
        guard let zipURL = zipFileURL else { return }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            zipReadError = "Name cannot be empty."
            return
        }
        // Validate newName does not contain "/" or backslash or ":" etc.
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        if trimmedName.rangeOfCharacter(from: invalidCharacters) != nil {
            zipReadError = "Name contains invalid characters."
            return
        }

        do {
            guard let archive = try? Archive(url: zipURL, accessMode: .update, pathEncoding: nil) else {
                zipReadError = "Failed to open archive for update."
                return
            }

            // Determine parent path prefix (folder path)
            let oldFullPath = node.fullPath
            let parentPath: String
            if let lastSlashIndex = oldFullPath.lastIndex(of: "/"), node.isDirectory == false {
                // Use string.index(_:offsetBy:) to get index after last slash
                let idx = oldFullPath.index(lastSlashIndex, offsetBy: 1)
                parentPath = String(oldFullPath[..<idx]) // include slash
            } else if node.isDirectory {
                // For directory, the fullPath ends with "/"
                // Remove last component + slash
                var path = oldFullPath
                if path.hasSuffix("/") {
                    path.removeLast()
                }
                if let lastSlashIndex = path.lastIndex(of: "/") {
                    let idx = path.index(lastSlashIndex, offsetBy: 1)
                    parentPath = String(path[..<idx])
                } else {
                    parentPath = ""
                }
            } else {
                // No parent folder
                parentPath = ""
            }

            let newFullPath: String
            if node.isDirectory {
                newFullPath = parentPath + trimmedName + "/"
            } else {
                newFullPath = parentPath + trimmedName
            }

            // tar archives: rewrite entry paths with the new name
            if TarArchive.isTarURL(zipURL) {
                let oldFullPath = node.fullPath
                mutateTar { entries in
                    guard !entries.contains(where: { $0.path == newFullPath || $0.path.hasPrefix(newFullPath) }) else {
                        throw DuplicateEntryError(name: trimmedName)
                    }
                    if node.isDirectory {
                        let prefix = oldFullPath.hasSuffix("/") ? oldFullPath : oldFullPath + "/"
                        for i in entries.indices {
                            if entries[i].path == prefix || entries[i].path.hasPrefix(prefix) {
                                entries[i].path = newFullPath + String(entries[i].path.dropFirst(prefix.count))
                            }
                        }
                    } else {
                        for i in entries.indices where entries[i].path == oldFullPath {
                            entries[i].path = newFullPath
                        }
                    }
                }
                selectedNode = nil
                pendingRenameNode = nil
                newNodeName = ""
                return
            }

            // Check if new name already exists in archive
            if archive.contains(where: { $0.path == newFullPath }) {
                zipReadError = "An entry with the new name already exists."
                return
            }

            if node.isDirectory {
                // Rename folder: copy all entries under oldFullPath prefix to newFullPath prefix, then remove old entries
                let prefix = oldFullPath.hasSuffix("/") ? oldFullPath : oldFullPath + "/"
                let newPrefix = newFullPath

                var entriesToRename: [ZIPFoundation.Entry] = []
                for entry in archive {
                    if entry.path == prefix || entry.path.hasPrefix(prefix) {
                        entriesToRename.append(entry)
                    }
                }

                // Copy entries with new paths
                for entry in entriesToRename {
                    let relativePath = String(entry.path.dropFirst(prefix.count))
                    let targetPath = newPrefix + relativePath
                    // Check target path doesn't exist (should not due to above check, but be safe)
                    if archive.contains(where: { $0.path == targetPath }) {
                        zipReadError = "Conflict while renaming entries."
                        return
                    }
                    // Extract data for entry
                    var entryData = Data()
                    _ = try archive.extract(entry) { chunk in
                        entryData.append(chunk)
                    }
                    // Add new entry with same attributes
                    // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                    try archive.addEntry(with: targetPath, type: entry.type, uncompressedSize: Int64(entryData.count), provider: { position, size in
                        let start = Int(position)
                        let end = min(start + Int(size), entryData.count)
                        return entryData.subdata(in: start..<end)
                    })
                }
                // Remove old entries
                for entry in entriesToRename {
                    try archive.remove(entry)
                }
            } else {
                // Rename single file entry
                guard let oldEntry = archive.first(where: { $0.path == oldFullPath }) else {
                    zipReadError = "Original file entry not found."
                    return
                }
                // Extract data
                var data = Data()
                _ = try archive.extract(oldEntry) { chunk in
                    data.append(chunk)
                }
                // Add new entry
                // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                try archive.addEntry(with: newFullPath, type: oldEntry.type, uncompressedSize: Int64(data.count), provider: { position, size in
                    let start = Int(position)
                    let end = min(start + Int(size), data.count)
                    return data.subdata(in: start..<end)
                })
                // Remove old entry
                try archive.remove(oldEntry)
            }

            // Refresh tree and clear rename state
            zipNodes = try readZipNodes(url: zipURL)
            selectedNode = nil
            pendingRenameNode = nil
            newNodeName = ""
        } catch {
            zipReadError = "Rename failed: \(error.localizedDescription)"
        }
    }

    // NEW: MOVE FEATURE - Move nodes (files or folders) into another folder (nil = root)
    @MainActor
    private func moveZipNodes(_ nodes: [ZipNode], into folder: ZipNode?) async {
        guard let zipURL = zipFileURL else { return }
        for node in nodes {
            await moveZipNode(node, into: folder, zipURL: zipURL)
        }
    }

    @MainActor
    private func moveZipNode(_ node: ZipNode, into folder: ZipNode?, zipURL: URL) async {
        // Target folder path prefix ("" = root)
        var folderPrefix = ""
        if let folder = folder {
            let p = folder.fullPath
            folderPrefix = p.hasSuffix("/") ? p : p + "/"
            // Guard: cannot move a folder into itself or one of its descendants
            if node.isDirectory {
                let nodePrefix = node.fullPath.hasSuffix("/") ? node.fullPath : node.fullPath + "/"
                if folder.fullPath == node.fullPath || folderPrefix.hasPrefix(nodePrefix) {
                    zipReadError = "Cannot move a folder into itself."
                    return
                }
            }
        }

        // Compute the new full path (keep the same name, change the parent)
        let oldFullPath = node.fullPath
        let name = node.isDirectory
            ? String(node.fullPath.dropLast(node.fullPath.hasSuffix("/") ? 1 : 0).split(separator: "/").last ?? "")
            : node.name
        let newFullPath = folderPrefix + name + (node.isDirectory ? "/" : "")

        // No-op if the entry already lives in that folder
        let normalizedOld = node.isDirectory && oldFullPath.hasSuffix("/")
            ? String(oldFullPath.dropLast()) : oldFullPath
        let normalizedNew = node.isDirectory && newFullPath.hasSuffix("/")
            ? String(newFullPath.dropLast()) : newFullPath
        if normalizedOld == normalizedNew { return }

        // tar archives: rewrite entry paths under the new parent
        if TarArchive.isTarURL(zipURL) {
            let dirPrefix = oldFullPath.hasSuffix("/") ? oldFullPath : oldFullPath + "/"
            mutateTar { entries in
                let conflict: Bool
                if node.isDirectory {
                    conflict = entries.contains { $0.path == newFullPath || $0.path.hasPrefix(newFullPath) }
                } else {
                    conflict = entries.contains { $0.path == newFullPath }
                }
                guard !conflict else { throw DuplicateEntryError(name: node.name) }
                for i in entries.indices {
                    if node.isDirectory {
                        if entries[i].path == dirPrefix || entries[i].path.hasPrefix(dirPrefix) {
                            entries[i].path = newFullPath + String(entries[i].path.dropFirst(dirPrefix.count))
                        }
                    } else if entries[i].path == oldFullPath {
                        entries[i].path = newFullPath
                    }
                }
            }
            ContentView.dropLogger.debug("moveZipNode: moved \(oldFullPath, privacy: .public) -> \(newFullPath, privacy: .public)")
            return
        }

        let fm = FileManager.default
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        do {
            guard let readArchive = try? Archive(url: zipURL, accessMode: .read, pathEncoding: nil) else {
                zipReadError = "Failed to open archive for reading."
                return
            }

            // Check the destination does not already contain an entry with this name
            let conflict: Bool
            if node.isDirectory {
                conflict = readArchive.contains { $0.path == newFullPath || $0.path.hasPrefix(newFullPath) }
            } else {
                conflict = readArchive.contains { $0.path == newFullPath }
            }
            if conflict {
                zipReadError = "An entry named \"\(node.name)\" already exists in that folder."
                return
            }

            // Rewrite the archive entry-by-entry into a fresh temp file instead of
            // mutating in place: interleaving addEntry/remove on an archive open in
            // .update mode can corrupt the central directory.
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard let writeArchive = try? Archive(url: tempURL, accessMode: .create, pathEncoding: nil) else {
                zipReadError = "Could not create temp archive."
                return
            }

            let dirPrefix = oldFullPath.hasSuffix("/") ? oldFullPath : oldFullPath + "/"
            for entry in readArchive {
                let targetPath: String
                if node.isDirectory {
                    targetPath = (entry.path == dirPrefix || entry.path.hasPrefix(dirPrefix))
                        ? newFullPath + String(entry.path.dropFirst(dirPrefix.count))
                        : entry.path
                } else {
                    targetPath = (entry.path == oldFullPath) ? newFullPath : entry.path
                }

                var entryData = Data()
                _ = try readArchive.extract(entry) { chunk in
                    entryData.append(chunk)
                }
                // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                try writeArchive.addEntry(with: targetPath, type: entry.type, uncompressedSize: Int64(entryData.count), provider: { position, size in
                    let start = Int(position)
                    let end = min(start + Int(size), entryData.count)
                    return entryData.subdata(in: start..<end)
                })
            }

            // Atomically replace the original
            if fm.fileExists(atPath: zipURL.path) {
                try fm.removeItem(at: zipURL)
            }
            try fm.moveItem(at: tempURL, to: zipURL)

            // Refresh tree
            zipNodes = try readZipNodes(url: zipURL)
            ContentView.dropLogger.debug("moveZipNode: moved \(oldFullPath, privacy: .public) -> \(newFullPath, privacy: .public)")
        } catch {
            zipReadError = "Move failed: \(error.localizedDescription)"
            try? fm.removeItem(at: tempURL)
        }
    }

    // Helper: extract limited-size data for preview from an entry in the zip
    private func previewData(from url: URL, fullPath: String, maxBytes: Int = 5 * 1024 * 1024) -> Data? {
        // tar archives: entry data comes from the parsed tar
        if TarArchive.isTarURL(url),
           let entry = (try? TarArchive.read(url: url))?.first(where: { $0.path == fullPath }) {
            guard entry.data.count <= maxBytes else { return nil }
            return entry.data
        }
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            return nil
        }
        guard let entry = archive.first(where: { $0.path == fullPath }) else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                if data.count < maxBytes {
                    data.append(chunk)
                }
            }
        } catch {
            return nil
        }
        return data
    }

    // Preview generator for files in the zip
    @ViewBuilder
    private func previewForZipEntry(url: URL, node: ZipNode) -> some View {
        if let data = previewData(from: url, fullPath: node.fullPath) {
            if data.isEmpty {
                Text("(Empty file)").italic()
            }
            else if let imageView = imageView(from: data) {
                imageView
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .padding()
            }
            else if let text = String(data: data, encoding: .utf8), text.isPrintable {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.name).font(.title2)
                    Text("Size: \(data.count) bytes").foregroundStyle(.secondary)
                    Text("(Preview not available)")
                        .foregroundStyle(.tertiary)
                }.padding()
            }
        } else {
            Text("File not found in zip.")
        }
    }

    // Save As: duplicate current zip to a chosen location
    private func saveAsCopy() {
        guard let sourceURL = zipFileURL else { return }
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = ContentView.openableContentTypes
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                do {
                    // Overwrite if exists
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                } catch {
                    zipReadError = "Save As failed: \(error.localizedDescription)"
                }
            }
        }
        #endif
    }

    // Show an Open Panel to add files into the current zip
    private func presentAddFilesPanel() {
        #if canImport(AppKit)
        guard zipFileURL != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if let selected = selectedNode, selected.isDirectory {
                        addFileToZip(zipURL: zipFileURL!, fileURL: url, atPath: selected.fullPath)
                    } else {
                        addFileToZip(zipURL: zipFileURL!, fileURL: url, atPath: nil)
                    }
                }
            }
        }
        #endif
    }

    // Add new folder entry to zip, in optional parent folder
    @MainActor
    private func addNewFolder(toParent parentNode: ZipNode?) async {
        guard let zipURL = zipFileURL else { return }
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return }
        // Compose full path for the new folder (always end with "/")
        var folderPath: String
        if let parent = parentNode {
            let prefix = parent.fullPath.hasSuffix("/") ? parent.fullPath : parent.fullPath + "/"
            folderPath = prefix + folderName + "/"
        } else {
            folderPath = folderName + "/"
        }
        // tar archives: append a directory entry and rewrite
        if TarArchive.isTarURL(zipURL) {
            mutateTar { entries in
                guard !entries.contains(where: { $0.path == folderPath }) else {
                    throw DuplicateEntryError(name: folderName)
                }
                entries.append(TarEntry(path: folderPath, data: Data(), modificationDate: Date(), permissions: 0o755))
            }
            selectedNode = nil
            newFolderName = "New Folder"
            return
        }
        guard let archive = try? Archive(url: zipURL, accessMode: .update, pathEncoding: nil) else { return }
        do {
            // Add directory entry with empty data
            // FIX: supply the full parameter list to resolve the ambiguous addEntry overload
            try archive.addEntry(
                with: folderPath,
                type: .directory,
                uncompressedSize: Int64(0),
                modificationDate: Date(),
                permissions: nil,
                compressionMethod: .none,
                bufferSize: 65536,
                progress: nil,
                provider: { _, _ in
                    return Data()
                }
            )
            // Refresh tree
            zipNodes = try readZipNodes(url: zipURL)
            selectedNode = nil
            newFolderName = "New Folder"
        } catch {
            zipReadError = "Failed to add folder: \(error.localizedDescription)"
        }
    }

    // Total uncompressed size of all file entries, for the status bar
    private var totalUncompressedSize: Int64? {
        guard !zipNodes.isEmpty else { return nil }
        func sum(_ nodes: [ZipNode]) -> Int64 {
            nodes.reduce(0) { acc, node in
                acc + (node.size ?? 0) + (node.children.map(sum) ?? 0)
            }
        }
        return sum(zipNodes)
    }

    // Compute current listing; for now we show top-level entries
    private func currentListingNodes() -> [ZipNode] {
        return zipNodes
    }

    // Handle taps: if directory, select it (future: navigate); if file, select for preview
    private func handleTap(on node: ZipNode) {
        selectedNode = node
        // Future enhancement: push into directories
    }

    // Remove selected file entry from the zip (files only)
    private func removeSelectedEntry() {
        guard let node = selectedNode, node.isDirectory == false, let zipURL = zipFileURL else { return }
        // tar archives: rewrite without the entry
        if TarArchive.isTarURL(zipURL) {
            mutateTar { entries in
                entries.removeAll { $0.path == node.fullPath }
            }
            selectedNode = nil
            return
        }
        guard let archive = try? Archive(url: zipURL, accessMode: .update, pathEncoding: nil) else { return }
        guard let entry = archive.first(where: { $0.path == node.fullPath }) else {
            zipReadError = "Entry not found in archive."
            return
        }
        do {
            try archive.remove(entry)
            // Refresh tree
            zipNodes = try readZipNodes(url: zipURL)
            selectedNode = nil
        } catch {
            zipReadError = "Failed to remove entry: \(error.localizedDescription)"
        }
    }

    // Show an Open Panel to choose a zip file to open
    private func presentOpenPanel() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { await loadZip(at: url) }
            }
        }
        #else
        // Fallback for platforms without AppKit
        showingFileImporter = true
        #endif
    }

    // Async repack with progress UI
    private func bytesString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @MainActor
    private func beginSaving(totalBytes: Int64) {
        isSaving = true
        saveProgress = 0
        saveProgressText = "0 of \(bytesString(totalBytes))"
    }

    @MainActor
    private func updateSaving(doneBytes: Int64, totalBytes: Int64) {
        saveProgress = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
        saveProgressText = "\(bytesString(doneBytes)) of \(bytesString(totalBytes))"
    }

    @MainActor
    private func endSaving() {
        isSaving = false
    }

    private func repackCurrentZipWithProgress() async {
        guard let sourceURL = zipFileURL else { return }
        // tar archives: normalize by reading and rewriting the archive
        if TarArchive.isTarURL(sourceURL) {
            mutateTar { _ in }
            return
        }
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        do {
            // Read from source and write all entries into a new archive at tempURL
            guard let readArchive = try? Archive(url: sourceURL, accessMode: .read, pathEncoding: nil) else {
                zipReadError = "Could not open archive for reading."
                return
            }
            // Ensure temp file does not exist
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard let writeArchive = try? Archive(url: tempURL, accessMode: .create, pathEncoding: nil) else {
                zipReadError = "Could not create temp archive."
                return
            }
            for entry in readArchive {
                // Copy entries by streaming
                var entryData = Data()
                _ = try readArchive.extract(entry) { data in
                    entryData.append(data)
                }
                // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                try writeArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: Int64(entryData.count), provider: { position, size in
                    let start = Int(position)
                    let end = min(start + Int(size), entryData.count)
                    return entryData.subdata(in: start..<end)
                })
            }
            // Atomically replace original
            if fm.fileExists(atPath: sourceURL.path) {
                try fm.removeItem(at: sourceURL)
            }
            try fm.moveItem(at: tempURL, to: sourceURL)
            // Refresh the tree after mutation
            zipNodes = try readZipNodes(url: sourceURL)
        } catch {
            zipReadError = "Save failed: \(error.localizedDescription)"
            // Cleanup temp on failure
            try? fm.removeItem(at: tempURL)
        }
        endSaving()
    }

    // Repack the current zip to a temp file and atomically replace the original
    private func repackCurrentZip() {
        guard let sourceURL = zipFileURL else { return }
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        do {
            // Read from source and write all entries into a new archive at tempURL
            guard let readArchive = try? Archive(url: sourceURL, accessMode: .read, pathEncoding: nil) else {
                zipReadError = "Could not open archive for reading."
                return
            }
            // Ensure temp file does not exist
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard let writeArchive = try? Archive(url: tempURL, accessMode: .create, pathEncoding: nil) else {
                zipReadError = "Could not create temp archive."
                return
            }
            for entry in readArchive {
                // Copy entries by streaming
                var entryData = Data()
                _ = try readArchive.extract(entry) { data in
                    entryData.append(data)
                }
                // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                try writeArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: Int64(entryData.count), provider: { position, size in
                    let start = Int(position)
                    let end = min(start + Int(size), entryData.count)
                    return entryData.subdata(in: start..<end)
                })
            }
            // Atomically replace original
            if fm.fileExists(atPath: sourceURL.path) {
                try fm.removeItem(at: sourceURL)
            }
            try fm.moveItem(at: tempURL, to: sourceURL)
            // Refresh the tree after mutation
            zipNodes = try readZipNodes(url: sourceURL)
        } catch {
            zipReadError = "Save failed: \(error.localizedDescription)"
            // Cleanup temp on failure
            try? fm.removeItem(at: tempURL)
        }
    }

    // Tar archives are edited by reading all entries, transforming them, and
    // rewriting the whole archive (the same safe pattern used for zip moves).
    @MainActor
    private func mutateTar(_ transform: (inout [TarEntry]) throws -> Void) {
        guard let url = zipFileURL else { return }
        do {
            var entries = try TarArchive.read(url: url)
            try transform(&entries)
            try TarArchive.write(entries, to: url)
            zipNodes = try readZipNodes(url: url)
        } catch {
            zipReadError = "Archive operation failed: \(error.localizedDescription)"
        }
    }

    private struct DuplicateEntryError: LocalizedError {
        let name: String
        var errorDescription: String? { "An entry named \"\(name)\" already exists." }
    }

    // NEW: Drag and Drop Add - stage dropped files into our temp container.
    // The App Sandbox only grants access to drag-dropped URLs during the drop
    // operation itself, so we must copy them synchronously (inside the drop
    // callback) before deferring the zip work to a Task.
    private func stageDroppedFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let stagingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CinchDropStaging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            ContentView.dropLogger.error("stageDroppedFiles: could not create staging dir: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var staged: [URL] = []
        for url in urls {
            let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.copyItem(at: url, to: dest)
                staged.append(dest)
            } catch {
                ContentView.dropLogger.error("stageDroppedFiles: could not copy \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return staged
    }

    // NEW: Drag and Drop Add + Paste - shared ingestion for a single file/folder URL
    private static let dropLogger = Logger(subsystem: "com.cinch.dragdrop", category: "ingest")

    private func ingestURL(_ url: URL, into folder: ZipNode? = nil) async {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            ContentView.dropLogger.error("ingestURL: file does not exist (or is inaccessible): \(url.path, privacy: .public)")
            zipReadError = "Could not access \(url.lastPathComponent)."
            return
        }

        // No archive open: opening a dropped/pasted archive loads it
        if zipFileURL == nil {
            if ContentView.isArchiveURL(url) {
                await loadZip(at: url)
            } else {
                zipReadError = "Create or open an archive before adding files."
            }
            return
        }

        // Add into the explicitly targeted folder when given, else the selected
        // folder when one is selected, otherwise at the root
        let pathPrefix: String?
        if let folder = folder, folder.isDirectory {
            pathPrefix = folder.fullPath
        } else if let selected = selectedNode, selected.isDirectory {
            pathPrefix = selected.fullPath
        } else {
            pathPrefix = nil
        }
        ContentView.dropLogger.debug("ingestURL: adding \(url.lastPathComponent, privacy: .public) (isDir=\(isDir.boolValue)) into \(pathPrefix ?? "root", privacy: .public)")

        if isDir.boolValue {
            await addFolderToZip(url)
        } else {
            addFileToZip(zipURL: zipFileURL!, fileURL: url, atPath: pathPrefix)
        }
    }

    // NEW: Paste (⌘V) - add file URLs currently on the pasteboard to the open archive
    #if canImport(AppKit)
    @MainActor
    private func handlePasteFromPasteboard() {
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls {
                await ingestURL(url)
            }
        }
    }
    #endif

    // NEW: Drag and Drop Add - handle files and directories dropped
    private func handleDroppedProvidersAsync(_ providers: [NSItemProvider]) async {
        ContentView.dropLogger.debug("SwiftUI onDrop received \(providers.count) provider(s), types: \(providers.map(\.registeredTypeIdentifiers), privacy: .public)")
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                  let url = await loadURL(from: provider) else {
                ContentView.dropLogger.error("SwiftUI onDrop: provider yielded no file URL")
                continue
            }
            await ingestURL(url)
        }
    }

    @MainActor
    private func loadZip(at url: URL) async {
        do {
            zipFileURL = url
            zipNodes = try readZipNodes(url: url)
            selectedNode = nil
            zipReadError = nil
        } catch {
            zipNodes = []
            selectedNode = nil
            zipReadError = "Failed to read zip file: \(error.localizedDescription)"
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // Add file to zip at optional path prefix
    private func addFileToZip(zipURL: URL, fileURL: URL, atPath pathPrefix: String?) {
        // tar archives: append the file as a new entry and rewrite
        if TarArchive.isTarURL(zipURL) {
            let fileName = fileURL.lastPathComponent
            let targetPath: String
            if let prefix = pathPrefix {
                let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
                targetPath = normalizedPrefix + fileName
            } else {
                targetPath = fileName
            }
            mutateTar { entries in
                guard !entries.contains(where: { $0.path == targetPath }) else {
                    throw DuplicateEntryError(name: fileName)
                }
                let data = try Data(contentsOf: fileURL)
                entries.append(TarEntry(path: targetPath, data: data, modificationDate: Date(), permissions: 0o644))
            }
            return
        }
        guard let archive = try? Archive(url: zipURL, accessMode: .update, pathEncoding: nil) else {
            ContentView.dropLogger.error("addFileToZip: could not open archive for update: \(zipURL.path, privacy: .public)")
            zipReadError = "Could not open \(zipURL.lastPathComponent) for writing."
            return
        }
        let fileName = fileURL.lastPathComponent
        let targetPath: String
        if let prefix = pathPrefix {
            let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
            targetPath = normalizedPrefix + fileName
        } else {
            targetPath = fileName
        }
        do {
            // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
            try archive.addEntry(with: targetPath, relativeTo: fileURL.deletingLastPathComponent())
            ContentView.dropLogger.debug("addFileToZip: added entry \(targetPath, privacy: .public)")
            // refresh tree
            zipNodes = try readZipNodes(url: zipURL)
            ContentView.dropLogger.debug("addFileToZip: refreshed tree, \(self.zipNodes.count, privacy: .public) root node(s)")
        } catch {
            ContentView.dropLogger.error("addFileToZip: failed: \(error.localizedDescription, privacy: .public)")
            zipReadError = "Failed to add file: \(error.localizedDescription)"
        }
    }

    // NEW: Drag and Drop Add - Add folder recursively to zip
    private func addFolderToZip(_ folderURL: URL) async {
        guard let zipURL = zipFileURL else { return }
        // tar archives: append the folder's contents as new entries and rewrite
        if TarArchive.isTarURL(zipURL) {
            let fm = FileManager.default
            let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil)
            let base = folderURL.deletingLastPathComponent().path + "/"
            var newEntries: [TarEntry] = []
            let topEntry = TarEntry(path: folderURL.lastPathComponent + "/", data: Data(), modificationDate: Date(), permissions: 0o755)
            newEntries.append(topEntry)
            while let item = enumerator?.nextObject() as? URL {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
                let relativePath = item.path.replacingOccurrences(of: base, with: "")
                if isDir.boolValue {
                    newEntries.append(TarEntry(path: relativePath + "/", data: Data(), modificationDate: Date(), permissions: 0o755))
                } else {
                    let data = try? Data(contentsOf: item)
                    newEntries.append(TarEntry(path: relativePath, data: data ?? Data(), modificationDate: Date(), permissions: 0o644))
                }
            }
            mutateTar { entries in
                guard !entries.contains(where: { $0.path == topEntry.path }) else {
                    throw DuplicateEntryError(name: folderURL.lastPathComponent)
                }
                entries.append(contentsOf: newEntries)
            }
            return
        }
        guard let archive = try? Archive(url: zipURL, accessMode: .update, pathEncoding: nil) else { return }
        let fm = FileManager.default

        let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil)
        do {
            while let item = enumerator?.nextObject() as? URL {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        // ZIP format stores directories implicitly by entries with trailing slash
                        // We can skip explicit directory entries as ZIPFoundation does not require them
                        continue
                    } else {
                        // Compute relative path from the folderURL's parent directory to preserve folder structure
                        let relativePath = item.path.replacingOccurrences(of: folderURL.deletingLastPathComponent().path + "/", with: "")
                        // Add file entry with relative path to preserve subfolder structure
                        // FIX: Use minimal addEntry signature WITHOUT compressionMethod property to avoid build errors
                        try archive.addEntry(with: relativePath, relativeTo: folderURL.deletingLastPathComponent())
                    }
                }
            }
            // Refresh tree after adding folder contents
            zipNodes = try readZipNodes(url: zipURL)
        } catch {
            zipReadError = "Failed to add folder to zip: \(error.localizedDescription)"
        }
    }
}

extension ContentView {
    // Cross-platform helper to build a SwiftUI Image from raw data
    fileprivate func imageView(from data: Data) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }
}

#if canImport(AppKit)
/// Routes ⌘V from a local event monitor into the active ContentView.
/// Cinch is a single-window app, so a static route is sufficient.
private enum PasteRouter {
    static var handlePaste: (() -> Void)? = nil
    static var monitor: Any? = nil

    static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                // Let text fields (rename / new-folder alerts use a field editor,
                // which is an NSTextView) paste text normally.
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return event
                }
                // Only consume the event when the pasteboard holds file URLs
                let urls = NSPasteboard.general.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL]
                if let urls, !urls.isEmpty {
                    handlePaste?()
                    return nil // consumed
                }
            }
            return event
        }
    }

    static func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        handlePaste = nil
    }
}
#endif

extension String {
    var isPrintable: Bool {

        // Consider a string printable if it contains no control characters except whitespace and newlines
        return !self.unicodeScalars.contains { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                // Allow common whitespace characters
                return scalar != "\n" && scalar != "\r" && scalar != "\t"
            }
            return false
        }
    }
}

// True for entries that are macOS metadata, not real user files:
// "._name" AppleDouble companions (xattrs/resource forks) and the
// "__MACOSX" folder Finder's "Compress" adds to zips.
func isMacOSMetadataPath(_ path: String) -> Bool {
    if path.hasPrefix("__MACOSX/") || path == "__MACOSX" { return true }
    let name = path.split(separator: "/").last ?? Substring(path)
    return name.hasPrefix("._")
}

// Helper function for file/folder tree
func readZipNodes(url: URL) throws -> [ZipNode] {
    var root: [String: ZipNode] = [:]

    if TarArchive.isTarURL(url) {
        // tar / tar.gz archives: build the tree from parsed tar entries
        for tarEntry in try TarArchive.read(url: url) {
            // Hide AppleDouble "._foo" metadata entries (Finder does the same);
            // they stay in the archive, just out of the tree view.
            if isMacOSMetadataPath(tarEntry.path) { continue }
            let pathComponents = tarEntry.path.split(separator: "/").map(String.init)
            insertEntry(pathComponents, isDirectory: tarEntry.isDirectory, root: &root, fullPath: tarEntry.path, size: tarEntry.isDirectory ? nil : Int64(tarEntry.data.count), modificationDate: tarEntry.modificationDate)
        }
    } else {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for entry in archive {
            if isMacOSMetadataPath(entry.path) { continue }
            let pathComponents = entry.path.split(separator: "/").map(String.init)
            let size: Int64? = entry.type == .file ? Int64(entry.uncompressedSize) : nil
            let modDate: Date? = entry.fileAttributes[.modificationDate] as? Date
            insertEntry(pathComponents, isDirectory: entry.path.hasSuffix("/"), root: &root, fullPath: entry.path, size: size, modificationDate: modDate)
        }
    }

    return root.values.sorted { a, b in
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

func insertEntry(_ components: [String], isDirectory: Bool, root: inout [String: ZipNode], fullPath: String, size: Int64?, modificationDate: Date?) {
    guard let first = components.first else { return }
    if components.count == 1 {
        if root[first] == nil {
            root[first] = ZipNode(
                name: first,
                isDirectory: isDirectory,
                children: nil,
                fullPath: fullPath,
                size: size,
                modificationDate: modificationDate
            )
        }
    } else {
        var folder = root[first] ?? ZipNode(name: first, isDirectory: true, children: [], fullPath: first)
        let nextChildren = folder.children ?? []
        var childrenDict = Dictionary(uniqueKeysWithValues: nextChildren.map { ($0.name, $0) })
        insertEntry(Array(components.dropFirst()), isDirectory: isDirectory, root: &childrenDict, fullPath: fullPath, size: size, modificationDate: modificationDate)
        folder.children = childrenDict.values.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        root[first] = folder
    }
}
