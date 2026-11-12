//
//  TarArchive.swift
//  Cinch
//
//  Read and write tar archives, optionally gzip-compressed (.tar.gz / .tgz).
//  Uses Apple's Compression framework for the DEFLATE payload and implements
//  the gzip container (RFC 1952) and ustar tar format manually.
//

import Foundation
import Compression

/// One entry in a tar archive. Directory paths always end with "/".
struct TarEntry: Equatable {
    var path: String
    var data: Data
    var modificationDate: Date
    var permissions: Int

    var isDirectory: Bool { path.hasSuffix("/") }
}

enum TarArchiveError: Error, LocalizedError {
    case notGzip
    case corruptGzip
    case corruptTar
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .notGzip: return "The file is not a gzip archive."
        case .corruptGzip: return "The gzip stream is corrupt."
        case .corruptTar: return "The tar archive is corrupt."
        case .compressionFailed: return "Compressing the archive failed."
        }
    }
}

enum TarArchive {

    // MARK: - Format detection

    /// Files Cinch treats as tar archives: .tar, .tar.gz, .tgz
    static func isTarURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar")
            || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.gz")
    }

    static func isCompressedName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".gz") || name.hasSuffix(".tgz")
    }

    // MARK: - Reading

    static func read(url: URL) throws -> [TarEntry] {
        let fileData = try Data(contentsOf: url)
        let tarData = try Gzip.isGzipData(fileData) ? Gzip.decompress(fileData) : fileData
        return try parse(tarData)
    }

    static func parse(_ tar: Data) throws -> [TarEntry] {
        var entries: [TarEntry] = []
        let blockSize = 512
        var offset = 0

        while offset + blockSize <= tar.count {
            let header = tar.subdata(in: offset..<(offset + blockSize))

            // Two zero blocks (or truncation) mark the end of the archive
            if header.first(where: { $0 != 0 }) == nil { break }

            let name = tarString(header, at: 0, length: 100)
            let prefix = tarString(header, at: 345, length: 155)
            let size = tarOctal(header, at: 124, length: 12)
            let mtime = tarOctal(header, at: 136, length: 12)
            let mode = tarOctal(header, at: 100, length: 8)
            let typeFlag = header[156]

            // GNU long name / pax extended headers are metadata; skip their data
            let isMetadata = typeFlag == UInt8(ascii: "L")
                || typeFlag == UInt8(ascii: "x")
                || typeFlag == UInt8(ascii: "g")

            var path = prefix.isEmpty ? name : prefix + "/" + name
            let isDirectory = typeFlag == UInt8(ascii: "5") || path.hasSuffix("/")
            if isDirectory && !path.hasSuffix("/") { path += "/" }

            let dataStart = offset + blockSize
            let paddedSize = (Int(size) + blockSize - 1) / blockSize * blockSize
            let dataEnd = dataStart + Int(size)
            guard dataEnd <= tar.count else { throw TarArchiveError.corruptTar }

            if !isMetadata && !name.isEmpty {
                let data = isDirectory ? Data() : tar.subdata(in: dataStart..<dataEnd)
                entries.append(TarEntry(
                    path: path,
                    data: data,
                    modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime)),
                    permissions: mode != 0 ? Int(mode) : 0o644
                ))
            }

            offset = dataStart + paddedSize
        }

        return entries
    }
}
extension TarArchive {

    // MARK: - Writing

    static func write(_ entries: [TarEntry], to url: URL) throws {
        let tarData = tarData(from: entries)
        let outData = isCompressedName(url) ? try Gzip.compress(tarData) : tarData
        try outData.write(to: url, options: .atomic)
    }

    static func tarData(from entries: [TarEntry]) -> Data {
        var out = Data()
        let blockSize = 512

        for entry in entries {
            var header = Data(repeating: 0, count: blockSize)
            writeName(entry.path, into: &header)

            putOctal(&header, value: UInt64(entry.isDirectory ? 0o755 : entry.permissions), at: 100, length: 8)   // mode
            putOctal(&header, value: 0, at: 108, length: 8)    // uid
            putOctal(&header, value: 0, at: 116, length: 8)    // gid
            putOctal(&header, value: UInt64(entry.data.count), at: 124, length: 12) // size
            putOctal(&header, value: UInt64(max(0, Int(entry.modificationDate.timeIntervalSince1970))), at: 136, length: 12) // mtime
            header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
            // magic + version: "ustar\0" + "00"
            header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
            header[263] = UInt8(ascii: "0")
            header[264] = UInt8(ascii: "0")

            // Checksum: sum of all header bytes with the checksum field as spaces
            for i in 148..<156 { header[i] = UInt8(ascii: " ") }
            var sum: UInt64 = 0
            for byte in header { sum += UInt64(byte) }
            let chk = Array(String(sum, radix: 8).utf8)
            header.replaceSubrange(148..<(148 + chk.count), with: chk)
            header[148 + chk.count] = 0
            header[148 + chk.count + 1] = UInt8(ascii: " ")

            out.append(header)
            if !entry.isDirectory {
                out.append(entry.data)
                let pad = (blockSize - entry.data.count % blockSize) % blockSize
                out.append(Data(repeating: 0, count: pad))
            }
        }

        // End-of-archive: two zero blocks, padded to the 10240-byte record size
        out.append(Data(repeating: 0, count: blockSize * 2))
        let recordSize = 10240
        if out.count % recordSize != 0 {
            out.append(Data(repeating: 0, count: recordSize - out.count % recordSize))
        }
        return out
    }

    /// Writes the entry path into the ustar name (+prefix) fields.
    /// Paths longer than the format allows are skipped (represented by returning false).
    @discardableResult
    private static func writeName(_ path: String, into header: inout Data) -> Bool {
        let nameBytes = Array(path.utf8)
        if nameBytes.count <= 100 {
            header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
            return true
        }
        // Try to split across the ustar prefix (155) + name (100) fields
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for split in stride(from: components.count - 1, through: 1, by: -1) {
            let prefixPart = components[0..<split].joined(separator: "/")
            let namePart = components[split...].joined(separator: "/")
            let nb = Array(namePart.utf8)
            let pb = Array(prefixPart.utf8)
            if nb.count <= 100 && pb.count <= 155 {
                header.replaceSubrange(0..<nb.count, with: nb)
                header.replaceSubrange(345..<(345 + pb.count), with: pb)
                return true
            }
        }
        return false
    }

    // MARK: - Header field helpers

    private static func tarString(_ header: Data, at offset: Int, length: Int) -> String {
        let slice = header.subdata(in: offset..<(offset + length))
        let bytes = Array(slice.prefix { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func tarOctal(_ header: Data, at offset: Int, length: Int) -> UInt64 {
        let s = tarString(header, at: offset, length: length)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        return UInt64(s, radix: 8) ?? 0
    }

    private static func putOctal(_ data: inout Data, value: UInt64, at offset: Int, length: Int) {
        // Octal, zero-padded, NUL-terminated (ustar style)
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        var field = Data(repeating: 0, count: length)
        let bytes = Array(padded.utf8)
        for (i, b) in bytes.enumerated() where i < length {
            field[i] = b
        }
        data.replaceSubrange(offset..<(offset + length), with: field)
    }
}
