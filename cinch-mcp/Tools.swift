//
//  Tools.swift
//  cinch-mcp
//
//  MCP tool type, argument/schema helpers and shared archive helpers.
//  Tool definitions live in ReadonlyTools.swift and ToolsEdit.swift.
//

import Foundation
import CinchCore

// MARK: - Types

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let handler: ([String: Any]) throws -> String
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ArchiveFormat {
    case zip
    case tar
}

// MARK: - Schema helpers

func objectSchema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required]
}

func stringProp(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

func intProp(_ description: String) -> [String: Any] {
    ["type": "integer", "description": description]
}

func stringArrayProp(_ description: String) -> [String: Any] {
    ["type": "array", "items": ["type": "string"], "description": description]
}

func mappingsProp(_ description: String) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": [
            "type": "object",
            "properties": [
                "from": stringProp("Existing entry path."),
                "to": stringProp("New entry path."),
            ],
            "required": ["from", "to"],
        ],
    ]
}

// MARK: - Argument helpers

func requireString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty else {
        throw ToolError("missing required string parameter \"\(key)\"")
    }
    return value
}

func optionalString(_ args: [String: Any], _ key: String) -> String? {
    guard let value = args[key] as? String, !value.isEmpty else { return nil }
    return value
}

func requireStringArray(_ args: [String: Any], _ key: String) throws -> [String] {
    guard let values = args[key] as? [String], !values.isEmpty else {
        throw ToolError("missing required array-of-strings parameter \"\(key)\"")
    }
    return values
}

func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
    if let n = args[key] as? Int { return n }
    if let s = args[key] as? String, let n = Int(s) { return n }
    return nil
}

func fileURL(fromPath path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

// MARK: - Shared archive helpers

func archiveFormat(of url: URL) -> ArchiveFormat {
    TarArchive.isTarURL(url) ? .tar : .zip
}

/// macOS metadata the app hides from the tree: AppleDouble "._name"
/// companions and Finder "__MACOSX" folders.
func isHiddenEntry(_ path: String) -> Bool {
    if path.hasPrefix("__MACOSX") || path.contains("/__MACOSX/") { return true }
    return (path as NSString).lastPathComponent.hasPrefix("._")
}

func jsonText(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "{\"error\": \"could not encode result\"}"
    }
    return text
}

func encryptionName(_ encryption: ZipEncryption) -> String {
    switch encryption {
    case .none: return "none"
    case .traditional: return "ZipCrypto"
    case .aes128: return "AES-128"
    case .aes192: return "AES-192"
    case .aes256: return "AES-256"
    case .unknown(let raw): return "unknown(\(raw))"
    }
}

/// Strips trailing slashes so "dir/" and "dir" compare equal.
func withoutTrailingSlash(_ path: String) -> String {
    var p = path
    while p.hasSuffix("/") { p.removeLast() }
    return p
}

/// Rejects path traversal (".."); returns a clean relative path.
func sanitizedEntryPath(_ entry: String) -> String? {
    let components = entry.split(separator: "/").map(String.init)
    if components.contains("..") { return nil }
    return components.joined(separator: "/")
}

/// Matches selected entries: exact paths, or anything inside a selected
/// folder (folder path given with or without trailing slash).
func makeMatcher(_ wanted: [String]?) -> (String) -> Bool {
    guard let wanted, !wanted.isEmpty else { return { _ in true } }
    let set = Set(wanted.map(withoutTrailingSlash))
    return { entry in
        let e = withoutTrailingSlash(entry)
        return set.contains(e) || set.contains { e.hasPrefix($0 + "/") }
    }
}

func listEntries(url: URL) throws -> [[String: Any]] {
    let iso = ISO8601DateFormatter()
    var out: [[String: Any]] = []
    switch archiveFormat(of: url) {
    case .tar:
        for e in try TarArchive.read(url: url) where !isHiddenEntry(e.path) {
            out.append([
                "path": e.path,
                "kind": e.isDirectory ? "directory" : "file",
                "size": e.data.count,
                "modified": iso.string(from: e.modificationDate),
            ])
        }
    case .zip:
        for e in try Libzip.entries(url: url) where !isHiddenEntry(e.path) {
            var item: [String: Any] = [
                "path": e.path,
                "kind": e.isDirectory ? "directory" : "file",
                "size": e.size,
                "modified": iso.string(from: e.modificationDate),
            ]
            if e.isEncrypted { item["encrypted"] = encryptionName(e.encryption) }
            out.append(item)
        }
    }
    return out
}
