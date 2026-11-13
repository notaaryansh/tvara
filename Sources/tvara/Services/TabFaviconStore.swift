import AppKit
import Compression
import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Favicons for open browser tabs, read straight from each browser's own
/// on-disk favicon database. Nothing is fetched from the network.
///
/// Not thread-safe: BrowserTabsService only calls it from its serial queue.
final class TabFaviconStore: @unchecked Sendable {

    enum Family { case chromium, firefox }

    /// Where each browser keeps its profiles, relative to
    /// ~/Library/Application Support.
    private static let supportDirs: [String: (dir: String, family: Family)] = [
        "com.google.Chrome": ("Google/Chrome", .chromium),
        "com.google.Chrome.beta": ("Google/Chrome Beta", .chromium),
        "com.google.Chrome.canary": ("Google/Chrome Canary", .chromium),
        "org.chromium.Chromium": ("Chromium", .chromium),
        "com.brave.Browser": ("BraveSoftware/Brave-Browser", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("com.operasoftware.Opera", .chromium),
        "company.thebrowser.Browser": ("Arc/User Data", .chromium),
        "org.mozilla.firefox": ("Firefox", .firefox),
        "org.mozilla.firefoxdeveloperedition": ("Firefox", .firefox),
        "org.mozilla.nightly": ("Firefox", .firefox),
        "app.zen-browser.zen": ("zen", .firefox),
    ]

    /// Page URL → normalized PNG. `nil` values are remembered misses, so a
    /// page without an icon isn't looked up again on every panel open.
    private var cache: [String: Data?] = [:]
    /// Parsed Firefox session per profile, reused until the file changes.
    private var sessions: [String: (mtime: Date, urlByTitle: [String: String])] = [:]

    private static func supportURL(_ dir: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dir)", isDirectory: true)
    }

    // MARK: - Firefox tab URLs

    /// Title → URL for the tabs Firefox currently has open, from the
    /// session file it rewrites every few seconds. Firefox's accessibility
    /// tree gives tab titles only; this is how a tab gets its address (and
    /// through it, its favicon). A tab opened in the last few seconds can
    /// be missing.
    func firefoxURLsByTitle(bundleID: String) -> [String: String] {
        guard let entry = Self.supportDirs[bundleID], entry.family == .firefox else { return [:] }
        // The running profile is the one whose session file changed last.
        var newest: (url: URL, mtime: Date)?
        for profile in Self.profileDirs(Self.supportURL(entry.dir).appendingPathComponent("Profiles")) {
            let file = profile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4")
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (file, mtime) }
        }
        guard let newest else { return [:] }
        if let cached = sessions[newest.url.path], cached.mtime == newest.mtime {
            return cached.urlByTitle
        }

        var urlByTitle: [String: String] = [:]
        if let raw = try? Data(contentsOf: newest.url),
           let json = Self.mozLz4Decode(raw),
           let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let windows = root["windows"] as? [[String: Any]] {
            for window in windows {
                for tab in (window["tabs"] as? [[String: Any]]) ?? [] {
                    guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty
                    else { continue }
                    // `index` is the 1-based position in the tab's history.
                    let index = min(max((tab["index"] as? Int) ?? entries.count, 1), entries.count)
                    let current = entries[index - 1]
                    guard let url = current["url"] as? String,
                          let title = current["title"] as? String, !title.isEmpty
                    else { continue }
                    if urlByTitle[title] == nil { urlByTitle[title] = url }
                }
            }
        }
        sessions = [newest.url.path: (newest.mtime, urlByTitle)]
        return urlByTitle
    }

    /// Firefox's "mozLz4" container: an 8-byte magic, the decompressed size
    /// as a little-endian UInt32, then one raw LZ4 block.
    static func mozLz4Decode(_ data: Data) -> Data? {
        let magic = Data("mozLz40\0".utf8)
        guard data.count > 12, data.prefix(8) == magic else { return nil }
        let size = data.subdata(in: 8..<12).enumerated()
            .reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard size > 0, size < 512 * 1024 * 1024 else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    d, size, s + 12, data.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? out : nil
    }

    // MARK: - Favicons

    /// Favicons for the given page URLs, keyed by URL. Pages the browser
    /// has no icon for are simply absent.
    func favicons(bundleID: String, urls: [String]) -> [String: Data] {
        guard let entry = Self.supportDirs[bundleID] else { return [:] }
        let wanted = Set(urls.filter { !$0.isEmpty })
        let missing = wanted.filter { cache[$0] == nil }
        if !missing.isEmpty {
            if cache.count > 2000 { cache.removeAll() }
            var pending = missing
            let base = Self.supportURL(entry.dir)
            let databases: [URL]
            switch entry.family {
            case .chromium:
                databases = Self.profileDirs(base).map { $0.appendingPathComponent("Favicons") }
            case .firefox:
                databases = Self.profileDirs(base.appendingPathComponent("Profiles"))
                    .map { $0.appendingPathComponent("favicons.sqlite") }
            }
            for database in databases where !pending.isEmpty {
                guard FileManager.default.fileExists(atPath: database.path) else { continue }
                for (url, png) in Self.query(database, family: entry.family, urls: pending) {
                    cache[url] = .some(png)
                    pending.remove(url)
                }
            }
            for url in pending { cache[url] = .some(nil) }
        }
        var found: [String: Data] = [:]
        for url in wanted {
            if let hit = cache[url], let png = hit { found[url] = png }
        }
        return found
    }

    /// Profile folders under a browser's data directory (Default,
    /// Profile 1, xxxx.default-release, …), most recently used first.
    private static func profileDirs(_ base: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func query(_ database: URL, family: Family, urls: Set<String>) -> [String: Data] {
        // immutable=1: read the file as it is on disk without taking locks,
        // so a running browser holding the database can't block the read
        // and we can never block the browser. The cost is that an icon
        // still sitting in the write-ahead log is missed until it lands.
        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }

        // First the icon stored for that exact page; failing that, the
        // icon of any page on the same site (?1 is then a range over
        // "origin/" … "origin0", the character after "/").
        let exact: String
        let sameSite: String
        switch family {
        case .chromium:
            let select = """
            SELECT fb.image_data FROM icon_mapping im
            JOIN favicon_bitmaps fb ON fb.icon_id = im.icon_id
            WHERE fb.image_data IS NOT NULL AND
            """
            exact = select + " im.page_url = ?1 ORDER BY fb.width DESC LIMIT 1"
            sameSite = select + " im.page_url >= ?1 AND im.page_url < ?2 ORDER BY fb.width DESC LIMIT 1"
        case .firefox:
            // Width 65535 marks an SVG; prefer a bitmap when there is one.
            let select = """
            SELECT i.data FROM moz_pages_w_icons p
            JOIN moz_icons_to_pages ip ON ip.page_id = p.id
            JOIN moz_icons i ON i.id = ip.icon_id
            WHERE i.data IS NOT NULL AND
            """
            exact = select + " p.page_url = ?1 ORDER BY (i.width = 65535), i.width DESC LIMIT 1"
            sameSite = select + " p.page_url >= ?1 AND p.page_url < ?2 ORDER BY (i.width = 65535), i.width DESC LIMIT 1"
        }
        var exactStmt: OpaquePointer?
        var siteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, exact, -1, &exactStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sameSite, -1, &siteStmt, nil) == SQLITE_OK
        else { sqlite3_finalize(exactStmt); sqlite3_finalize(siteStmt); return [:] }
        defer { sqlite3_finalize(exactStmt); sqlite3_finalize(siteStmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func icon(_ stmt: OpaquePointer?, _ args: [String]) -> Data? {
            sqlite3_reset(stmt)
            for (i, arg) in args.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            return normalizedPNG(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
        }

        var found: [String: Data] = [:]
        for url in urls {
            if let png = icon(exactStmt, [url]) {
                found[url] = png
            } else if let parts = URLComponents(string: url),
                      let scheme = parts.scheme, let host = parts.host,
                      scheme == "http" || scheme == "https" {
                let origin = scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
                if let png = icon(siteStmt, [origin + "/", origin + "0"]) { found[url] = png }
            }
        }
        return found
    }

    /// Re-encode whatever the browser stored (PNG, ICO, SVG, …) as a 64px
    /// PNG, so rows decode one small, known format.
    private static func normalizedPNG(_ raw: Data) -> Data? {
        autoreleasepool {
            guard let image = NSImage(data: raw), image.isValid else { return nil }
            let px = 64
            var proposed = CGRect(x: 0, y: 0, width: px, height: px)
            guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                  let ctx = CGContext(
                    data: nil, width: px, height: px,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: px, height: px))
            guard let scaled = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, scaled, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return out as Data
        }
    }
}
