import Accelerate
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_ES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the pre-built `embeddings.db` produced by
/// `scripts/embed_messages.py`. For each query the planner gives us a
/// `search_term`; we embed *that* (one OpenAI call), pull the candidate
/// rows' pre-computed vectors from SQLite, and rerank with cosine.
///
/// v0 scope: Discord only. Other sources can join the table later — the
/// schema already keys on (message_id, source, model).
actor EmbeddingStore {
    static let model = "text-embedding-3-small"
    static let dim   = 1536

    private let dbPath: String
    private var db: OpaquePointer?
    private var cachedKey: String?

    private static let embeddingsEndpoint =
        URL(string: "https://api.openai.com/v1/embeddings")!

    init() {
        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.dbPath = supportDir + "/embeddings.db"

        var handle: OpaquePointer?
        if sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            self.db = handle
        } else {
            self.db = nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// True when the embeddings db exists and has at least one Discord row.
    /// Callers should fall back to the keyword filter when this is false.
    func isAvailable() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM embeddings WHERE source='discord' AND model=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, Self.model, -1, SQLITE_TRANSIENT_ES)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Query embedding

    /// Embed a single query string via OpenAI. ~150-300ms latency.
    func embedQuery(_ text: String, apiKey: String) async throws -> [Float] {
        let body: [String: Any] = ["model": Self.model, "input": text]
        var request = URLRequest(url: Self.embeddingsEndpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmbeddingError.api(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        let parsed = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard let vec = parsed.data.first?.embedding else {
            throw EmbeddingError.api("empty embedding response")
        }
        return vec
    }

    // MARK: - Candidate lookup

    /// Bulk-fetch vectors for the given Discord message_ids. Missing rows are
    /// simply omitted from the result — callers should drop those candidates
    /// (or keep them at the bottom by falling back to existing rank).
    func vectors(forDiscordMessages ids: [String]) -> [String: [Float]] {
        guard let db, !ids.isEmpty else { return [:] }
        // Build a parameterized IN-clause. ids are Discord snowflakes (digits)
        // so they're safe to template, but we still bind to keep one code path.
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT message_id, embedding
            FROM embeddings
            WHERE source = 'discord'
              AND model = ?
              AND message_id IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.model, -1, SQLITE_TRANSIENT_ES)
        for (i, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), id, -1, SQLITE_TRANSIENT_ES)
        }
        var out: [String: [Float]] = [:]
        out.reserveCapacity(ids.count)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let msgId = String(cString: cstr)
            guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 1))
            guard len == Self.dim * MemoryLayout<Float>.size else { continue }
            let vec = [Float](unsafeUninitializedCapacity: Self.dim) { buf, count in
                memcpy(buf.baseAddress!, bytes, len)
                count = Self.dim
            }
            out[msgId] = vec
        }
        return out
    }

    // MARK: - Cosine

    /// Cosine similarity using Accelerate's vDSP. Both vectors must be the
    /// same length; returns 0 for degenerate inputs rather than NaN.
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }
}

// MARK: - Decoding

private struct EmbedResponse: Decodable {
    let data: [Datum]
    struct Datum: Decodable { let embedding: [Float] }
}

enum EmbeddingError: Error, CustomStringConvertible {
    case api(String)
    var description: String {
        switch self {
        case .api(let s): return "Embeddings API error: \(s)"
        }
    }
}

// MARK: - Discord URL → message_id

extension SearchResult {
    /// For Discord results we encode the message_id in the openTarget URL
    /// (discord://-/channels/<guild>/<channel>/<messageId>). Pull it out
    /// so we can rerank by its pre-computed embedding.
    var discordMessageId: String? {
        guard case .url(let s) = openTarget,
              s.hasPrefix("discord://"),
              source == .discord else { return nil }
        // Last path segment is the messageId for any /channels/.../.../id URL.
        let parts = s.split(separator: "/")
        guard let last = parts.last, last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }
}
