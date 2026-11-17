//
//  ToolsEdit2.swift
//  cinch-mcp
//
//  Mutating MCP tools: archive_write_file, archive_delete, archive_rename,
//  archive_new_folder and archive_set_password.
//

import Foundation
import CinchCore

extension Tool {

    static var editingTools: [Tool] {
        [createTool, addTool, writeFileTool, deleteTool, renameTool, newFolderTool, setPasswordTool]
    }

    static let writeFileTool = Tool(
        name: "archive_write_file",
        description: "Add or replace a single in-memory entry in an archive: write text or base64 content into it without staging files on disk. An entry path ending in \"/\" creates a folder.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "entry": stringProp("Path of the entry inside the archive."),
            "content": stringProp("Text content (UTF-8) to write."),
            "content_base64": stringProp("Binary content, base64-encoded. Takes precedence over content."),
            "password": stringProp("AES-256-encrypt the entry with this password (zip only)."),
        ], required: ["path", "entry"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            let entry = try requireString(args, "entry")
            let password = optionalString(args, "password")

            let data: Data
            if let b64 = optionalString(args, "content_base64") {
                guard let d = Data(base64Encoded: b64) else {
                    throw ToolError("content_base64 is not valid base64")
                }
                data = d
            } else if let text = optionalString(args, "content") {
                data = Data(text.utf8)
            } else {
                throw ToolError("missing \"content\" or \"content_base64\"")
            }

            let isDir = entry.hasSuffix("/")
            switch archiveFormat(of: url) {
            case .zip:
                if isDir {
                    try Libzip.addDirectory(url: url, as: entry)
                } else {
                    try Libzip.addData(url: url, data: data, as: entry, password: password)
                }
            case .tar:
                var entries = try TarArchive.read(url: url)
                let clean = withoutTrailingSlash(entry)
                entries.removeAll { $0.path == clean || $0.path == clean + "/" }
                entries.append(TarEntry(
                    path: isDir ? clean + "/" : clean,
                    data: isDir ? Data() : data,
                    modificationDate: Date(),
                    permissions: isDir ? 0o755 : 0o644
                ))
                try TarArchive.write(entries, to: url)
            }
            return "Wrote \(entry) (\(data.count) bytes) to \(url.lastPathComponent)."
        }
    )

    static let deleteTool = Tool(
        name: "archive_delete",
        description: "Delete entries from an archive; a folder path deletes the folder and its contents recursively.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "entries": stringArrayProp("Entry paths to delete."),
        ], required: ["path", "entries"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            let matcher = makeMatcher(try requireStringArray(args, "entries"))

            switch archiveFormat(of: url) {
            case .zip:
                let doomed = try Libzip.entries(url: url).map(\.path).filter(matcher)
                if doomed.isEmpty { throw ToolError("no matching entries") }
                try Libzip.delete(url: url, paths: doomed)
            case .tar:
                var entries = try TarArchive.read(url: url)
                let before = entries.count
                entries.removeAll { matcher($0.path) }
                if entries.count == before { throw ToolError("no matching entries") }
                try TarArchive.write(entries, to: url)
            }
            return "Deleted entries from \(url.lastPathComponent)."
        }
    )

    static let renameTool = Tool(
        name: "archive_rename",
        description: "Rename entries in an archive. Renaming a folder remaps every entry inside it.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "mappings": mappingsProp("Renames to apply, e.g. [{\"from\": \"old.txt\", \"to\": \"new.txt\"}]."),
        ], required: ["path", "mappings"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            guard let mappings = args["mappings"] as? [[String: Any]], !mappings.isEmpty else {
                throw ToolError("missing required parameter \"mappings\"")
            }
            var pairs: [(from: String, to: String)] = []
            for m in mappings {
                guard let from = m["from"] as? String, !from.isEmpty,
                      let to = m["to"] as? String, !to.isEmpty else {
                    throw ToolError("each mapping needs non-empty \"from\" and \"to\"")
                }
                if to.split(separator: "/").contains("..") {
                    throw ToolError("destination paths may not contain \"..\"")
                }
                pairs.append((withoutTrailingSlash(from), withoutTrailingSlash(to)))
            }

            switch archiveFormat(of: url) {
            case .zip:
                let renames: [(from: String, to: String)] = try Libzip.entries(url: url)
                    .map(\.path)
                    .compactMap { path -> (String, String)? in
                        let p = withoutTrailingSlash(path)
                        for pair in pairs where p == pair.from || p.hasPrefix(pair.from + "/") {
                            let suffix = p == pair.from ? "" : String(p.dropFirst(pair.from.count))
                            return (path, pair.to + suffix + (path.hasSuffix("/") ? "/" : ""))
                        }
                        return nil
                    }
                if renames.isEmpty { throw ToolError("no matching entries") }
                try Libzip.rename(url: url, mappings: renames)
            case .tar:
                var entries = try TarArchive.read(url: url)
                for i in entries.indices {
                    let p = withoutTrailingSlash(entries[i].path)
                    for pair in pairs where p == pair.from || p.hasPrefix(pair.from + "/") {
                        let suffix = p == pair.from ? "" : String(p.dropFirst(pair.from.count))
                        entries[i].path = pair.to + suffix + (entries[i].path.hasSuffix("/") ? "/" : "")
                    }
                }
                try TarArchive.write(entries, to: url)
            }
            return "Renamed entries in \(url.lastPathComponent)."
        }
    )

    static let newFolderTool = Tool(
        name: "archive_new_folder",
        description: "Create a new folder inside an archive.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "folder": stringProp("Path of the folder to create inside the archive."),
        ], required: ["path", "folder"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            let folder = withoutTrailingSlash(try requireString(args, "folder"))
            guard !folder.isEmpty, sanitizedEntryPath(folder) == folder else {
                throw ToolError("invalid folder path: \(folder)")
            }
            switch archiveFormat(of: url) {
            case .zip:
                try Libzip.addDirectory(url: url, as: folder + "/")
            case .tar:
                var entries = try TarArchive.read(url: url)
                entries.append(TarEntry(
                    path: folder + "/", data: Data(),
                    modificationDate: Date(), permissions: 0o755
                ))
                try TarArchive.write(entries, to: url)
            }
            return "Created folder \(folder) in \(url.lastPathComponent)."
        }
    )

    static let setPasswordTool = Tool(
        name: "archive_set_password",
        description: "Rewrite a zip archive with every entry AES-256 encrypted under a new password (an empty password removes encryption). Tar archives have no password concept.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the zip archive."),
            "password": stringProp("New password; empty string removes encryption."),
            "old_password": stringProp("Current password, if the archive is encrypted (needed to read its entries)."),
        ], required: ["path", "password"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            guard archiveFormat(of: url) == .zip else {
                throw ToolError("passwords apply to zip archives only")
            }
            let newPassword = (args["password"] as? String) ?? ""
            let oldPassword = optionalString(args, "old_password")

            let entries = try Libzip.entries(url: url)
            var payload: [(path: String, data: Data, modified: Date)] = []
            for e in entries where !e.isDirectory {
                payload.append((e.path, try Libzip.readEntry(url: url, path: e.path, password: oldPassword), e.modificationDate))
            }
            let dirs = entries.filter(\.isDirectory).map(\.path)

            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".cinch-mcp-" + UUID().uuidString + ".zip")
            try Libzip.mutate(url: temp) { za in
                for path in dirs {
                    try Libzip.addDirectoryToArchive(za, path: path)
                }
                for item in payload {
                    try Libzip.addDataToArchive(
                        za, data: item.data, as: item.path,
                        password: newPassword.isEmpty ? nil : newPassword, modified: item.modified)
                }
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return newPassword.isEmpty
                ? "Removed encryption from \(url.lastPathComponent)."
                : "Re-encrypted \(url.lastPathComponent) with AES-256."
        }
    )
}
