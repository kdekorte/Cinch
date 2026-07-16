import SwiftUI
import Foundation
import ZIPFoundation
import UniformTypeIdentifiers
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
    @Environment(AppModel.self) private var appModel

    @State private var sortOrder: [KeyPathComparator<ZipNode>] = [
        .init(\.name, order: .forward)
    ]

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Toolbar row across the top
                HStack(spacing: 8) {
                    Button {
                        if zipFileURL != nil { presentAddFilesPanel() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(zipFileURL == nil)

                    Button {
                        Task { await repackCurrentZipWithProgress() }
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(zipFileURL == nil)

                    Button {
                        removeSelectedEntry()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(selectedNode == nil || zipFileURL == nil)

                    Spacer()

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
                }
                .padding(8)
                .background(.bar)

                Divider()

                // Title / path row
                HStack {
                    Text(zipFileURL?.lastPathComponent ?? "No Zip Opened")
                        .font(.headline)
                    Spacer()
                    Button("Open Zip…") { presentOpenPanel() }
                        .keyboardShortcut("o", modifiers: [.command])
                }
                .padding([.horizontal, .top], 8)
                .padding(.bottom, 4)

                // Main content: list like Finder
                if zipNodes.isEmpty {
                    VStack(spacing: 8) {
                        Text("No Zip Opened")
                            .foregroundStyle(.secondary)
                        Text("Use Open Zip… to choose a .zip file.")
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(currentListingNodes(), sortOrder: $sortOrder) {
                        TableColumn("Name", value: \.name) { node in
                            HStack {
                                Image(systemName: node.isDirectory ? "folder" : "doc")
                                Text(node.name)
                            }
                        }
                        TableColumn("Size") { node in
                            if let size = node.size, !node.isDirectory {
                                Text(bytesString(size))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("--").foregroundStyle(.tertiary)
                            }
                        }
                        TableColumn("Date Modified") { node in
                            if let date = node.modificationDate {
                                Text(date.formatted(date: .numeric, time: .shortened))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("--").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .contextMenu {
                        if let node = selectedNode, !node.isDirectory {
                            Button("Remove") { removeSelectedEntry() }
                        }
                    }
                }

                // Optional preview below list
                if let node = selectedNode, zipFileURL != nil, node.isDirectory == false {
                    Divider()
                    self.previewForZipEntry(url: zipFileURL!, node: node)
                        .frame(maxWidth: .infinity, maxHeight: 280, alignment: .topLeading)
                        .background(.thinMaterial)
                }
            }
            .onChange(of: appModel.intent) { _, newValue in
                guard let intent = newValue else { return }
                switch intent {
                case .newDocument:
                    zipFileURL = nil
                    zipNodes = []
                    selectedNode = nil
                    zipReadError = nil
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
                Color.black.opacity(0.2).ignoresSafeArea()
                VStack(spacing: 12) {
                    let label = Text("Saving…")
                    let current = Text(saveProgressText)
                    ProgressView(value: saveProgress, label: { label }, currentValueLabel: { current })
                        .frame(width: 260)
                    Button("Cancel") { /* no-op for now */ }
                        .disabled(true)
                        .opacity(0.5)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                .shadow(radius: 8)
            }
        }
    }

    // Helper: extract limited-size data for preview from an entry in the zip
    private func previewData(from url: URL, fullPath: String, maxBytes: Int = 5 * 1024 * 1024) -> Data? {
        guard let archive = Archive(url: url, accessMode: .read) else {
            return nil
        }
        guard let entry = archive.first(where: { $0.path == fullPath }) else { return nil }
        var data = Data()
        do {
            try archive.extract(entry) { chunk in
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
        panel.allowedContentTypes = [UTType.zip]
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
                    addFileToZip(zipURL: zipFileURL!, fileURL: url)
                }
            }
        }
        #endif
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
        guard let archive = Archive(url: zipURL, accessMode: .update) else { return }
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
        panel.allowedContentTypes = [UTType.zip]
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
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        do {
            // Read from source and write all entries into a new archive at tempURL
            guard let readArchive = Archive(url: sourceURL, accessMode: .read) else {
                zipReadError = "Could not open archive for reading."
                return
            }
            // Ensure temp file does not exist
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard let writeArchive = Archive(url: tempURL, accessMode: .create) else {
                zipReadError = "Could not create temp archive."
                return
            }
            for entry in readArchive {
                // Copy entries by streaming
                try readArchive.extract(entry) { data in
                    try writeArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: UInt32(data.count), compressionMethod: .deflate, provider: { position, size in
                        // For simplicity, provide full data slice per request
                        let start = Int(position)
                        let end = min(start + Int(size), data.count)
                        return data.subdata(in: start..<end)
                    })
                }
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
        await endSaving()
    }

    // Repack the current zip to a temp file and atomically replace the original
    private func repackCurrentZip() {
        guard let sourceURL = zipFileURL else { return }
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
        do {
            // Read from source and write all entries into a new archive at tempURL
            guard let readArchive = Archive(url: sourceURL, accessMode: .read) else {
                zipReadError = "Could not open archive for reading."
                return
            }
            // Ensure temp file does not exist
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard let writeArchive = Archive(url: tempURL, accessMode: .create) else {
                zipReadError = "Could not create temp archive."
                return
            }
            for entry in readArchive {
                // Copy entries by streaming
                try readArchive.extract(entry) { data in
                    try writeArchive.addEntry(with: entry.path, type: entry.type, uncompressedSize: UInt32(data.count), compressionMethod: .deflate, provider: { position, size in
                        // For simplicity, provide full data slice per request
                        let start = Int(position)
                        let end = min(start + Int(size), data.count)
                        return data.subdata(in: start..<end)
                    })
                }
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

    private func handleDroppedProvidersAsync(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadURL(from: provider) {
                    await loadZip(at: url)
                    return
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.zip.identifier) {
                if let url = await loadURL(from: provider) {
                    await loadZip(at: url)
                    return
                }
            }
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

    private func addFileToZip(zipURL: URL, fileURL: URL) {
        guard let archive = Archive(url: zipURL, accessMode: .update) else { return }
        let fileName = fileURL.lastPathComponent
        do {
            try archive.addEntry(with: fileName, relativeTo: fileURL.deletingLastPathComponent())
            // refresh tree
            zipNodes = try readZipNodes(url: zipURL)
        } catch {
            zipReadError = "Failed to add file: \(error.localizedDescription)"
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

// Helper function for file/folder tree
func readZipNodes(url: URL) throws -> [ZipNode] {
    guard let archive = Archive(url: url, accessMode: .read) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var root: [String: ZipNode] = [:]
    for entry in archive {
        let pathComponents = entry.path.split(separator: "/").map(String.init)
        let size: Int64? = entry.type == .file ? Int64(entry.uncompressedSize) : nil
        let modDate: Date? = entry.fileAttributes[.modificationDate] as? Date
        insertEntry(pathComponents, entry: entry, root: &root, fullPath: entry.path, size: size, modificationDate: modDate)
    }
    return root.values.sorted(by: { $0.name < $1.name })
}

func insertEntry(_ components: [String], entry: ZIPFoundation.Entry, root: inout [String: ZipNode], fullPath: String, size: Int64?, modificationDate: Date?) {
    guard let first = components.first else { return }
    if components.count == 1 {
        if root[first] == nil {
            root[first] = ZipNode(
                name: first,
                isDirectory: entry.path.hasSuffix("/"),
                children: nil,
                fullPath: fullPath,
                size: size,
                modificationDate: modificationDate
            )
        }
    } else {
        var folder = root[first] ?? ZipNode(name: first, isDirectory: true, children: [], fullPath: first)
        var nextChildren = folder.children ?? []
        var childrenDict = Dictionary(uniqueKeysWithValues: nextChildren.map { ($0.name, $0) })
        insertEntry(Array(components.dropFirst()), entry: entry, root: &childrenDict, fullPath: fullPath, size: size, modificationDate: modificationDate)
        folder.children = childrenDict.values.sorted(by: { $0.name < $1.name })
        root[first] = folder
    }
}

