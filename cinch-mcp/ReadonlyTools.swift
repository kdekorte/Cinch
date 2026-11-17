//
//  ReadonlyTools.swift
//  cinch-mcp
//
//  The read-only MCP tools: archive_list, archive_read, archive_extract.
//

import Foundation
import CinchCore

extension Tool {

    static var allTools: [Tool] {
        [listTool, readTool, extractTool] + Tool.editingTools
    }

    static let listTool = Tool(
        name: "archive_list",
        description: "List the entries of a zip or tar/tar.gz archive: path, kind (file/directory), size in bytes and modification date. Zip entries also report their encryption method.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive (.zip, .tar, .tar.gz, .tgz)."),
        ], required: ["path"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("archive not found: \(url.path)")
            }
            return jsonText(try listEntries(url: url))
        }
    )

    static let readTool = Tool(
        name: "archive_read",
        description: "Read one entry from an archive. Text entries come back as text (UTF-8); binary entries come back base64-encoded. Encrypted zip entries need a password.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "entry": stringProp("Path of the entry inside the archive."),
            "password": stringProp("Password for encrypted zip entries (optional)."),
            "max_bytes": intProp("Maximum bytes to return (default 65536)."),
        ], required: ["path", "entry"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            let entry = try requireString(args, "entry")
            let password = optionalString(args, "password")
            let maxBytes = optionalInt(args, "max_bytes") ?? 65536

            let data: Data
            switch archiveFormat(of: url) {
            case .tar:
                guard let e = try TarArchive.read(url: url).first(where: { $0.path == entry }) else {
                    throw ToolError("entry not found: \(entry)")
                }
                data = e.data
            case .zip:
                data = try Libzip.readEntry(url: url, path: entry, password: password)
            }

            guard !data.isEmpty else { return "(empty file)" }
            let truncated = data.count > maxBytes
            let slice = data.prefix(maxBytes)
            if let text = String(data: slice, encoding: .utf8) {
                return truncated
                    ? text + "\n… (truncated at \(maxBytes) of \(data.count) bytes)"
                    : text
            }
            let note = truncated ? " (first \(maxBytes) of \(data.count) bytes)" : ""
            return "Binary entry\(note), base64:\n" + slice.base64EncodedString()
        }
    )

    static let extractTool = Tool(
        name: "archive_extract",
        description: "Extract entries from an archive to a directory on disk. Entries with unsafe paths (\"..\") are skipped.",
        schema: objectSchema([
            "path": stringProp("Absolute path of the archive."),
            "entries": stringArrayProp("Entry paths to extract; a folder path extracts its contents recursively. Omit to extract everything."),
            "dest_dir": stringProp("Absolute path of the destination directory (created if missing)."),
            "password": stringProp("Password for encrypted zip entries (optional)."),
        ], required: ["path", "dest_dir"]),
        handler: { args in
            let url = fileURL(fromPath: try requireString(args, "path"))
            let dest = fileURL(fromPath: try requireString(args, "dest_dir"))
            let matcher = makeMatcher(args["entries"] as? [String])
            let password = optionalString(args, "password")

            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

            var written = 0
            var skipped = 0
            func write(_ data: Data, _ entry: String) throws -> Bool {
                guard let clean = sanitizedEntryPath(entry), !clean.isEmpty else {
                    return false
                }
                let target = dest.appendingPathComponent(clean)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                return true
            }

            switch archiveFormat(of: url) {
            case .tar:
                for e in try TarArchive.read(url: url) where matcher(e.path) && !e.isDirectory {
                    if try write(e.data, e.path) { written += 1 } else { skipped += 1 }
                }
            case .zip:
                for e in try Libzip.entries(url: url) where matcher(e.path) && !e.isDirectory {
                    let data = try Libzip.readEntry(url: url, path: e.path, password: password)
                    if try write(data, e.path) { written += 1 } else { skipped += 1 }
                }
            }

            var result = "Extracted \(written) file(s) to \(dest.path)."
            if skipped > 0 { result += " \(skipped) unsafe entry path(s) skipped." }
            return result
        }
    )
}
