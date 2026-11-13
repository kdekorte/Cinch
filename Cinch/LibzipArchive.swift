//
//  LibzipArchive.swift
//  Cinch
//
//  Swift facade over the libzip C API (via the SwiftZip package's "zip"
//  module). Handles listing, reading (with password support for AES and
//  traditional encryption), and mutating zip archives.
//

import Foundation
#if canImport(zip)
import zip

/// Encryption method of a zip entry.
enum ZipEncryption: Equatable {
    case none
    case traditional  // legacy ZipCrypto
    case aes128
    case aes192
    case aes256
    case unknown(UInt16)

    init(raw: UInt16) {
        switch raw {
        case 0: self = .none
        case 1: self = .traditional
        case 0x0101: self = .aes128
        case 0x0102: self = .aes192
        case 0x0103: self = .aes256
        default: self = .unknown(raw)
        }
    }
}

struct ZipEntryInfo {
    var path: String
    var size: Int
    var modificationDate: Date
    var encryption: ZipEncryption

    var isDirectory: Bool { path.hasSuffix("/") }
    var isEncrypted: Bool { encryption != .none }
}

enum LibzipError: Error, LocalizedError {
    case openFailed(String)
    case entryNotFound(String)
    case wrongPassword
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path): return "Could not open archive \(path)"
        case .entryNotFound(let path): return "Entry not found: \(path)"
        case .wrongPassword: return "Wrong password."
        case .failed(let message): return message
        }
    }
}

enum Libzip {

    // MARK: - Helpers

    private static func cString(_ s: String) -> [CChar] {
        Array(s.utf8).map { CChar(bitPattern: $0) } + [0]
    }

    private static func lastError(_ za: OpaquePointer) -> String {
        let err = zip_get_error(za)
        return String(cString: zip_error_strerror(err))
    }

    /// Opens an archive; returns the handle and whether it was opened for reading only.
    private static func openArchive(_ url: URL, readOnly: Bool) throws -> OpaquePointer {
        var err: Int32 = 0
        let path = cString(url.path)
        let flags: Int32 = readOnly ? ZIP_RDONLY : (ZIP_CREATE as Int32)
        let za = path.withUnsafeBufferPointer { buf in
            zip_open(buf.baseAddress!, flags, &err)
        }
        guard let za = za else {
            throw LibzipError.openFailed(url.lastPathComponent)
        }
        return za
    }

    private static func statEntry(_ za: OpaquePointer, index: UInt64) -> zip_stat_t? {
        var st = zip_stat_t()
        zip_stat_init(&st)
        guard zip_stat_index(za, index, 0, &st) == 0, st.name != nil else { return nil }
        return st
    }

    private static func locate(_ za: OpaquePointer, path: String) -> Int64 {
        let cPath = cString(path)
        return cPath.withUnsafeBufferPointer { buf in
            zip_name_locate(za, buf.baseAddress!, 0)
        }
    }

    // MARK: - Reading

    /// Lists every entry in the archive (no password needed).
    static func entries(url: URL) throws -> [ZipEntryInfo] {
        let za = try openArchive(url, readOnly: true)
        defer { zip_discard(za) }

        let count = zip_get_num_entries(za, 0)
        guard count >= 0 else { throw LibzipError.failed(lastError(za)) }

        var result: [ZipEntryInfo] = []
        result.reserveCapacity(Int(count))
        for i in 0..<UInt64(count) {
            guard let st = statEntry(za, index: i) else { continue }
            let path = String(cString: st.name!)
            result.append(ZipEntryInfo(
                path: path,
                size: Int(st.size),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(st.mtime)),
                encryption: ZipEncryption(raw: st.encryption_method)
            ))
        }
        return result
    }

    /// True if any entry in the archive is encrypted.
    static func hasEncryptedEntries(url: URL) -> Bool {
        (try? entries(url: url))?.contains { $0.isEncrypted } ?? false
    }

    /// Reads one entry's data, decrypting with the password when needed.
    static func readEntry(url: URL, path: String, password: String?) throws -> Data {
        let za = try openArchive(url, readOnly: true)
        defer { zip_discard(za) }

        let index = locate(za, path: path)
        guard index >= 0 else { throw LibzipError.entryNotFound(path) }

        let cPassword = password.map(cString)
        let zf = cPassword.map { pw in
            pw.withUnsafeBufferPointer { zip_fopen_index_encrypted(za, UInt64(index), 0, $0.baseAddress) }
        } ?? zip_fopen_index(za, UInt64(index), 0)

        guard let zf = zf else {
            let message = lastError(za)
            if message.contains("assword") { throw LibzipError.wrongPassword }
            throw LibzipError.failed(message)
        }
        defer { zip_fclose(zf) }

        guard let st = statEntry(za, index: UInt64(index)) else {
            throw LibzipError.entryNotFound(path)
        }
        let size = Int(st.size)
        var data = Data(count: size)
        var total = 0
        let ok = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            while total < size {
                let bytesRead = zip_fread(zf, raw.baseAddress!.advanced(by: total), UInt64(size - total))
                if bytesRead <= 0 { return false }
                total += Int(bytesRead)
            }
            return true
        }
        guard ok, total == size else {
            let message = String(cString: zip_file_strerror(zf))
            if message.contains("assword") { throw LibzipError.wrongPassword }
            throw LibzipError.failed(message)
        }
        return data
    }
}

extension Libzip {

    // MARK: - Mutation
    // All mutations open the archive read-write, apply changes and zip_close()
    // to commit (libzip writes a fresh, consistent archive on close).

    /// Applies changes to the archive and commits them.
    /// The transform receives the open archive handle and may throw.
    static func mutate(url: URL, _ changes: (OpaquePointer) throws -> Void) throws {
        let za = try openArchive(url, readOnly: false)
        var thrown: Error? = nil
        do {
            try changes(za)
        } catch {
            thrown = error
        }
        if let error = thrown {
            zip_discard(za) // roll back all changes
            throw error
        }
        guard zip_close(za) == 0 else {
            let message = lastError(za)
            zip_discard(za)
            throw LibzipError.failed(message)
        }
    }

    /// Adds a file from disk. When a password is given the entry is written
    /// AES-256 encrypted.
    static func addFile(url: URL, from fileURL: URL, as path: String, password: String? = nil) throws {
        try mutate(url: url) { za in
            try addFileToArchive(za, from: fileURL, as: path, password: password)
        }
    }

    /// Adds an in-memory entry. When a password is given the entry is written
    /// AES-256 encrypted.
    static func addData(url: URL, data: Data, as path: String, password: String? = nil, modified: Date? = nil) throws {
        try mutate(url: url) { za in
            try addDataToArchive(za, data: data, as: path, password: password, modified: modified)
        }
    }

    /// Adds a directory entry.
    static func addDirectory(url: URL, as path: String) throws {
        try mutate(url: url) { za in
            try addDirectoryToArchive(za, path: path)
        }
    }

    /// Deletes the entries at the given paths (collect indices first).
    static func delete(url: URL, paths: [String]) throws {
        try mutate(url: url) { za in
            for path in paths {
                let index = locate(za, path: path)
                guard index >= 0 else { continue }
                guard zip_delete(za, UInt64(index)) == 0 else {
                    throw LibzipError.failed(lastError(za))
                }
            }
        }
    }

    /// Renames entries: each pair maps an existing path to a new one.
    static func rename(url: URL, mappings: [(from: String, to: String)]) throws {
        try mutate(url: url) { za in
            for mapping in mappings {
                let index = locate(za, path: mapping.from)
                guard index >= 0 else { continue }
                let newName = cString(mapping.to)
                let ok = newName.withUnsafeBufferPointer { buf in
                    zip_file_rename(za, UInt64(index), buf.baseAddress!, 0)
                }
                guard ok == 0 else {
                    throw LibzipError.failed(lastError(za))
                }
            }
        }
    }

    /// Creates an empty archive at the given URL.
    static func createEmptyArchive(url: URL) throws {
        try mutate(url: url) { _ in }
    }

    // MARK: - Per-archive-handle helpers (used inside mutate)

    static func addFileToArchive(_ za: OpaquePointer, from fileURL: URL, as path: String, password: String? = nil) throws {
        let source = zip_source_file(za, cString(fileURL.path), 0, 0)
        guard let source = source else {
            throw LibzipError.failed(lastError(za))
        }
        try addSourceToArchive(za, source: source, as: path, password: password)
    }

    static func addDataToArchive(_ za: OpaquePointer, data: Data, as path: String, password: String? = nil, modified: Date? = nil) throws {
        // zip_source_buffer does NOT copy the buffer: it reads from the pointer
        // when the archive is closed. Hand it malloc'd memory with freep=1 so
        // libzip owns (and later frees) a stable copy — a Swift Data buffer
        // would be dangling by the time zip_close() consumes it.
        let count = data.count
        let buffer = malloc(count > 0 ? count : 1)!
        if count > 0 {
            data.withUnsafeBytes { raw in
                memcpy(buffer, raw.baseAddress!, count)
            }
        }
        guard let source = zip_source_buffer(za, buffer, UInt64(count), 1) else {
            free(buffer)
            throw LibzipError.failed(lastError(za))
        }
        try addSourceToArchive(za, source: source, as: path, password: password, modified: modified)
    }

    static func addDirectoryToArchive(_ za: OpaquePointer, path: String) throws {
        let name = cString(path)
        let index = name.withUnsafeBufferPointer { buf in
            zip_dir_add(za, buf.baseAddress!, 0)
        }
        guard index >= 0 else {
            throw LibzipError.failed(lastError(za))
        }
    }

    private static func addSourceToArchive(_ za: OpaquePointer, source: OpaquePointer, as path: String, password: String?, modified: Date? = nil) throws {
        let name = cString(path)
        let index = name.withUnsafeBufferPointer { buf in
            zip_file_add(za, buf.baseAddress!, source, ZIP_FL_OVERWRITE | ZIP_FL_ENC_UTF_8)
        }
        guard index >= 0 else {
            zip_source_free(source)
            throw LibzipError.failed(lastError(za))
        }
        if let password = password {
            let cPassword = cString(password)
            let ok = cPassword.withUnsafeBufferPointer { buf in
                zip_file_set_encryption(za, UInt64(index), UInt16(ZIP_EM_AES_256), buf.baseAddress!)
            }
            guard ok == 0 else {
                throw LibzipError.failed(lastError(za))
            }
        }
        if let modified = modified {
            _ = zip_file_set_mtime(za, UInt64(index), Int(modified.timeIntervalSince1970), 0)
        }
    }
}
#endif
