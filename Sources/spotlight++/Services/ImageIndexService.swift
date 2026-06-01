import Accelerate
import AppKit
import CoreImage
import CoreML
import Foundation
import SQLite3
import Vision

private let SQLITE_TRANSIENT_IMG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Indexes a set of folders (Pictures, Desktop, Downloads, plus any user-added
/// roots) and serves natural-language queries against them. Per image we
/// capture three signals on-device:
///
///   • Apple Vision label classifier (`VNClassifyImageRequest`) — coarse
///     scene/object labels with confidence.
///   • Apple Vision OCR (`VNRecognizeTextRequest`) — readable text inside
///     the image (menu, sign, screenshot text).
///   • MobileCLIP-S2 image embedding (CoreML) — 512-d unit vector for
///     semantic text-to-image cosine search.
///
/// At query time we encode the user's query with MobileCLIP-S2's text
/// encoder, run a cosine pass over all embeddings, and add a small boost
/// for direct label or OCR token matches. Results are returned as
/// `SearchResult` with `source: .images` and `openTarget: .file(path)`.
actor ImageIndexService {

    private let dbPath: String
    private var db: OpaquePointer?

    /// Folders we walk. Configurable later via Settings UI.
    private let scanRoots: [URL]
    private let allowedExts: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","webp","gif"]

    /// Lazily-loaded CoreML encoders. Loading takes ~50-100ms, so we only
    /// pay that cost the first time a search or index sweep runs.
    private var clipImage: MLModel?
    private var clipText: MLModel?
    private var tokenizer: CLIPTokenizer?

    // Debounce so we don't rescan on every search.
    private var lastScan: Date = .distantPast
    private static let scanLifetime: TimeInterval = 600  // 10 min

    init(scanRoots: [URL]? = nil) {
        let home = NSHomeDirectory()
        let supportDir = home + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.dbPath = supportDir + "/images.db"

        if let scanRoots {
            self.scanRoots = scanRoots
        } else {
            self.scanRoots = [
                URL(fileURLWithPath: home + "/Pictures"),
                URL(fileURLWithPath: home + "/Desktop"),
                URL(fileURLWithPath: home + "/Downloads"),
            ]
        }

        var handle: OpaquePointer?
        if sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            self.db = handle
            Self.createSchema(db: handle)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer?) {
        // Original `images` table holds path + image-CLIP embedding + cached
        // Vision JSON. The newer `labels` + `image_labels` pair adds
        // synonym-aware label matching via CLIP text embeddings.
        // The FTS5 mirror gives us BM25 over OCR text.
        let sql = """
        CREATE TABLE IF NOT EXISTS images (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          path          TEXT NOT NULL UNIQUE,
          file_mtime    INTEGER NOT NULL,
          width         INTEGER,
          height        INTEGER,
          ocr           TEXT,
          labels_json   TEXT,
          embedding     BLOB,            -- 512 float32, L2-normalised
          indexed_at    INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_images_path ON images(path);

        -- Global Vision-label vocabulary, ≤~1000 unique strings ever. Each
        -- name is CLIP-text-encoded once and cached, so query-time we can
        -- score images by max-cosine over their tagged labels — handling
        -- "glasses" ↔ "eyeglasses" semantically rather than via porter stems.
        CREATE TABLE IF NOT EXISTS labels (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          name       TEXT NOT NULL UNIQUE,
          embedding  BLOB                  -- 512 float32, L2-normalised. NULL = not yet embedded
        );

        CREATE TABLE IF NOT EXISTS image_labels (
          image_id   INTEGER NOT NULL,
          label_id   INTEGER NOT NULL,
          confidence REAL NOT NULL,
          PRIMARY KEY (image_id, label_id),
          FOREIGN KEY (image_id) REFERENCES images(id) ON DELETE CASCADE,
          FOREIGN KEY (label_id) REFERENCES labels(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_image_labels_image ON image_labels(image_id);
        CREATE INDEX IF NOT EXISTS idx_image_labels_label ON image_labels(label_id);

        -- FTS5 contentless mirror of `images.ocr`. Manual sync via triggers
        -- (FTS5 'content=' option) keeps the index lean — only the
        -- inverted index, no duplicated OCR text.
        CREATE VIRTUAL TABLE IF NOT EXISTS images_fts USING fts5(
          ocr,
          content='images',
          content_rowid='id',
          tokenize='porter unicode61'
        );

        CREATE TRIGGER IF NOT EXISTS images_ai AFTER INSERT ON images BEGIN
          INSERT INTO images_fts(rowid, ocr) VALUES (new.id, new.ocr);
        END;
        CREATE TRIGGER IF NOT EXISTS images_ad AFTER DELETE ON images BEGIN
          INSERT INTO images_fts(images_fts, rowid, ocr) VALUES('delete', old.id, old.ocr);
        END;
        CREATE TRIGGER IF NOT EXISTS images_au AFTER UPDATE ON images BEGIN
          INSERT INTO images_fts(images_fts, rowid, ocr) VALUES('delete', old.id, old.ocr);
          INSERT INTO images_fts(rowid, ocr) VALUES (new.id, new.ocr);
        END;

        -- One-time backfill / migration flags
        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Public API used by the ViewModel

    /// Called once at app start. Loads the CoreML models and triggers a
    /// background sweep of all scan roots. Cheap to call repeatedly: the
    /// sweep is debounced by `scanLifetime`.
    func warmCache() async {
        _ = await ensureModels()
        await migrateIfNeeded()
        await sweepIfStale()
    }

    /// One-time backfill: when the schema was upgraded to add the
    /// `labels` / `image_labels` / `images_fts` tables, the rows that
    /// were already indexed predate them. We walk the existing rows,
    /// rebuild the FTS5 inverted index from the cached `ocr` column,
    /// and re-tag each image from its `labels_json`. Embeddings for new
    /// label names get computed on the fly; old image-CLIP embeddings
    /// are reused verbatim. Tracked via the `meta` table so this only
    /// runs once per upgrade.
    private func migrateIfNeeded() async {
        guard let db else { return }
        if metaValue("rrf_backfill_done") == "1" { return }
        guard await ensureModels() else { return }

        NSLog("ImageIndexService: one-time backfill of labels + FTS5 for existing rows")
        // FTS5 rebuild
        sqlite3_exec(db, "INSERT INTO images_fts(images_fts) VALUES('rebuild')", nil, nil, nil)

        // Walk existing rows and re-tag from labels_json
        var stmt: OpaquePointer?
        let sql = "SELECT id, labels_json FROM images WHERE labels_json IS NOT NULL"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var rows: [(Int64, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let js = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                rows.append((id, js))
            }
            sqlite3_finalize(stmt)
            var done = 0
            for (id, js) in rows {
                guard let data = js.data(using: .utf8),
                      let hits = try? JSONDecoder().decode([LabelHit].self, from: data) else { continue }
                writeImageLabels(imageID: id, labels: hits)
                done += 1
                await Task.yield()
                if done % 1000 == 0 {
                    NSLog("ImageIndexService: backfilled \(done)/\(rows.count)")
                }
            }
        } else {
            sqlite3_finalize(stmt)
        }

        setMetaValue("rrf_backfill_done", "1")
        loadLabelCache()
        NSLog("ImageIndexService: backfill complete")
    }

    private func metaValue(_ key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_IMG)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }
        return nil
    }

    private func setMetaValue(_ key: String, _ value: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_step(stmt)
    }

    /// Force an immediate full sweep. Useful as a "Reindex" command later.
    func sweep() async {
        lastScan = .distantPast
        await sweepIfStale()
    }

    /// Run the natural-language query and return ranked image results.
    ///
    /// Fuses three signals via Reciprocal Rank Fusion (k=60):
    ///   1. CLIP cosine over the image embedding   — general visual concept
    ///   2. CLIP cosine over per-image best label  — synonym-aware tag match
    ///   3. BM25 over OCR text via FTS5            — exact-text-in-image
    ///
    /// RRF sidesteps the score-normalisation problem (BM25 ∈ [0, ∞),
    /// cosine ∈ [-1, 1]) — only the per-list rank position matters.
    /// k=60 is the canonical constant from the Cormack/Clarke/Buettcher
    /// paper, balanced so a top-5 hit in one signal still beats a
    /// rank-200 hit in two others.
    func search(_ query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard await ensureModels(),
              let qVec = encodeText(trimmed) else { return [] }
        guard let db else { return [] }

        // Make sure the label vector cache is warm — the search loop reads
        // it without going through SQLite per row.
        if labelCache.isEmpty { loadLabelCache() }

        // ─── Pull every image row's (id, path, ocr, embedding) once ────────
        struct Row {
            let id: Int64; let path: String; let ocr: String; let w: Int; let h: Int
            let imgEmb: [Float]
        }
        var rows: [Int64: Row] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT id, path, ocr, embedding, width, height FROM images WHERE embedding IS NOT NULL"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let path = String(cString: sqlite3_column_text(stmt, 1))
                let ocr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                guard let blob = sqlite3_column_blob(stmt, 3),
                      sqlite3_column_bytes(stmt, 3) == 512 * MemoryLayout<Float>.size else { continue }
                let buf = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: 512)
                let w = Int(sqlite3_column_int(stmt, 4))
                let h = Int(sqlite3_column_int(stmt, 5))
                rows[id] = Row(id: id, path: path, ocr: ocr, w: w, h: h, imgEmb: Array(buf))
            }
        }
        sqlite3_finalize(stmt)
        if rows.isEmpty { return [] }

        // ─── Signal 1: image-CLIP cosine ───────────────────────────────────
        var imgScores: [(Int64, Float)] = []
        imgScores.reserveCapacity(rows.count)
        for (id, r) in rows {
            var s: Float = 0
            vDSP_dotpr(qVec, 1, r.imgEmb, 1, &s, vDSP_Length(512))
            imgScores.append((id, s))
        }
        imgScores.sort { $0.1 > $1.1 }

        // ─── Signal 2: best-label cosine per image ─────────────────────────
        // First: cosine(query, every label) once.
        var labelScore: [Int64: Float] = [:]
        for (labelID, lvec) in labelCache {
            var s: Float = 0
            vDSP_dotpr(qVec, 1, lvec, 1, &s, vDSP_Length(512))
            labelScore[labelID] = s
        }
        // Then: per image, max over its tagged labels.
        var bestLabelPerImage: [Int64: Float] = [:]
        var llStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT image_id, label_id FROM image_labels", -1, &llStmt, nil) == SQLITE_OK {
            while sqlite3_step(llStmt) == SQLITE_ROW {
                let imageID = sqlite3_column_int64(llStmt, 0)
                let labelID = sqlite3_column_int64(llStmt, 1)
                guard let s = labelScore[labelID] else { continue }
                if let cur = bestLabelPerImage[imageID] {
                    if s > cur { bestLabelPerImage[imageID] = s }
                } else {
                    bestLabelPerImage[imageID] = s
                }
            }
        }
        sqlite3_finalize(llStmt)
        let labelRanks = bestLabelPerImage
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }

        // ─── Signal 3: BM25 over OCR via FTS5 ──────────────────────────────
        var bm25Ranks: [(Int64, Float)] = []
        if let fts = buildFTSMatch(from: trimmed) {
            var bmStmt: OpaquePointer?
            let bmSql = "SELECT rowid, bm25(images_fts) FROM images_fts WHERE images_fts MATCH ? ORDER BY bm25(images_fts) LIMIT 200"
            if sqlite3_prepare_v2(db, bmSql, -1, &bmStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(bmStmt, 1, fts, -1, SQLITE_TRANSIENT_IMG)
                while sqlite3_step(bmStmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(bmStmt, 0)
                    let s = Float(-sqlite3_column_double(bmStmt, 1))   // FTS5 BM25 is negative; flip for "higher = better"
                    bm25Ranks.append((id, s))
                }
            }
            sqlite3_finalize(bmStmt)
        }

        // ─── Fuse via Reciprocal Rank Fusion ───────────────────────────────
        let k: Double = 60
        var rrf: [Int64: Double] = [:]
        for (pos, p) in imgScores.enumerated()   { rrf[p.0, default: 0] += 1 / (k + Double(pos) + 1) }
        for (pos, p) in labelRanks.enumerated()  { rrf[p.0, default: 0] += 1 / (k + Double(pos) + 1) }
        for (pos, p) in bm25Ranks.enumerated()   { rrf[p.0, default: 0] += 1 / (k + Double(pos) + 1) }

        // Index the per-signal cosines so we can display them in the badge.
        let imgCosine = Dictionary(uniqueKeysWithValues: imgScores.map { ($0.0, $0.1) })

        let fused = rrf.sorted { $0.value > $1.value }.prefix(limit)

        return fused.compactMap { (imageID, fusedScore) -> SearchResult? in
            guard let r = rows[imageID] else { return nil }
            let imgC = imgCosine[imageID] ?? 0
            let labC = bestLabelPerImage[imageID] ?? 0

            // Subtitle: OCR snippet wins if non-empty, then top labels.
            let snippet = r.ocr.trimmingCharacters(in: .whitespacesAndNewlines)
                              .replacingOccurrences(of: "\n", with: " ")
            let topLabels = topLabelNames(forImage: imageID).joined(separator: ", ")
            let subtitle: String
            if !snippet.isEmpty { subtitle = String(snippet.prefix(120)) }
            else if !topLabels.isEmpty { subtitle = topLabels }
            else { subtitle = "\(r.w)×\(r.h)" }

            // Rank encodes the fused score into a sortable Int so the
            // cross-source merge in SearchViewModel keeps strong fused
            // matches near the top of the unified results.
            let rank = Int(fusedScore * 100_000)

            // Badge shows whichever signal won this image so the user has
            // a quick intuition for "why did this match".
            let badge = String(format: "%.2f", max(imgC, labC))

            let iconData = makeThumbnail(path: r.path, maxDim: 256)
            return SearchResult(
                title: (r.path as NSString).lastPathComponent,
                subtitle: subtitle,
                source: .images,
                date: nil,
                badge: badge,
                openTarget: .file(r.path),
                rank: rank,
                iconData: iconData
            )
        }
    }

    /// Top 3 label names for an image, ordered by stored confidence desc.
    /// Used to fill the result row subtitle when there's no OCR text.
    private func topLabelNames(forImage imageID: Int64) -> [String] {
        guard let db else { return [] }
        var out: [String] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT labels.name FROM image_labels
        JOIN labels ON labels.id = image_labels.label_id
        WHERE image_labels.image_id = ?
        ORDER BY image_labels.confidence DESC LIMIT 3
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, imageID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Convert a free-text query into an FTS5 MATCH expression. Splits on
    /// whitespace, drops 1-char tokens, joins with `OR` so a multi-word
    /// query lights up partial matches. Returns nil for empty input or any
    /// token containing characters FTS5 would reject.
    private func buildFTSMatch(from query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        // Use prefix match (`token*`) so "glasses" lights up "glass", "glassware" too.
        return tokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    // MARK: - Model loading

    /// True if both CoreML models loaded successfully. Cached after first call.
    private func ensureModels() async -> Bool {
        if clipImage != nil && clipText != nil && tokenizer != nil { return true }
        guard let imgURL = Bundle.module.url(forResource: "mobileclip_s2_image", withExtension: "mlmodelc", subdirectory: "Models"),
              let txtURL = Bundle.module.url(forResource: "mobileclip_s2_text",  withExtension: "mlmodelc", subdirectory: "Models")
        else {
            NSLog("ImageIndexService: MobileCLIP models not found in bundle")
            return false
        }
        // Indexing path: prefer CPU+GPU over ANE. ANE has thrown
        // NSGenericException on a specific user image (HEIC with unusual
        // color profile / 16-bit components) which Swift `try?` cannot
        // catch — it terminates the process. CPU+GPU is ~2-3x slower
        // (~100ms/img instead of 30ms) but robust across every CGImage
        // shape Vision can decode.
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
        do {
            self.clipImage = try MLModel(contentsOf: imgURL, configuration: cfg)
            self.clipText  = try MLModel(contentsOf: txtURL, configuration: cfg)
            self.tokenizer = CLIPTokenizer()
            return true
        } catch {
            NSLog("ImageIndexService: failed to load CoreML models: \(error)")
            return false
        }
    }

    // MARK: - Indexing

    private func sweepIfStale() async {
        guard Date().timeIntervalSince(lastScan) >= Self.scanLifetime else { return }
        lastScan = Date()
        await sweepNow()
    }

    private func sweepNow() async {
        guard await ensureModels() else { return }
        let files = enumerate(roots: scanRoots)
        let newOrChanged = files.filter { needsIndex($0) }
        if newOrChanged.isEmpty { return }
        NSLog("ImageIndexService: indexing \(newOrChanged.count) image(s)")
        var done = 0
        for url in newOrChanged {
            indexOne(url)
            done += 1
            // Yield every image so search() calls (which run on the same
            // actor) can interleave. Without this, a search waits for the
            // ENTIRE sweep to finish before its turn comes up.
            await Task.yield()
            if done % 250 == 0 {
                NSLog("ImageIndexService: \(done)/\(newOrChanged.count) indexed")
            }
        }
        NSLog("ImageIndexService: sweep complete (\(done) indexed)")
    }

    private func enumerate(roots: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let enumr = fm.enumerator(at: root,
                                            includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in enumr {
                if allowedExts.contains(f.pathExtension.lowercased()) {
                    out.append(f)
                }
            }
        }
        return out
    }

    private func needsIndex(_ url: URL) -> Bool {
        guard let db else { return false }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let sql = "SELECT file_mtime FROM images WHERE path = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return true }
        sqlite3_bind_text(stmt, 1, url.path, -1, SQLITE_TRANSIENT_IMG)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let storedMtime = sqlite3_column_int64(stmt, 0)
            return Int64(mtime) > storedMtime
        }
        return true
    }

    private func indexOne(_ url: URL) {
        guard let cg = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return
        }
        // Guard against pathological CGImages that have crashed CoreML in
        // the past: zero-dim, absurdly huge, or 16-bit-per-component HDR.
        guard cg.width >= 32, cg.height >= 32,
              cg.width <= 16384, cg.height <= 16384,
              cg.bitsPerComponent <= 8 else {
            return
        }
        let v = runVision(on: cg)
        let emb = encodeImage(cg) ?? []
        upsert(path: url.path,
               mtime: Int64(((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970) ?? 0),
               width: cg.width, height: cg.height,
               ocr: v.ocr, labels: v.labels, embedding: emb)
    }

    private func upsert(path: String, mtime: Int64, width: Int, height: Int,
                        ocr: String, labels: [LabelHit], embedding: [Float]) {
        guard let db else { return }
        let labelJSON = (try? JSONEncoder().encode(labels)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = """
        INSERT INTO images (path, file_mtime, width, height, ocr, labels_json, embedding, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          file_mtime = excluded.file_mtime,
          width      = excluded.width,
          height     = excluded.height,
          ocr        = excluded.ocr,
          labels_json= excluded.labels_json,
          embedding  = excluded.embedding,
          indexed_at = excluded.indexed_at
        RETURNING id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_bind_int64(stmt, 2, mtime)
        sqlite3_bind_int(stmt, 3, Int32(width))
        sqlite3_bind_int(stmt, 4, Int32(height))
        sqlite3_bind_text(stmt, 5, ocr, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_bind_text(stmt, 6, labelJSON, -1, SQLITE_TRANSIENT_IMG)
        embedding.withUnsafeBufferPointer { buf in
            _ = sqlite3_bind_blob(stmt, 7, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT_IMG)
        }
        sqlite3_bind_int64(stmt, 8, Int64(Date().timeIntervalSince1970))
        var imageID: Int64 = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            imageID = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        guard imageID > 0 else { return }
        writeImageLabels(imageID: imageID, labels: labels)
    }

    /// Wipe and rewrite the image→label many-to-many rows, looking up (and
    /// lazily embedding) each label name as it appears. Cheap when most
    /// labels are already cached.
    private func writeImageLabels(imageID: Int64, labels: [LabelHit]) {
        guard let db else { return }
        // Drop any prior rows for this image — on update we re-tag from
        // scratch since Vision may have produced a different label set.
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM image_labels WHERE image_id = ?", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_int64(del, 1, imageID)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)

        for hit in labels {
            let labelID = ensureLabel(name: hit.name)
            guard labelID > 0 else { continue }
            var ins: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO image_labels(image_id, label_id, confidence) VALUES (?, ?, ?)", -1, &ins, nil) == SQLITE_OK {
                sqlite3_bind_int64(ins, 1, imageID)
                sqlite3_bind_int64(ins, 2, labelID)
                sqlite3_bind_double(ins, 3, Double(hit.confidence))
                sqlite3_step(ins)
            }
            sqlite3_finalize(ins)
        }
    }

    /// Ensure a (name → id) row exists in `labels`. If the row is fresh or
    /// its embedding is NULL, encode the label name via the CLIP text encoder
    /// and persist the 512-d vector. Subsequent lookups are pure SQLite.
    @discardableResult
    private func ensureLabel(name: String) -> Int64 {
        guard let db else { return 0 }
        var sel: OpaquePointer?
        var existing: (id: Int64, hasEmb: Bool) = (0, false)
        if sqlite3_prepare_v2(db, "SELECT id, embedding IS NOT NULL FROM labels WHERE name = ?", -1, &sel, nil) == SQLITE_OK {
            sqlite3_bind_text(sel, 1, name, -1, SQLITE_TRANSIENT_IMG)
            if sqlite3_step(sel) == SQLITE_ROW {
                existing = (sqlite3_column_int64(sel, 0), sqlite3_column_int(sel, 1) != 0)
            }
        }
        sqlite3_finalize(sel)

        if existing.id > 0 && existing.hasEmb { return existing.id }

        // Either no row, or row with NULL embedding → compute the embedding now.
        let vec = encodeText(name) ?? []
        guard vec.count == 512 else {
            // Encoder unavailable; still record the name so we can backfill later.
            if existing.id > 0 { return existing.id }
            var ins: OpaquePointer?
            var newID: Int64 = 0
            if sqlite3_prepare_v2(db, "INSERT INTO labels(name) VALUES (?) RETURNING id", -1, &ins, nil) == SQLITE_OK {
                sqlite3_bind_text(ins, 1, name, -1, SQLITE_TRANSIENT_IMG)
                while sqlite3_step(ins) == SQLITE_ROW {
                    newID = sqlite3_column_int64(ins, 0)
                }
            }
            sqlite3_finalize(ins)
            return newID
        }

        if existing.id > 0 {
            // UPDATE the embedding in place
            var upd: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE labels SET embedding = ? WHERE id = ?", -1, &upd, nil) == SQLITE_OK {
                vec.withUnsafeBufferPointer { buf in
                    _ = sqlite3_bind_blob(upd, 1, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT_IMG)
                }
                sqlite3_bind_int64(upd, 2, existing.id)
                sqlite3_step(upd)
            }
            sqlite3_finalize(upd)
            // Refresh in-memory cache so search() picks up the new row.
            labelCache[existing.id] = vec
            labelCacheName[existing.id] = name
            return existing.id
        }

        // Fresh row — INSERT with the embedding
        var ins: OpaquePointer?
        var newID: Int64 = 0
        if sqlite3_prepare_v2(db, "INSERT INTO labels(name, embedding) VALUES (?, ?) RETURNING id", -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_text(ins, 1, name, -1, SQLITE_TRANSIENT_IMG)
            vec.withUnsafeBufferPointer { buf in
                _ = sqlite3_bind_blob(ins, 2, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT_IMG)
            }
            while sqlite3_step(ins) == SQLITE_ROW {
                newID = sqlite3_column_int64(ins, 0)
            }
        }
        sqlite3_finalize(ins)
        if newID > 0 {
            labelCache[newID] = vec
            labelCacheName[newID] = name
        }
        return newID
    }

    // In-memory cache of (labelID → CLIP-text embedding). Populated lazily
    // as labels are encountered and reused at query time so we don't
    // re-pull 1000 BLOBs from SQLite on every search.
    private var labelCache: [Int64: [Float]] = [:]
    private var labelCacheName: [Int64: String] = [:]

    /// Pull every label's (id, name, embedding) into the in-memory caches.
    /// Idempotent. Run once after model load so search() can score without
    /// hitting SQLite for label vectors.
    private func loadLabelCache() {
        guard let db else { return }
        labelCache.removeAll(keepingCapacity: true)
        labelCacheName.removeAll(keepingCapacity: true)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id, name, embedding FROM labels WHERE embedding IS NOT NULL", -1, &stmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = String(cString: sqlite3_column_text(stmt, 1))
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let bytes = sqlite3_column_bytes(stmt, 2)
            guard bytes == 512 * MemoryLayout<Float>.size else { continue }
            let buf = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: 512)
            labelCache[id] = Array(buf)
            labelCacheName[id] = name
        }
    }

    // MARK: - Vision (labels + OCR)

    private func runVision(on image: CGImage) -> (ocr: String, labels: [LabelHit]) {
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify, text])
        let labels: [LabelHit] = (classify.results ?? [])
            .filter { $0.confidence >= 0.25 }
            .prefix(15)
            .map { LabelHit(name: $0.identifier, confidence: $0.confidence) }
        let ocr = (text.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        return (ocr, labels)
    }

    // MARK: - CLIP encoders (image + text)

    private func encodeImage(_ cg: CGImage) -> [Float]? {
        guard let model = clipImage else { return nil }
        guard let pb = makePixelBuffer(from: cg, w: 256, h: 256) else { return nil }
        let inp = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
        guard let inp,
              let res = try? model.prediction(from: inp),
              let multi = res.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
        return l2(extract(multi))
    }

    private func encodeText(_ query: String) -> [Float]? {
        guard let model = clipText, let tok = tokenizer else { return nil }
        // Apple's CLIPTokenizer.encode_full already returns a 77-element
        // zero-padded Int array with <BOS> + tokens + <EOS> + zeros.
        let ids = tok.encode_full(text: query)
        guard ids.count == 77, let arr = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
        for (i, id) in ids.enumerated() { arr[i] = NSNumber(value: id) }
        let inp = try? MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: arr)])
        guard let inp,
              let res = try? model.prediction(from: inp),
              let multi = res.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
        return l2(extract(multi))
    }

    // MARK: - helpers

    private func extract(_ multi: MLMultiArray) -> [Float] {
        let n = multi.count
        var out = [Float](repeating: 0, count: n)
        let p = multi.dataPointer.bindMemory(to: Float.self, capacity: n)
        for i in 0..<n { out[i] = p[i] }
        return out
    }

    private func l2(_ v: [Float]) -> [Float] {
        var sq: Float = 0
        vDSP_svesq(v, 1, &sq, vDSP_Length(v.count))
        let norm = sqrt(sq) + 1e-9
        var inv = 1.0 / norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    private func makePixelBuffer(from cg: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
        let attrs: NSDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func makeThumbnail(path: String, maxDim: Int) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: NSDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        // Encode JPEG so the SearchResult row can render via NSImage(data:).
        let dest = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: NSDictionary = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(dst, thumb, props)
        CGImageDestinationFinalize(dst)
        return dest as Data
    }
}

// MARK: - Persisted label record

struct LabelHit: Codable {
    let name: String
    let confidence: Float
}
