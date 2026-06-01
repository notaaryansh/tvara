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
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Public API used by the ViewModel

    /// Called once at app start. Loads the CoreML models and triggers a
    /// background sweep of all scan roots. Cheap to call repeatedly: the
    /// sweep is debounced by `scanLifetime`.
    func warmCache() async {
        _ = await ensureModels()
        await sweepIfStale()
    }

    /// Force an immediate full sweep. Useful as a "Reindex" command later.
    func sweep() async {
        lastScan = .distantPast
        await sweepIfStale()
    }

    /// Run the natural-language query and return ranked image results.
    /// Pure-CLIP cosine ranking for now — label/OCR boosts can be layered
    /// in once we measure them on the user's own corpus.
    func search(_ query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard await ensureModels(),
              let qVec = encodeText(trimmed) else { return [] }

        // Pull all (path, embedding) pairs. At our target scale (<= 100k
        // images), an in-memory dot pass over 100k × 512 floats ≈ 200ms;
        // ANN indexing can be added later.
        guard let db else { return [] }
        let sql = "SELECT path, ocr, labels_json, embedding, width, height FROM images WHERE embedding IS NOT NULL"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var scored: [(Float, String, String, String, Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let ocr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let labels = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(stmt, 3) else { continue }
            let bytes = sqlite3_column_bytes(stmt, 3)
            guard bytes == 512 * MemoryLayout<Float>.size else { continue }
            let buf = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: 512)
            let emb = Array(buf)
            let w = Int(sqlite3_column_int(stmt, 4))
            let h = Int(sqlite3_column_int(stmt, 5))
            var s: Float = 0
            vDSP_dotpr(qVec, 1, emb, 1, &s, vDSP_Length(512))
            scored.append((s, path, ocr, labels, w, h))
        }

        scored.sort { $0.0 > $1.0 }
        // Drop the long tail — anything below 0.10 cosine is essentially
        // noise. (Real strong matches start ~0.20+.)
        let cut = scored.prefix(limit).filter { $0.0 > 0.10 }

        return cut.map { (score, path, ocr, labels, w, h) in
            let name = (path as NSString).lastPathComponent
            let topLabels: String
            if let data = labels.data(using: .utf8),
               let arr = try? JSONDecoder().decode([LabelHit].self, from: data) {
                topLabels = arr.prefix(3).map { $0.name }.joined(separator: ", ")
            } else {
                topLabels = ""
            }
            // Subtitle: short OCR snippet if any, else top labels, else dimensions.
            let snippet = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
            let subtitle: String
            if !snippet.isEmpty { subtitle = String(snippet.prefix(120)) }
            else if !topLabels.isEmpty { subtitle = topLabels }
            else { subtitle = "\(w)×\(h)" }

            // Thumbnail bytes for the row icon (256px max).
            let iconData = makeThumbnail(path: path, maxDim: 256)

            // Rank encodes cosine into a sortable Int so the cross-source
            // ViewModel merge keeps strong CLIP hits near the top.
            // 0.20 cosine ≈ rank 200, 0.40 ≈ rank 400.
            let rank = Int(score * 1000)
            return SearchResult(
                title: name,
                subtitle: subtitle,
                source: .images,
                date: nil,
                badge: String(format: "%.2f", score),
                openTarget: .file(path),
                rank: rank,
                iconData: iconData
            )
        }
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
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
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
        for url in newOrChanged {
            indexOne(url)
        }
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
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_bind_int64(stmt, 2, mtime)
        sqlite3_bind_int(stmt, 3, Int32(width))
        sqlite3_bind_int(stmt, 4, Int32(height))
        sqlite3_bind_text(stmt, 5, ocr, -1, SQLITE_TRANSIENT_IMG)
        sqlite3_bind_text(stmt, 6, labelJSON, -1, SQLITE_TRANSIENT_IMG)
        embedding.withUnsafeBufferPointer { buf in
            sqlite3_bind_blob(stmt, 7, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT_IMG)
        }
        sqlite3_bind_int64(stmt, 8, Int64(Date().timeIntervalSince1970))
        sqlite3_step(stmt)
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
