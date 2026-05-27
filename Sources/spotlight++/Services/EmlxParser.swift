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
        let body    = cleanBody(bodyData, headers: headers)

        let messageId = stripAngleBrackets(headers["message-id"] ?? "")
        guard !messageId.isEmpty else { return nil }

        // Decode RFC 2047 encoded-word in human-facing fields. Raw form looks
        // like =?UTF-8?B?8J+Xkw==?= (base64) or =?utf-8?Q?Seed=20deals?=
        // (quoted-printable). Search hits on the raw form, but the snippet
        // and the visible subject/sender both display the decoded text.
        return Parsed(
            messageId: messageId,
            subject: decodeMimeWords(headers["subject"] ?? ""),
            from:    decodeMimeWords(headers["from"]    ?? ""),
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

    /// Extracts the most useful textual content from a (possibly multipart)
    /// MIME body. Steps:
    ///   1. If Content-Type is multipart/*, find the text/plain part using
    ///      the declared boundary; fall back to text/html if no plain part.
    ///   2. Decode the chosen part per its Content-Transfer-Encoding
    ///      (quoted-printable / base64 / 7bit-8bit-binary passthrough).
    ///   3. Strip HTML tags if it's an HTML part.
    ///   4. Strip quoted reply lines ('> ' prefix) and the "On <date>...
    ///      wrote:" separator so the snippet shows the NEW content of a
    ///      reply, not the chain of >>>>> quotes.
    ///   5. Collapse whitespace and cap at ~10KB for FTS index size.
    private static func cleanBody(_ data: Data, headers: [String: String]) -> String {
        let topCT  = headers["content-type"] ?? "text/plain"
        let topCTE = headers["content-transfer-encoding"] ?? ""

        let (textBytes, partCT, partCTE) = extractTextPart(
            data: data, contentType: topCT, encoding: topCTE
        )
        var s = decodeTextPart(textBytes, contentType: partCT, encoding: partCTE)

        // Drop trailing Apple plist (defensive — shouldn't bleed in given the
        // emlx byte length field, but if it does it'd pollute the snippet).
        if let plistRange = s.range(of: "<?xml", options: .backwards) {
            s = String(s[..<plistRange.lowerBound])
        }

        // Strip HTML tags. Email HTML is full of weird inline styles —
        // a simple regex is good enough for indexing.
        if partCT.lowercased().contains("html")
            || (s.contains("<") && s.contains(">")) {
            s = s.replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
            )
        }

        s = stripQuotedReply(s)

        // Collapse whitespace and trim.
        s = s.replacingOccurrences(
            of: "[\\s\\u{00A0}]+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if s.count > 10_000 { s = String(s.prefix(10_000)) }
        return s
    }

    // MARK: - Multipart extraction

    /// Returns (raw bytes of chosen part, its content-type, its CTE).
    /// For non-multipart bodies, returns the whole `data` unchanged.
    private static func extractTextPart(
        data: Data, contentType: String, encoding: String
    ) -> (Data, String, String) {
        let ctLower = contentType.lowercased()
        guard ctLower.hasPrefix("multipart/"),
              let boundary = extractBoundary(from: contentType) else {
            return (data, contentType, encoding)
        }

        let delimiter = "--\(boundary)".data(using: .utf8) ?? Data()
        guard !delimiter.isEmpty else { return (data, contentType, encoding) }

        // Slice the body into parts by boundary occurrences.
        let parts = splitData(data, by: delimiter)
        var plainPart: (Data, String, String)?
        var htmlPart:  (Data, String, String)?

        for raw in parts {
            // Each part has its own headers + blank-line + body. Find that.
            guard let splitIdx = raw.findHeaderBodySplit() else { continue }
            let pHeaderData = raw.prefix(splitIdx)
            let pBody = raw.subdata(in: (splitIdx + 2)..<raw.count)
            let pHeaders = parseHeaders(pHeaderData)
            let pCT  = pHeaders["content-type"] ?? "text/plain"
            let pCTE = pHeaders["content-transfer-encoding"] ?? ""
            let lower = pCT.lowercased()
            if lower.hasPrefix("multipart/") {
                // Nested multipart (multipart/alternative inside multipart/mixed).
                // Recurse — return the first usable text inside it.
                let inner = extractTextPart(data: pBody, contentType: pCT, encoding: pCTE)
                let innerLower = inner.1.lowercased()
                if innerLower.contains("text/plain"), plainPart == nil {
                    plainPart = inner
                } else if innerLower.contains("text/html"), htmlPart == nil {
                    htmlPart = inner
                }
            } else if lower.contains("text/plain"), plainPart == nil {
                plainPart = (pBody, pCT, pCTE)
            } else if lower.contains("text/html"), htmlPart == nil {
                htmlPart = (pBody, pCT, pCTE)
            }
            if plainPart != nil { break }   // prefer plain when found
        }

        if let p = plainPart { return p }
        if let h = htmlPart  { return h }
        return (data, contentType, encoding)
    }

    private static func extractBoundary(from contentType: String) -> String? {
        // Content-Type: multipart/mixed; boundary="--foo"
        // or boundary=foo (unquoted)
        guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var v = contentType[r.upperBound...]
        if v.hasPrefix("\"") {
            v = v.dropFirst()
            if let end = v.firstIndex(of: "\"") { return String(v[..<end]) }
        }
        // Unquoted — runs until ; or end of line
        let end = v.firstIndex(where: { $0 == ";" || $0 == "\n" || $0 == "\r" }) ?? v.endIndex
        return String(v[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// Split Data into chunks delimited by `boundary`. The boundary itself
    /// is excluded from each returned chunk. Empty chunks are dropped.
    private static func splitData(_ data: Data, by delim: Data) -> [Data] {
        var out: [Data] = []
        var searchFrom = data.startIndex
        while searchFrom < data.endIndex {
            guard let r = data.range(of: delim, in: searchFrom..<data.endIndex) else {
                let tail = data.subdata(in: searchFrom..<data.endIndex)
                if !tail.isEmpty { out.append(tail) }
                break
            }
            let chunk = data.subdata(in: searchFrom..<r.lowerBound)
            if !chunk.isEmpty { out.append(chunk) }
            searchFrom = r.upperBound
        }
        return out
    }

    private static func decodeTextPart(
        _ data: Data, contentType: String, encoding: String
    ) -> String {
        let enc = encoding.lowercased().trimmingCharacters(in: .whitespaces)
        let charset = charset(from: contentType)
        let stringEnc: String.Encoding = (charset == "iso-8859-1") ? .isoLatin1 : .utf8

        switch enc {
        case "base64":
            // Base64 in MIME ignores whitespace; clean and decode.
            let cleaned = String(data: data, encoding: .ascii)?
                .replacingOccurrences(of: "\\s", with: "", options: .regularExpression) ?? ""
            if let decoded = Data(base64Encoded: cleaned),
               let s = String(data: decoded, encoding: stringEnc) {
                return s
            }
            return String(data: data, encoding: stringEnc) ?? ""
        case "quoted-printable":
            return decodeQuotedPrintable(data, charset: stringEnc)
        default:
            // 7bit / 8bit / binary / unknown → pass through
            return String(data: data, encoding: stringEnc)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        }
    }

    private static func charset(from contentType: String) -> String {
        guard let r = contentType.range(of: "charset=", options: .caseInsensitive) else {
            return "utf-8"
        }
        var v = contentType[r.upperBound...]
        if v.hasPrefix("\"") {
            v = v.dropFirst()
            if let end = v.firstIndex(of: "\"") { return v[..<end].lowercased() }
        }
        let end = v.firstIndex(where: { $0 == ";" || $0 == "\n" || $0 == "\r" }) ?? v.endIndex
        return v[..<end].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Decode quoted-printable: =XX hex pairs are bytes; `=\n` is a soft
    /// line break (joins lines); everything else is literal.
    private static func decodeQuotedPrintable(_ data: Data, charset: String.Encoding) -> String {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b == 0x3D /* = */, i + 1 < data.endIndex {
                let b1 = data[i + 1]
                // Soft line break: =\n or =\r\n
                if b1 == 0x0a { i += 2; continue }
                if b1 == 0x0d, i + 2 < data.endIndex, data[i + 2] == 0x0a {
                    i += 3; continue
                }
                if i + 2 < data.endIndex,
                   let high = hexValue(b1), let low = hexValue(data[i + 2]) {
                    out.append(UInt8(high * 16 + low))
                    i += 3; continue
                }
            }
            out.append(b)
            i += 1
        }
        return String(data: out, encoding: charset)
            ?? String(data: out, encoding: .isoLatin1)
            ?? ""
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)             // 0-9
        case 0x41...0x46: return Int(b - 0x41 + 10)        // A-F
        case 0x61...0x66: return Int(b - 0x61 + 10)        // a-f
        default: return nil
        }
    }

    // MARK: - Quoted reply stripping

    /// Remove lines that are part of the quoted previous message — these
    /// are uninformative for snippets and bloat the FTS index. Two patterns:
    ///   1. Lines starting with one or more `>` (the universal quote prefix)
    ///   2. Everything after an "On <date>, <person> wrote:" separator line
    private static func stripQuotedReply(_ s: String) -> String {
        // Cut at the reply separator if present.
        var trimmed = s
        let separatorPatterns = [
            #"On .{1,80}wrote:"#,                  // Gmail / Apple Mail
            #"From: .{1,200}\nSent: "#,            // Outlook style
            #"-----+ ?Original Message ?-----+"#,   // Old Outlook
        ]
        for pat in separatorPatterns {
            if let r = trimmed.range(of: pat, options: .regularExpression) {
                trimmed = String(trimmed[..<r.lowerBound])
            }
        }

        // Drop lines that start with optional whitespace + '>' (one or more).
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            return !stripped.hasPrefix(">")
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - RFC 2047 encoded-word decode

    /// Decode strings like `=?UTF-8?B?8J+Xkw==?=` or `=?utf-8?Q?Seed=20deals?=`
    /// into their visible form. Multiple encoded words and surrounding plain
    /// text are handled. Used for subject and from headers.
    private static func decodeMimeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }

        // Match =?charset?encoding?text?=
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return s
        }
        let ns = s as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: s, range: fullRange)
        guard !matches.isEmpty else { return s }

        var result = ""
        var cursor = 0
        for m in matches {
            // Append plain text before this match (collapse whitespace between
            // adjacent encoded-words per RFC 2047 §5).
            if m.range.location > cursor {
                let before = ns.substring(with: NSRange(
                    location: cursor, length: m.range.location - cursor
                ))
                result += before
            }
            let charset = ns.substring(with: m.range(at: 1)).lowercased()
            let enc     = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            let stringEnc: String.Encoding =
                (charset == "iso-8859-1") ? .isoLatin1 : .utf8

            switch enc {
            case "b":
                if let d = Data(base64Encoded: payload),
                   let decoded = String(data: d, encoding: stringEnc) {
                    result += decoded
                }
            case "q":
                // RFC 2047 Q-encoding: like quoted-printable but '_' = space.
                let qBytes = (payload
                    .replacingOccurrences(of: "_", with: " "))
                    .data(using: .ascii) ?? Data()
                result += decodeQuotedPrintable(qBytes, charset: stringEnc)
            default:
                result += payload
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(
                location: cursor, length: ns.length - cursor
            ))
        }
        return result
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
