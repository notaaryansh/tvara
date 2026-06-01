import AppKit
import ApplicationServices
import Foundation

/// Window-management commands surfaced as launcher rows. Match is a flat
/// loop over a hardcoded alias table — no scoring, no fuzziness. Execute
/// drives the macOS Accessibility API against the previously-frontmost
/// app's focused window (PID captured by SearchWindowController before
/// the panel steals focus).
final class WindowManagerService {

    /// PID of the app that was frontmost when the panel opened. Set by
    /// SearchWindowController; nil when the launcher was opened with no
    /// targetable app (status-bar icon click with no prior focus, etc.).
    var targetPID: pid_t?
    /// Friendly name shown in the row subtitle so the user sees which app
    /// the command will hit.
    var targetAppName: String?

    /// One row entry per (alias → action). Multiple aliases per action are
    /// declared as separate rows so a single typed prefix can hit the same
    /// preset through any of its phrasings. Declaration order is the
    /// permanent display priority — first matching action wins ties.
    private struct Entry {
        let alias: String       // lowercase, what the user types
        let action: WindowAction
        let canonical: String   // shown as the row title ("Left Half")
    }

    /// Hardcoded alias list. Add a line here when you notice yourself
    /// typing something that doesn't match. No runtime cost — entries are
    /// scanned linearly, ~200 entries is sub-millisecond.
    private static let entries: [Entry] = [
        // ─── Halves ───────────────────────────────────────────────────
        Entry(alias: "left half",       action: .leftHalf,   canonical: "Left Half"),
        Entry(alias: "left",            action: .leftHalf,   canonical: "Left Half"),
        Entry(alias: "snap left",       action: .leftHalf,   canonical: "Left Half"),
        Entry(alias: "half left",       action: .leftHalf,   canonical: "Left Half"),
        Entry(alias: "lh",              action: .leftHalf,   canonical: "Left Half"),

        Entry(alias: "right half",      action: .rightHalf,  canonical: "Right Half"),
        Entry(alias: "right",           action: .rightHalf,  canonical: "Right Half"),
        Entry(alias: "snap right",      action: .rightHalf,  canonical: "Right Half"),
        Entry(alias: "half right",      action: .rightHalf,  canonical: "Right Half"),
        Entry(alias: "rh",              action: .rightHalf,  canonical: "Right Half"),

        Entry(alias: "top half",        action: .topHalf,    canonical: "Top Half"),
        Entry(alias: "top",             action: .topHalf,    canonical: "Top Half"),
        Entry(alias: "upper half",      action: .topHalf,    canonical: "Top Half"),
        Entry(alias: "upper",           action: .topHalf,    canonical: "Top Half"),
        Entry(alias: "th",              action: .topHalf,    canonical: "Top Half"),

        Entry(alias: "bottom half",     action: .bottomHalf, canonical: "Bottom Half"),
        Entry(alias: "bottom",          action: .bottomHalf, canonical: "Bottom Half"),
        Entry(alias: "lower half",      action: .bottomHalf, canonical: "Bottom Half"),
        Entry(alias: "lower",           action: .bottomHalf, canonical: "Bottom Half"),
        Entry(alias: "bh",              action: .bottomHalf, canonical: "Bottom Half"),

        // ─── Quarters ─────────────────────────────────────────────────
        Entry(alias: "top left",        action: .topLeft,    canonical: "Top Left"),
        Entry(alias: "upper left",      action: .topLeft,    canonical: "Top Left"),
        Entry(alias: "tl",              action: .topLeft,    canonical: "Top Left"),

        Entry(alias: "top right",       action: .topRight,   canonical: "Top Right"),
        Entry(alias: "upper right",     action: .topRight,   canonical: "Top Right"),
        Entry(alias: "tr",              action: .topRight,   canonical: "Top Right"),

        Entry(alias: "bottom left",     action: .bottomLeft, canonical: "Bottom Left"),
        Entry(alias: "lower left",      action: .bottomLeft, canonical: "Bottom Left"),
        Entry(alias: "bl",              action: .bottomLeft, canonical: "Bottom Left"),

        Entry(alias: "bottom right",    action: .bottomRight, canonical: "Bottom Right"),
        Entry(alias: "lower right",     action: .bottomRight, canonical: "Bottom Right"),
        Entry(alias: "br",              action: .bottomRight, canonical: "Bottom Right"),

        // ─── Thirds ───────────────────────────────────────────────────
        Entry(alias: "left third",      action: .leftThird,   canonical: "Left Third"),
        Entry(alias: "first third",     action: .leftThird,   canonical: "Left Third"),
        Entry(alias: "third left",      action: .leftThird,   canonical: "Left Third"),

        Entry(alias: "center third",    action: .centerThird, canonical: "Center Third"),
        Entry(alias: "middle third",    action: .centerThird, canonical: "Center Third"),
        Entry(alias: "center",          action: .centerThird, canonical: "Center Third"),

        Entry(alias: "right third",     action: .rightThird,  canonical: "Right Third"),
        Entry(alias: "last third",      action: .rightThird,  canonical: "Right Third"),
        Entry(alias: "third right",     action: .rightThird,  canonical: "Right Third"),

        // ─── Two-thirds ───────────────────────────────────────────────
        Entry(alias: "left two thirds",  action: .leftTwoThirds,  canonical: "Left Two-Thirds"),
        Entry(alias: "left 2/3",         action: .leftTwoThirds,  canonical: "Left Two-Thirds"),
        Entry(alias: "two thirds left",  action: .leftTwoThirds,  canonical: "Left Two-Thirds"),

        Entry(alias: "right two thirds", action: .rightTwoThirds, canonical: "Right Two-Thirds"),
        Entry(alias: "right 2/3",        action: .rightTwoThirds, canonical: "Right Two-Thirds"),
        Entry(alias: "two thirds right", action: .rightTwoThirds, canonical: "Right Two-Thirds"),

        // ─── Whole-screen ─────────────────────────────────────────────
        Entry(alias: "maximize",         action: .maximize,       canonical: "Maximize"),
        Entry(alias: "max",              action: .maximize,       canonical: "Maximize"),
        Entry(alias: "full",             action: .maximize,       canonical: "Maximize"),
        Entry(alias: "fullscreen",       action: .maximize,       canonical: "Maximize"),
        Entry(alias: "fill",             action: .maximize,       canonical: "Maximize"),
        Entry(alias: "whole",            action: .maximize,       canonical: "Maximize"),

        Entry(alias: "almost maximize",  action: .almostMaximize, canonical: "Almost Maximize"),
        Entry(alias: "near max",         action: .almostMaximize, canonical: "Almost Maximize"),
        Entry(alias: "near maximize",    action: .almostMaximize, canonical: "Almost Maximize"),

        Entry(alias: "center window",    action: .center,         canonical: "Center Window"),
        Entry(alias: "centre",           action: .center,         canonical: "Center Window"),
        Entry(alias: "middle",           action: .center,         canonical: "Center Window"),

        // ─── Multi-display ────────────────────────────────────────────
        Entry(alias: "next display",     action: .nextDisplay,     canonical: "Next Display"),
        Entry(alias: "next monitor",     action: .nextDisplay,     canonical: "Next Display"),
        Entry(alias: "next screen",      action: .nextDisplay,     canonical: "Next Display"),
        Entry(alias: "other display",    action: .nextDisplay,     canonical: "Next Display"),
        Entry(alias: "other monitor",    action: .nextDisplay,     canonical: "Next Display"),
        Entry(alias: "other screen",     action: .nextDisplay,     canonical: "Next Display"),

        Entry(alias: "previous display", action: .previousDisplay, canonical: "Previous Display"),
        Entry(alias: "prev display",     action: .previousDisplay, canonical: "Previous Display"),
        Entry(alias: "previous monitor", action: .previousDisplay, canonical: "Previous Display"),
        Entry(alias: "previous screen",  action: .previousDisplay, canonical: "Previous Display"),
    ]

    /// Stopwords stripped only from the FRONT of the query so phrases like
    /// "send this to the left" still hit "left". Tail filler is left alone
    /// — typing "left half please" should still match because "left half"
    /// is a prefix of the alias.
    private static let leadingStopwords: Set<String> = [
        "move", "snap", "put", "send", "make", "go", "set", "drop",
        "to", "the", "a", "an", "this", "it", "please", "pls", "just"
    ]

    /// Synonyms applied to each token after stopword stripping. Keeps the
    /// alias table from having to spell out every wording — "upper" maps
    /// to "top", "monitor" → "display", etc. Substitution is one-shot per
    /// token, no recursion.
    private static let synonyms: [String: String] = [
        "upper":   "top",
        "lower":   "bottom",
        "monitor": "display",
        "screen":  "display"
    ]

    // MARK: - Matching

    /// Synchronous, no allocation beyond the result array. Safe to call on
    /// every keystroke from the main actor.
    func match(query rawQuery: String) -> [SearchResult] {
        guard targetPID != nil else { return [] }
        let normalized = Self.normalize(rawQuery)
        guard !normalized.isEmpty else { return [] }

        // One pass: collect first entry per WindowAction whose alias
        // starts with the normalized query. Declaration order is preserved.
        var seen: Set<WindowAction> = []
        var hits: [Entry] = []
        for entry in Self.entries {
            guard entry.alias.hasPrefix(normalized) else { continue }
            guard !seen.contains(entry.action) else { continue }
            seen.insert(entry.action)
            hits.append(entry)
        }
        // Cap at 8 so a one-letter query doesn't dump 20 rows into the list.
        let capped = hits.prefix(8)

        let appLabel = targetAppName.map { "Window · \($0)" } ?? "Window"
        // Window rows want to outrank generic apps/files but sit below the
        // "open chat" contact-card pins at rank 1000. 940-{n} keeps them
        // grouped + ordered by declaration.
        return capped.enumerated().map { idx, entry in
            SearchResult(
                title: entry.canonical,
                subtitle: appLabel,
                source: .window,
                date: nil,
                badge: nil,
                openTarget: .windowAction(entry.action),
                rank: 940 - idx
            )
        }
    }

    /// Lowercase, trim, drop leading stopwords, apply synonyms, rejoin.
    /// O(n) on the token count — typically 1-3 tokens, sub-microsecond.
    private static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return "" }
        var tokens = lowered.split(separator: " ").map(String.init)
        // Strip leading stopwords (not tail — typing "left half please"
        // still has "left half" as a valid prefix of the alias).
        while let first = tokens.first, leadingStopwords.contains(first) {
            tokens.removeFirst()
        }
        // Apply per-token synonyms.
        tokens = tokens.map { synonyms[$0] ?? $0 }
        return tokens.joined(separator: " ")
    }

    // MARK: - Execution

    /// Run the action against the captured target PID's focused window.
    /// All work is synchronous AX calls — fast enough to do on the main
    /// actor right before hiding the panel.
    @discardableResult
    func execute(_ action: WindowAction) -> Bool {
        guard let pid = targetPID, pid != getpid() else { return false }
        let app = AXUIElementCreateApplication(pid)

        var winRef: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &winRef
        )
        guard copyStatus == .success, let win = winRef else { return false }
        // CFTypeRef → AXUIElement; AXUIElement is a CF type so this cast is safe.
        let window = win as! AXUIElement

        // Read current position + size so we can (a) figure out which
        // screen the window is on and (b) preserve size on actions that
        // only move (center, next/previous display).
        let currentRect = Self.readFrame(window) ?? .zero
        let currentScreen = Self.screenContaining(currentRect)

        switch action {
        case .nextDisplay, .previousDisplay:
            return moveToAdjacentDisplay(
                window: window,
                from: currentScreen,
                size: currentRect.size,
                forward: action == .nextDisplay
            )
        case .center:
            return centerOnScreen(
                window: window,
                screen: currentScreen,
                size: currentRect.size
            )
        default:
            let rect = Self.rect(for: action, on: currentScreen)
            return setFrame(window: window, rect: rect)
        }
    }

    /// Set position + size in two separate AX calls. Some apps refuse to
    /// resize past their internal min/max — we don't fight that, the call
    /// just no-ops on those dimensions.
    private func setFrame(window: AXUIElement, rect: CGRect) -> Bool {
        var pos = rect.origin
        var size = rect.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size)
        else { return false }
        // Set size BEFORE position — if we set position first and the new
        // position would push the (still-old) size off the screen edge,
        // some apps clamp the position back, leaving the window in the
        // wrong spot.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        return true
    }

    private func centerOnScreen(
        window: AXUIElement, screen: NSScreen, size: CGSize
    ) -> Bool {
        let v = screen.visibleFrame
        let topY = Self.axTopY(for: v)
        let x = v.minX + (v.width - size.width) / 2
        let y = topY + (v.height - size.height) / 2
        return setFrame(
            window: window,
            rect: CGRect(x: x, y: y, width: size.width, height: size.height)
        )
    }

    private func moveToAdjacentDisplay(
        window: AXUIElement,
        from currentScreen: NSScreen,
        size: CGSize,
        forward: Bool
    ) -> Bool {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return false }
        // Stable order: sort by visibleFrame minX so "next" means "to the
        // right", "previous" means "to the left". Multi-row monitor setups
        // tie-break by minY (lower = earlier).
        let ordered = screens.sorted {
            $0.visibleFrame.minX != $1.visibleFrame.minX
                ? $0.visibleFrame.minX < $1.visibleFrame.minX
                : $0.visibleFrame.minY < $1.visibleFrame.minY
        }
        guard let idx = ordered.firstIndex(of: currentScreen) else { return false }
        let nextIdx = forward
            ? (idx + 1) % ordered.count
            : (idx - 1 + ordered.count) % ordered.count
        return centerOnScreen(window: window, screen: ordered[nextIdx], size: size)
    }

    // MARK: - Geometry helpers

    /// AX uses top-left origin relative to the PRIMARY display. NSScreen
    /// gives bottom-left origin relative to the primary display. This is
    /// the only place we do the flip; everything downstream uses AX
    /// coords.
    private static func axTopY(for nsRect: CGRect) -> CGFloat {
        let primary = NSScreen.screens.first?.frame.height ?? nsRect.maxY
        return primary - nsRect.maxY
    }

    /// Resolve a preset action to an absolute rect (AX coords) inside the
    /// given screen's visibleFrame. Half/quarter/third positions are
    /// computed each call — cheap, no caching needed.
    private static func rect(for action: WindowAction, on screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        let topY = axTopY(for: v)
        let w = v.width, h = v.height
        let x = v.minX, y = topY
        switch action {
        case .leftHalf:        return CGRect(x: x,           y: y,           width: w/2,    height: h)
        case .rightHalf:       return CGRect(x: x + w/2,     y: y,           width: w/2,    height: h)
        case .topHalf:         return CGRect(x: x,           y: y,           width: w,      height: h/2)
        case .bottomHalf:      return CGRect(x: x,           y: y + h/2,     width: w,      height: h/2)
        case .topLeft:         return CGRect(x: x,           y: y,           width: w/2,    height: h/2)
        case .topRight:        return CGRect(x: x + w/2,     y: y,           width: w/2,    height: h/2)
        case .bottomLeft:      return CGRect(x: x,           y: y + h/2,     width: w/2,    height: h/2)
        case .bottomRight:     return CGRect(x: x + w/2,     y: y + h/2,     width: w/2,    height: h/2)
        case .leftThird:       return CGRect(x: x,           y: y,           width: w/3,    height: h)
        case .centerThird:     return CGRect(x: x + w/3,     y: y,           width: w/3,    height: h)
        case .rightThird:      return CGRect(x: x + 2*w/3,   y: y,           width: w/3,    height: h)
        case .leftTwoThirds:   return CGRect(x: x,           y: y,           width: 2*w/3,  height: h)
        case .rightTwoThirds:  return CGRect(x: x + w/3,     y: y,           width: 2*w/3,  height: h)
        case .maximize:        return CGRect(x: x,           y: y,           width: w,      height: h)
        case .almostMaximize:
            let m: CGFloat = 40
            return CGRect(x: x + m, y: y + m, width: w - 2*m, height: h - 2*m)
        case .center, .nextDisplay, .previousDisplay:
            // Handled by their own code paths in execute() — these need
            // the current window size to round-trip.
            return v
        }
    }

    /// Read the focused window's current frame in AX coords. Returns nil
    /// if either attribute is missing (some windows expose neither).
    private static func readFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let pStatus = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        let sStatus = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard pStatus == .success, sStatus == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Find which NSScreen contains the center of the given AX rect.
    /// Falls back to the primary screen when the rect's center sits in a
    /// dead zone between displays.
    private static func screenContaining(_ axRect: CGRect) -> NSScreen {
        let primary = NSScreen.screens.first ?? NSScreen.main!
        // Convert AX center → NSScreen coords.
        let axCenter = CGPoint(x: axRect.midX, y: axRect.midY)
        let nsCenter = CGPoint(
            x: axCenter.x,
            y: primary.frame.height - axCenter.y
        )
        return NSScreen.screens.first(where: { $0.frame.contains(nsCenter) })
            ?? primary
    }
}
