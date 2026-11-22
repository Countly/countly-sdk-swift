//
//  Gzip.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

extension Data {

    /// The bytes as a gzip stream (RFC 1952), for sending a request body
    /// compressed, or nil when compressing fails.
    ///
    /// Apple's zlib algorithm writes raw DEFLATE (RFC 1951) without a wrapper, so
    /// the gzip header and the CRC-32 and size trailer are added here.
    func gzipCompressed() -> Data? {
        guard let deflated = try? (self as NSData).compressed(using: .zlib) as Data else { return nil }

        var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        gzip.reserveCapacity(10 + deflated.count + 8)
        gzip.append(deflated)
        for value in [crc32, UInt32(truncatingIfNeeded: count)] {
            gzip.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
        }
        return gzip
    }

    /// CRC-32 (IEEE 802.3, the one gzip uses) of the bytes.
    var crc32: UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in self {
            crc = Self.crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }
}
