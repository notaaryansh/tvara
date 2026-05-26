import Foundation

/// Minimal parser for Apple Mail `.emlx` files.
///
/// Format (Apple-documented):
///   line 1   ASCII decimal byte length of the RFC822 portion that follows
///   bytes    RFC822 message: headers + blank line + body
///   trailer  Apple-specific `<?xml … </plist>` metadata (we discard)
///
/// We extract Message-ID, From, Subject, Date, and a trimmed/cleaned body
/// suitable for full-text search. We deliberately do NOT do full MIME
/// reassembly (multipart boundary parsing, base64 attachment decoding) —
/// for FTS it's enough to grab the first ~10KB of text after the headers
/// and strip HTML tags + obvious binary noise.
struct EmlxParser {
    struct Parsed {
        let messageId: String
        let subject: String
        let from: String
        let date: Date?
        let body: String
    }

    static func parse(fileURL: URL) -> Parsed? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> Parsed? {
        // First line: byte length (ASCII decimal)
        guard let firstNewline = data.firstIndex(of: 0x0a) else { return nil }
        let lengthStr = String(data: data.prefix(firstNewline), encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let length = Int(lengthStr), length > 0 else { return nil }

        let msgStart = firstNewline + 1
        let msgEnd = min(msgStart + length, data.count)
        guard msgEnd > msgStart else { return nil }
        let msgData = data.subdata(in: msgStart..<msgEnd)

        // Find header / body split — two newlines in a row (LF or CRLF).
        guard let splitIdx = msgData.findHeaderBodySplit() else { return nil }
        let headerData = msgData.prefix(splitIdx)
        let bodyData   = msgData.subdata(in: (splitIdx + 2)..<msgData.count)

        let headers = parseHeaders(headerData)
        let body    = cleanBody(bodyData)

        let messageId = stripAngleBrackets(headers["message-id"] ?? "")
        guard !messageId.isEmpty else { return nil }

        return Parsed(
            messageId: messageId,
            subject: headers["subject"] ?? "",
            from:    headers["from"]    ?? "",
            date:    parseRFC822Date(headers["date"] ?? ""),
            body:    body
        )
    }

    // MARK: - Headers

    private static func parseHeaders(_ data: Data) -> [String: String] {
        // RFC822 headers can fold across multiple lines (continuation
        // lines start with whitespace). We normalize those first.
        guard let raw = String(data: data, encoding: .utf8)
              ?? String(data: data, encoding: .isoLatin1) else {
            return [:]
        }

        var unfolded: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let first = l.first, (first == " " || first == "\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + l.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(l)
            }
        }

        var out: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out[key] == nil {                    // keep only the first occurrence
                out[key] = value
            }
        }
        return out
    }

    private static func stripAngleBrackets(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("<") { v.removeFirst() }
        if v.hasSuffix(">") { v.removeLast() }
        return v
    }

    // MARK: - Body cleanup

    /// Strip the trailing Apple plist (if present), decode as UTF-8 with
    /// Latin-1 fallback, remove obvious binary garbage, strip HTML tags.
    /// Caps at ~10 KB — enough for FTS hits, keeps the index lean.
    private static func cleanBody(_ data: Data) -> String {
        // Plain UTF-8 decode (replace invalid bytes silently).
        var s = String(data: data, encoding: .utf8)
              ?? String(data: data, encoding: .isoLatin1)
              ?? ""

        // Drop trailing Apple plist if it bled into the body region for
        // any reason (defensive — shouldn't happen given the length field).
        if let plistRange = s.range(of: "<?xml", options: .backwards) {
            s = String(s[..<plistRange.lowerBound])
        }

        // Strip HTML tags. Email HTML is full of weird inline styles —
        // a simple regex is good enough for indexing.
        if s.contains("<") && s.contains(">") {
            s = s.replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
            )
        }

        // Collapse whitespace and trim.
        s = s.replacingOccurrences(
            of: "[\\s\\u{00A0}]+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if s.count > 10_000 { s = String(s.prefix(10_000)) }
        return s
    }

    // MARK: - Date parsing

    private static let rfc822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        return f
    }()

    private static let rfc822Formats: [String] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ]

    private static func parseRFC822Date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        for fmt in rfc822Formats {
            rfc822Formatter.dateFormat = fmt
            if let d = rfc822Formatter.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Data helpers

private extension Data {
    /// Returns the index just before the blank line (two consecutive LF or
    /// CRLF) that separates headers from body. Handles both Unix and
    /// dos-style line endings.
    func findHeaderBodySplit() -> Int? {
        // Look for "\n\n" or "\r\n\r\n"
        for i in 0..<(count - 1) {
            if self[i] == 0x0a && self[i+1] == 0x0a {
                return i
            }
            if i + 3 < count, self[i] == 0x0d, self[i+1] == 0x0a,
               self[i+2] == 0x0d, self[i+3] == 0x0a {
                return i + 1   // point at the first \n; caller adds 2 to skip both newlines
            }
        }
        return nil
    }

    func firstIndex(of byte: UInt8) -> Int? {
        return withUnsafeBytes { raw -> Int? in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<count where ptr[i] == byte { return i }
            return nil
        }
    }
}
