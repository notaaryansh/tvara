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

    /// Nonisolated so `AppIconReader` can be pointed at the same file.
    nonisolated let dbPath: String
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

    /// Cached bundle mtimes for the given paths — the freshness keys only.
    /// The PNG bytes are deliberately NOT loaded: enrichment just needs to
    /// know which icons are stale, and rows read their PNG on demand through
    /// `AppIconReader`. Missing paths are absent from the result.
    func fetchMtimes(paths: [String]) -> [String: Double] {
        ensureOpen()
        guard let db, !paths.isEmpty else { return [:] }

        // SQLite's default SQLITE_LIMIT_VARIABLE_NUMBER is 32_766, but
        // older builds capped at 999. Batch the IN clause to stay safe.
        var out: [String: Double] = [:]
        let chunkSize = 500
        var i = 0
        while i < paths.count {
            let end = min(i + chunkSize, paths.count)
            let chunk = Array(paths[i..<end])
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            let sql = "SELECT path, bundle_mtime FROM app_icons WHERE path IN (\(placeholders))"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (j, p) in chunk.enumerated() {
                    sqlite3_bind_text(stmt, Int32(j + 1), p, -1, SQLITE_TRANSIENT_AI)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out[String(cString: sqlite3_column_text(stmt, 0))] =
                        sqlite3_column_double(stmt, 1)
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
        _ = png.withUnsafeBytes { buf in
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

/// Synchronous, read-only access to the icon PNGs in `app_icons.db`.
///
/// App rows need their icon in the same frame as the keystroke, so the
/// lookup can't hop through the `AppIconStore` actor. Holding every PNG in
/// memory to make that possible cost ~3.6 MB for the life of the app; this
/// reads just the handful of icons a query actually shows (a primary-key
/// lookup over a memory-mapped file, a few microseconds each) and lets
/// them go when the rows do.
///
/// Its own connection, guarded by a lock, so it is safe from any thread.
final class AppIconReader: @unchecked Sendable {
    private let dbPath: String
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var stmt: OpaquePointer?
    private var lastOpenAttempt: CFAbsoluteTime = 0

    init(dbPath: String) { self.dbPath = dbPath }

    deinit {
        sqlite3_finalize(stmt)
        if let db { sqlite3_close(db) }
    }

    func png(forPath path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = preparedStatement() else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_AI)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // An app that was updated since its icon was cached has a newer
        // bundle mtime. Return nil for it — the row falls back to the live
        // icon — until the next refresh re-encodes the PNG. One `stat`,
        // about a microsecond.
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        guard abs(sqlite3_column_double(stmt, 1) - mtime) < 1.0 else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, 0))
        guard len > 0, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: len)
    }

    /// Opens lazily. On a first launch the database (or its table) doesn't
    /// exist yet, so a failed open is retried — at most once a second, to
    /// keep the keystroke path cheap while it's missing.
    private func preparedStatement() -> OpaquePointer? {
        if let stmt { return stmt }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastOpenAttempt > 1 else { return nil }
        lastOpenAttempt = now

        if db == nil {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(
                dbPath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
            ) == SQLITE_OK else {
                if handle != nil { sqlite3_close(handle) }
                return nil
            }
            // Memory-map the file instead of copying pages into SQLite's
            // heap cache. Lookups read straight from the OS file cache:
            // measured at ~0.05 ms for 20 icons, first batch included, and
            // mapped file pages don't count toward the app's footprint.
            sqlite3_exec(handle, "PRAGMA mmap_size=33554432", nil, nil, nil)
            db = handle
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT png, bundle_mtime FROM app_icons WHERE path = ?", -1, &prepared, nil
        ) == SQLITE_OK else {
            sqlite3_finalize(prepared)
            return nil
        }
        stmt = prepared
        return prepared
    }
}

/// Render an app icon to PNG bytes at `maxDim × maxDim`. Safe to call
/// off the main actor — `NSWorkspace.shared.icon(forFile:)` is
/// documented thread-safe and the CoreGraphics path below has no GUI
/// dependencies.
///
/// Memory matters here: this runs once per installed app on a cold
/// cache (i.e. every first launch). It used to go through
/// `icon.tiffRepresentation`, which serializes EVERY size in the .icns
/// uncompressed (~35 MB per app), and the caller's loop never drained
/// those autoreleased buffers — ~300 apps peaked above 9 GB. Now it asks
/// for just the representation nearest the target size, draws that into
/// a `maxDim`-pixel bitmap, and wraps the work in its own autorelease
/// pool so nothing outlives the call.
func encodeAppIconPNG(path: String, maxDim: CGFloat = AppIconStore.pngMaxDim) -> Data? {
    autoreleasepool {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var proposed = CGRect(x: 0, y: 0, width: maxDim, height: maxDim)
        guard let source = icon.cgImage(
            forProposedRect: &proposed, context: nil, hints: nil
        ) else { return nil }

        let px = max(Int(maxDim.rounded()), 1)
        guard let ctx = CGContext(
            data: nil, width: px, height: px,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let thumb = ctx.makeImage() else { return nil }

        let dest = NSMutableData()
        let pngType = UTType.png.identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(dest, pngType, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dst, thumb, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return dest as Data
    }
}

/// Best-effort bundle mtime used as the cache freshness key. App
/// updates rewrite the bundle directory so the mtime moves. Returns
/// `nil` when stat fails so callers skip the disk-cache lookup AND
/// the persist — otherwise the failure would write `mtime = 0` once
/// and then match itself forever, freezing whatever (possibly stale
/// or nil) icon got cached on that first failed pass.
func bundleMtimeSeconds(path: String) -> Double? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
}
