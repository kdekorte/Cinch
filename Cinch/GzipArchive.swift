//
//  GzipArchive.swift
//  Cinch
//
//  Gzip container (RFC 1952) implemented over Apple's raw DEFLATE.
//

import Foundation
import Compression

enum Gzip {

    static func isGzipData(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.index(after: data.startIndex)] == 0x8B
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18 else { throw TarArchiveError.notGzip }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw TarArchiveError.notGzip }

        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw TarArchiveError.corruptGzip }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else { throw TarArchiveError.corruptGzip }

        let deflated = Array(bytes[offset..<(bytes.count - 8)])
        let inflated = try rawInflate(deflated)

        // Trailer: CRC32 (4 bytes LE) + ISIZE (4 bytes LE)
        let trailerStart = bytes.count - 8
        let expectedCRC = UInt32(bytes[trailerStart])
            | (UInt32(bytes[trailerStart + 1]) << 8)
            | (UInt32(bytes[trailerStart + 2]) << 16)
            | (UInt32(bytes[trailerStart + 3]) << 24)
        guard crc32(inflated) == expectedCRC else { throw TarArchiveError.corruptGzip }

        return Data(inflated)
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try rawDeflate([UInt8](data))

        var out = Data()
        // Header: magic, deflate, no flags, no mtime, no xfl, unknown OS
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        out.append(contentsOf: deflated)
        // Trailer: CRC32 + ISIZE (both little-endian)
        let crc = crc32([UInt8](data))
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        out.append(UInt8((crc >> 16) & 0xFF))
        out.append(UInt8((crc >> 24) & 0xFF))
        let size = UInt32(truncatingIfNeeded: data.count)
        out.append(UInt8(size & 0xFF))
        out.append(UInt8((size >> 8) & 0xFF))
        out.append(UInt8((size >> 16) & 0xFF))
        out.append(UInt8((size >> 24) & 0xFF))
        return out
    }

    // MARK: Raw DEFLATE via the Compression framework

    private static func rawInflate(_ input: [UInt8]) throws -> [UInt8] {
        // Start with a generous output size and grow until everything fits
        var capacity = max(input.count * 4, 64 * 1024)
        while true {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = input.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst, capacity, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
            if written < capacity {
                return Array(UnsafeBufferPointer(start: dst, count: written))
            }
            capacity *= 2
            if capacity > 4 << 30 { throw TarArchiveError.corruptGzip }
        }
    }

    private static func rawDeflate(_ input: [UInt8]) throws -> [UInt8] {
        // DEFLATE's worst case is slightly larger than the input
        let capacity = input.count + input.count / 16 + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let written = input.withUnsafeBufferPointer { src in
            compression_encode_buffer(dst, capacity, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw TarArchiveError.compressionFailed }
        return Array(UnsafeBufferPointer(start: dst, count: written))
    }

    // MARK: CRC32 (IEEE 802.3, as used by gzip)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
