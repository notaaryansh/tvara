import Compression
import Foundation

/// Minimal parser for Chromium Simple Cache `*_0` entry files.
///
/// Empirically determined layout (Chrome 100+ / Discord 0.0.391):
///
/// ```
///   offset 0:                 SimpleFileHeader (20 bytes)
///   offset 20:                4 null bytes (partition flags)
///   offset 24:                key bytes — length given by header.key_length;
///                              starts with ASCII path prefix "1/0/" then the
///                              full URL
///   offset 24 + key_length:   body bytes — either gzipped JSON (API responses)
///                              or raw image bytes (avatars / icons), ending
///                              at the first SimpleFileEOF marker
/// ```
///
/// We don't parse the full multi-stream EOF metadata; for our use case we
/// only need URL + decoded body of the response stream.
enum ChromiumCacheParser {
    static let initialMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    static let eofMagic:     UInt64 = 0xf4fa_6f45_970d_41d8

    struct Entry {
        let url: String
        let body: Data
    }

    static func parse(fileURL: URL) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> Entry? {
        guard data.count >= 28 else { return nil }
        guard data.readUInt64LE(at: 0) == initialMagic else { return nil }

        let keyLength = Int(data.readUInt32LE(at: 12))
        let keyStart  = 24                      // header (20) + partition flags (4)
        let keyEnd    = keyStart + keyLength
        guard keyEnd <= data.count, keyLength > 0 else { return nil }

        // The key region begins with a partition-path prefix like "1/0/".
        // Strip that to get the raw URL. We locate the URL by searching for
        // the scheme inside the key bytes; if absent, this entry is not an
        // http(s) cache entry and we skip it.
        guard let schemeRel = data.findSchemeInRange(keyStart..<keyEnd) else { return nil }
        let url = String(data: data.subdata(in: schemeRel..<keyEnd), encoding: .utf8) ?? ""

        // Body: bytes after the key, terminated at the first SimpleFileEOF
        // marker (which delimits stream 1 from the metadata streams).
        let bodyStart = keyEnd
        guard bodyStart < data.count else { return nil }
        let bodyEnd = data.findEOFMagic(from: bodyStart) ?? data.count
        guard bodyEnd > bodyStart else { return nil }

        let raw = data.subdata(in: bodyStart..<bodyEnd)

        // Two body encodings in practice: gzipped JSON API responses, and
        // raw image bytes (RIFF for WebP, 89 50 4E 47 for PNG, etc).
        let body: Data
        if raw.count >= 3, raw[0] == 0x1f, raw[1] == 0x8b, raw[2] == 0x08 {
            guard let decompressed = raw.gunzipped() else { return nil }
            body = decompressed
        } else {
            body = raw
        }

        return Entry(url: url, body: body)
    }
}

// MARK: - Data helpers

extension Data {
    fileprivate func readUInt64LE(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        _ = withUnsafeBytes { raw in
            memcpy(&v, raw.baseAddress!.advanced(by: offset), 8)
        }
        return v
    }

    fileprivate func readUInt32LE(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        _ = withUnsafeBytes { raw in
            memcpy(&v, raw.baseAddress!.advanced(by: offset), 4)
        }
        return v
    }

    /// Returns the byte offset of the first "https://" or "http://" within
    /// `range`, or nil if neither scheme is present in that window.
    fileprivate func findSchemeInRange(_ range: Range<Int>) -> Int? {
        let httpsBytes: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3a, 0x2f, 0x2f]
        let httpBytes:  [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f]
        guard range.upperBound <= count else { return nil }
        return withUnsafeBytes { raw -> Int? in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            var i = range.lowerBound
            while i + httpBytes.count <= range.upperBound {
                if i + httpsBytes.count <= range.upperBound
                    && memcmp(ptr.advanced(by: i), httpsBytes, httpsBytes.count) == 0 {
                    return i
                }
                if memcmp(ptr.advanced(by: i), httpBytes, httpBytes.count) == 0 {
                    return i
                }
                i += 1
            }
            return nil
        }
    }

    fileprivate func findEOFMagic(from start: Int) -> Int? {
        let target: UInt64 = ChromiumCacheParser.eofMagic
        guard start + 8 <= count else { return nil }
        return withUnsafeBytes { raw -> Int? in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            var i = start
            while i + 8 <= count {
                var v: UInt64 = 0
                memcpy(&v, ptr.advanced(by: i), 8)
                if v == target { return i }
                i += 1
            }
            return nil
        }
    }

    fileprivate func gunzipped() -> Data? {
        guard count > 18 else { return nil }
        guard self[0] == 0x1f, self[1] == 0x8b, self[2] == 0x08 else { return nil }

        let flags = self[3]
        var offset = 10

        if flags & 0x04 != 0 {                  // FEXTRA
            guard offset + 2 <= count else { return nil }
            let xlen = Int(self[offset]) | (Int(self[offset+1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {                  // FNAME
            while offset < count && self[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {                  // FCOMMENT
            while offset < count && self[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {                  // FHCRC
            offset += 2
        }

        guard offset < count - 8 else { return nil }
        let deflateData = subdata(in: offset..<(count - 8))

        var output = Data()
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 1),
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        defer { compression_stream_destroy(&stream) }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }

        let bufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        var ok = true
        deflateData.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = deflateData.count
            stream.dst_ptr = dstBuffer
            stream.dst_size = bufferSize

            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_OK {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = bufferSize
                    continue
                }
                ok = false
                return
            }
        }
        return ok ? output : nil
    }
}
