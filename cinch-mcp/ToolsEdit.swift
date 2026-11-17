//
//  ToolsEdit.swift
//  cinch-mcp
//
//  Shared helpers for the mutating MCP tools, plus archive_create and
//  archive_add. The remaining mutating tools are in ToolsEdit2.swift.
//

import Foundation
import CinchCore

// MARK: - Adding disk files

/// Visits root and (recursively) its children, calling visit with the file
/// URL and its path relative to root's parent ("name", "name/child", ...).
func walkDiskTree(_ root: URL, prefix: String, visit: (URL, String) throws -> Void) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
        throw ToolError("file not found: \(root.path)")
    }
    let rel = prefix.isEmpty ? root.lastPathComponent : prefix + "/" + root.lastPathComponent
    try visit(root, rel)
    guard isDir.boolValue else { return }
    let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for child in children {
        try walkDiskTree(child, prefix: rel, visit: visit)
    }
}

/// Adds a disk file/folder (recursively) to an open zip archive.
func addDiskTree(to za: OpaquePointer, root: URL, prefix: String, password: String?) throws {
    try walkDiskTree(root, prefix: prefix) { fileURL, rel in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            try Libzip.addDirectoryToArchive(za, path: rel + "/")
        } else {
            try Libzip.addFileToArchive(za, from: fileURL, as: rel, password: password)
        }
    }
}

/// Builds a tar entry for a disk file, keeping its mtime and permissions.
func tarEntry(from fileURL: URL, path: String, isDirectory: Bool) throws -> TarEntry {
    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return TarEntry(
        path: isDirectory ? path + "/" : path,
        data: isDirectory ? Data() : (try Data(contentsOf: fileURL)),
        modificationDate: (attrs[.modificationDate] as? Date) ?? Date(),
        permissions: (attrs[.posixPermissions] as? Int) ?? (isDirectory ? 0o755 : 0o644)
    )
}

// MARK: - archive_create

extension Tool {

    static let createTool = Tool(
        name: "archive_create",
        description: "Create a new archive on disk from files or folders on disk (folders are added recursively). The format is inferred from the extension, or forced with the format parameter.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive to create. Extension (.zip, .tar, .tar.gz, .tgz) decides the format."),
            "files": stringArrayProp("Absolute paths of files/folders on disk to add. Omit for an empty archive."),
            "format": stringProp("Force the format: \"zip\", \"tar\" or \"tar.gz\". Default: inferred from the file extension."),
            "password": stringProp("AES-256-encrypt zip entries with this password (zip only)."),
        ], required: ["path"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            if FileManager.default.fileExists(atPath: url.path) {
                throw ToolError("file already exists: \(url.path)")
            }
            let files = (args["files"] as? [String]) ?? []
            let password = optionalString(args, "password")

            let isTar: Bool
            switch optionalString(args, "format") {
            case "zip": isTar = false
            case "tar", "tar.gz": isTar = true
            case nil: isTar = TarArchive.isTarURL(url)
            case .some(let f): throw ToolError("unknown format \"\(f)\" (use zip, tar or tar.gz)")
            }
            if isTar && password != nil {
                throw ToolError("passwords apply to zip archives only")
            }

            if isTar {
                var entries: [TarEntry] = []
                for file in files {
                    try walkDiskTree(fileURL(fromPath: file), prefix: "") { fileURL, rel in
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                        entries.append(try tarEntry(from: fileURL, path: rel, isDirectory: isDir.boolValue))
                    }
                }
                try TarArchive.write(entries, to: url)
            } else {
                try Libzip.mutate(url: url) { za in
                    for file in files {
                        try addDiskTree(to: za, root: fileURL(fromPath: file), prefix: "", password: password)
                    }
                }
            }
            return "Created \(url.lastPathComponent) with \(files.count) top-level item(s)."
        }
    )

    static let addTool = Tool(
        name: "archive_add",
        description: "Add files or folders from disk to an existing archive (folders are added recursively).",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "files": stringArrayProp("Absolute paths of files/folders on disk to add."),
            "folder": stringProp("Folder inside the archive to add into (default: root)."),
            "password": stringProp("AES-256-encrypt added zip entries with this password (zip only)."),
        ], required: ["path", "files"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("archive not found: \(url.path)")
            }
            let files = try requireStringArray(args, "files")
            let folder = withoutTrailingSlash(optionalString(args, "folder") ?? "")
            let password = optionalString(args, "password")

            switch archiveFormat(of: url) {
            case .zip:
                try Libzip.mutate(url: url) { za in
                    for file in files {
                        try addDiskTree(to: za, root: fileURL(fromPath: file), prefix: folder, password: password)
                    }
                }
            case .tar:
                var entries = try TarArchive.read(url: url)
                for file in files {
                    try walkDiskTree(fileURL(fromPath: file), prefix: folder) { fileURL, rel in
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                        entries.append(try tarEntry(from: fileURL, path: rel, isDirectory: isDir.boolValue))
                    }
                }
                try TarArchive.write(entries, to: url)
            }
            return "Added \(files.count) top-level item(s) to \(url.lastPathComponent)."
        }
    )
}
