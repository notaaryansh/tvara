import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

private let SQLITE_TRANSIENT_AI = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// On-disk PNG cache for installed-app icons. Survives app restarts so
/// the search panel renders icons in the same frame as the row instead
/// of re-decoding `.icns` bitmaps on every launch.
///
/// Keyed by (path, bundle_mtime). When the user updates an app the
/// bundle's mtime moves and we re-encode; otherwise the cached PNG is
/// reused indefinitely. The companion `encodeAppIconPNG` helper does
/// the off-main downscale + PNG encode using ImageIO.
actor AppIconStore {

    /// Target pixel size for the cached PNG. 64×64 is sized for the
    /// 36-pt result row at @2x — large enough to look crisp on Retina,
    /// small enough that 300 apps × ~3 KB ≈ 1 MB total.
    static let pngMaxDim: CGFloat = 64

    private let dbPath: String
    private var db: OpaquePointer?
    private var ready = false

    init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let supportDir = NSHomeDirectory()
                + "/Library/Application Support/tvara"
            try? FileManager.default.createDirectory(
                atPath: supportDir, withIntermediateDirectories: true
            )
            self.dbPath = supportDir + "/app_icons.db"
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func ensureOpen() {
        if ready { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if handle != nil { sqlite3_close(handle) }
            return
        }
        for s in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS app_icons (
                path         TEXT PRIMARY KEY,
                bundle_mtime REAL NOT NULL,
                png          BLOB NOT NULL,
                indexed_at   REAL NOT NULL
            )
            """,
        ] {
            if sqlite3_exec(handle, s, nil, nil, nil) != SQLITE_OK {
                NSLog("AppIconStore: bootstrap stmt failed: %@", s)
                sqlite3_close(handle)
                return
            }
        }
        self.db = handle
        self.ready = true
    }

    /// Bulk fetch icons for the given paths. Missing paths are absent
    /// from the result; callers re-decode and call `upsert`.
    func bulkFetch(paths: [String]) -> [String: CachedIcon] {
        ensureOpen()
        guard let db, !paths.isEmpty else { return [:] }

        // SQLite's default SQLITE_LIMIT_VARIABLE_NUMBER is 32_766, but
        // older builds capped at 999. Batch the IN clause to stay safe.
        var out: [String: CachedIcon] = [:]
        let chunkSize = 500
        var i = 0
        while i < paths.count {
            let end = min(i + chunkSize, paths.count)
            let chunk = Array(paths[i..<end])
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            let sql = "SELECT path, bundle_mtime, png FROM app_icons WHERE path IN (\(placeholders))"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (j, p) in chunk.enumerated() {
                    sqlite3_bind_text(stmt, Int32(j + 1), p, -1, SQLITE_TRANSIENT_AI)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let p = String(cString: sqlite3_column_text(stmt, 0))
                    let mtime = sqlite3_column_double(stmt, 1)
                    let len = Int(sqlite3_column_bytes(stmt, 2))
                    guard len > 0, let blob = sqlite3_column_blob(stmt, 2) else { continue }
                    out[p] = CachedIcon(
                        bundleMtime: mtime,
                        png: Data(bytes: blob, count: len)
                    )
                }
            }
            sqlite3_finalize(stmt)
            i = end
        }
        return out
    }

    /// Persist a freshly-encoded icon. Bumps `indexed_at` on replace.
    func upsert(path: String, bundleMtime: Double, png: Data) {
        ensureOpen()
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO app_icons (path, bundle_mtime, png, indexed_at)
        VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_AI)
        sqlite3_bind_double(stmt, 2, bundleMtime)
        png.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(png.count), SQLITE_TRANSIENT_AI)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// Drop rows for paths no longer present in the scanned app set.
    /// Keeps the db from growing unbounded as the user installs and
    /// uninstalls apps.
    func prune(keepPaths: Set<String>) {
        ensureOpen()
        guard let db else { return }
        var existing: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT path FROM app_icons", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                existing.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        let toDelete = existing.filter { !keepPaths.contains($0) }
        guard !toDelete.isEmpty else { return }
        var del: OpaquePointer?
        defer { sqlite3_finalize(del) }
        guard sqlite3_prepare_v2(
            db, "DELETE FROM app_icons WHERE path=?", -1, &del, nil
        ) == SQLITE_OK else { return }
        for p in toDelete {
            sqlite3_bind_text(del, 1, p, -1, SQLITE_TRANSIENT_AI)
            sqlite3_step(del)
            sqlite3_reset(del)
        }
    }
}

/// One row from `app_icons`.
struct CachedIcon: Sendable {
    let bundleMtime: Double
    let png: Data
}

/// Render an app icon to PNG bytes at `maxDim × maxDim`. Safe to call
/// off the main actor — `NSWorkspace.shared.icon(forFile:)` is
/// documented thread-safe and ImageIO's thumbnail path runs on the
/// calling thread without GUI dependencies.
func encodeAppIconPNG(path: String, maxDim: CGFloat = AppIconStore.pngMaxDim) -> Data? {
    let icon = NSWorkspace.shared.icon(forFile: path)
    guard let tiff = icon.tiffRepresentation,
          let src = CGImageSourceCreateWithData(tiff as CFData, nil) else {
        return nil
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDim,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        return nil
    }
    let dest = NSMutableData()
    let pngType = UTType.png.identifier as CFString
    guard let dst = CGImageDestinationCreateWithData(dest, pngType, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dst, thumb, nil)
    guard CGImageDestinationFinalize(dst) else { return nil }
    return dest as Data
}

/// Best-effort bundle mtime used as the cache freshness key. App
/// updates rewrite the bundle directory so the mtime moves; if we
/// can't stat the path we fall back to 0 (never matches a cached
/// mtime, so the icon gets re-encoded next time).
func bundleMtimeSeconds(path: String) -> Double {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return date
}
