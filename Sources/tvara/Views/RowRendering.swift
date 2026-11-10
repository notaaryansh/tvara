import AppKit
import SwiftUI

/// Shared helpers for the result-row views (SearchResultRow,
/// CompactMessageRow, PhotoCollectionRow). Row bodies re-evaluate on every
/// keystroke and every ↑/↓ press, so anything expensive they do per render
/// (decoding image bytes, allocating formatters) lives here, done once.
enum RowRendering {

    // MARK: - Decoded image cache

    /// Decoded `NSImage`s keyed by their source bytes. `NSImage(data:)` on a
    /// thumbnail/avatar PNG or JPEG costs a full decode, and rows used to do
    /// it inside `body` — so moving the selection re-decoded every visible
    /// row. NSData equality is a byte compare, which is far cheaper than a
    /// decode, and NSCache evicts under memory pressure on its own.
    private static let imageCache: NSCache<NSData, NSImage> = {
        let c = NSCache<NSData, NSImage>()
        c.countLimit = 400
        return c
    }()

    static func image(from data: Data?) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = data as NSData
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - Relative dates

    /// One formatter for every row instead of one allocation per render.
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @MainActor static func relativeString(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Query highlighting

    /// Subtitle with an optional bold sender prefix and every
    /// case-insensitive occurrence of `query` bolded.
    ///
    /// Ranges are computed in UTF-16 (NSString) space on the ORIGINAL
    /// string. The old per-row copies searched a `lowercased()` copy and
    /// offset by `prefix.count` (Characters), which mis-placed the bold
    /// span whenever the sender name had emoji / combining marks or the
    /// subtitle contained characters whose lowercase form changes length.
    static func highlightedSubtitle(
        _ subtitle: String,
        sender: String?,
        query: String
    ) -> AttributedString {
        let base = NSMutableAttributedString()
        var bodyOffset = 0
        if let sender, !sender.isEmpty {
            let prefix = "\(sender)  "
            base.append(NSAttributedString(string: prefix, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]))
            bodyOffset = (prefix as NSString).length
        }
        base.append(NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return AttributedString(base) }

        let hay = subtitle as NSString
        var searchRange = NSRange(location: 0, length: hay.length)
        while searchRange.length > 0 {
            let found = hay.range(of: q, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            base.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ], range: NSRange(location: found.location + bodyOffset, length: found.length))
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: hay.length - next)
        }
        return AttributedString(base)
    }

    // MARK: - Platform badge icons

    /// Icon for a platform badge, resolved by bundle ID first so apps
    /// installed outside `/Applications` (e.g. `~/Applications`, Setapp)
    /// still get their real icon instead of the generic blank-app one.
    static func appIcon(bundleID: String, fallbackPath: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: fallbackPath)
    }

    /// Deterministic per-name tint for placeholder avatars.
    static func placeholderColor(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return placeholderPalette[abs(hash) % placeholderPalette.count]
    }

    private static let placeholderPalette: [Color] = [
        Color(red: 0.45, green: 0.55, blue: 0.85),
        Color(red: 0.85, green: 0.45, blue: 0.55),
        Color(red: 0.45, green: 0.80, blue: 0.65),
        Color(red: 0.85, green: 0.65, blue: 0.40),
        Color(red: 0.65, green: 0.50, blue: 0.85),
        Color(red: 0.50, green: 0.70, blue: 0.85)
    ]

    static func initial(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}
