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
    ///
    /// `group` is the breadcrumb segment under "Window" — surfaces in the
    /// row subtitle as "Window > Halves · Terminal", same path-aware shape
    /// the Settings and Folders sources use.
    private struct Entry {
        let alias: String       // lowercase, what the user types
        let action: WindowAction
        let canonical: String   // shown as the row title ("Left Half")
        let group: String       // breadcrumb segment ("Halves", "Quadrants"…)
    }

    /// Hardcoded alias list. Add a line here when you notice yourself
    /// typing something that doesn't match. No runtime cost — entries are
    /// scanned linearly, ~80 entries is sub-millisecond.
    ///
    /// "Bare" single-word aliases like `left` / `right` / `top` / `max`
    /// were intentionally pruned for v0 — they exact-matched too easily and
    /// would suppress content rows under the command/content exclusivity
    /// rule (typing `max` would hide messages from a contact named Max).
    /// You still get fast disambiguation via the multi-word aliases.
    private static let entries: [Entry] = [
        // ─── Halves ───────────────────────────────────────────────────
        Entry(alias: "left half",       action: .leftHalf,   canonical: "Left Half",  group: "Halves"),
        Entry(alias: "snap left",       action: .leftHalf,   canonical: "Left Half",  group: "Halves"),
        Entry(alias: "half left",       action: .leftHalf,   canonical: "Left Half",  group: "Halves"),
        Entry(alias: "lh",              action: .leftHalf,   canonical: "Left Half",  group: "Halves"),

        Entry(alias: "right half",      action: .rightHalf,  canonical: "Right Half", group: "Halves"),
        Entry(alias: "snap right",      action: .rightHalf,  canonical: "Right Half", group: "Halves"),
        Entry(alias: "half right",      action: .rightHalf,  canonical: "Right Half", group: "Halves"),
        Entry(alias: "rh",              action: .rightHalf,  canonical: "Right Half", group: "Halves"),

        // ─── Quadrants ────────────────────────────────────────────────
        Entry(alias: "top left",        action: .topLeft,     canonical: "Top Left",     group: "Quadrants"),
        Entry(alias: "upper left",      action: .topLeft,     canonical: "Top Left",     group: "Quadrants"),
        Entry(alias: "tl",              action: .topLeft,     canonical: "Top Left",     group: "Quadrants"),

        Entry(alias: "top right",       action: .topRight,    canonical: "Top Right",    group: "Quadrants"),
        Entry(alias: "upper right",     action: .topRight,    canonical: "Top Right",    group: "Quadrants"),
        Entry(alias: "tr",              action: .topRight,    canonical: "Top Right",    group: "Quadrants"),

        Entry(alias: "bottom left",     action: .bottomLeft,  canonical: "Bottom Left",  group: "Quadrants"),
        Entry(alias: "lower left",      action: .bottomLeft,  canonical: "Bottom Left",  group: "Quadrants"),
        Entry(alias: "bl",              action: .bottomLeft,  canonical: "Bottom Left",  group: "Quadrants"),

        Entry(alias: "bottom right",    action: .bottomRight, canonical: "Bottom Right", group: "Quadrants"),
        Entry(alias: "lower right",     action: .bottomRight, canonical: "Bottom Right", group: "Quadrants"),
        Entry(alias: "br",              action: .bottomRight, canonical: "Bottom Right", group: "Quadrants"),

        // ─── Thirds ───────────────────────────────────────────────────
        Entry(alias: "left third",      action: .leftThird,   canonical: "Left Third",   group: "Thirds"),
        Entry(alias: "first third",     action: .leftThird,   canonical: "Left Third",   group: "Thirds"),
        Entry(alias: "third left",      action: .leftThird,   canonical: "Left Third",   group: "Thirds"),

        Entry(alias: "center third",    action: .centerThird, canonical: "Center Third", group: "Thirds"),
        Entry(alias: "middle third",    action: .centerThird, canonical: "Center Third", group: "Thirds"),
        Entry(alias: "third center",    action: .centerThird, canonical: "Center Third", group: "Thirds"),
        Entry(alias: "third middle",    action: .centerThird, canonical: "Center Third", group: "Thirds"),

        Entry(alias: "right third",     action: .rightThird,  canonical: "Right Third",  group: "Thirds"),
        Entry(alias: "last third",      action: .rightThird,  canonical: "Right Third",  group: "Thirds"),
        Entry(alias: "third right",     action: .rightThird,  canonical: "Right Third",  group: "Thirds"),

        // ─── Display ──────────────────────────────────────────────────
        Entry(alias: "maximize",         action: .maximize,        canonical: "Maximize",         group: "Display"),
        Entry(alias: "fullscreen",       action: .maximize,        canonical: "Maximize",         group: "Display"),
        Entry(alias: "fill screen",      action: .maximize,        canonical: "Maximize",         group: "Display"),

        Entry(alias: "minimize",         action: .minimize,        canonical: "Minimize",         group: "Display"),
        Entry(alias: "min",              action: .minimize,        canonical: "Minimize",         group: "Display"),
        Entry(alias: "hide to dock",     action: .minimize,        canonical: "Minimize",         group: "Display"),

        Entry(alias: "center window",    action: .center,          canonical: "Center Window",    group: "Display"),
        Entry(alias: "centre window",    action: .center,          canonical: "Center Window",    group: "Display"),

        Entry(alias: "next display",     action: .nextDisplay,     canonical: "Next Display",     group: "Display"),
        Entry(alias: "next monitor",     action: .nextDisplay,     canonical: "Next Display",     group: "Display"),
        Entry(alias: "next screen",      action: .nextDisplay,     canonical: "Next Display",     group: "Display"),
        Entry(alias: "other display",    action: .nextDisplay,     canonical: "Next Display",     group: "Display"),

        Entry(alias: "previous display", action: .previousDisplay, canonical: "Previous Display", group: "Display"),
        Entry(alias: "prev display",     action: .previousDisplay, canonical: "Previous Display", group: "Display"),
        Entry(alias: "previous monitor", action: .previousDisplay, canonical: "Previous Display", group: "Display"),
        Entry(alias: "previous screen",  action: .previousDisplay, canonical: "Previous Display", group: "Display"),
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

        // ─── Pass 1: prefix match (instant, primary path) ─────────────
        var seen: Set<WindowAction> = []
        var prefixHits: [Entry] = []
        for entry in Self.entries {
            guard entry.alias.hasPrefix(normalized) else { continue }
            guard !seen.contains(entry.action) else { continue }
            seen.insert(entry.action)
            prefixHits.append(entry)
        }
        if !prefixHits.isEmpty {
            return Self.render(
                entries: Array(prefixHits.prefix(8)),
                targetAppName: targetAppName,
                rankBase: 940
            )
        }

        // ─── Pass 2: fuzzy fallback (typo-tolerant) ────────────────────
        // Only runs when prefix returned zero, so worst case is bounded:
        // ~50 aliases × ~5 µs each = ~250 µs per keystroke when the
        // user has actually typo'd. Zero cost on the common path.
        let budget = FuzzyMatch.budget(for: normalized)
        guard budget > 0 else { return [] }
        seen.removeAll(keepingCapacity: true)
        var fuzzyHits: [(Entry, Int)] = []
        for entry in Self.entries {
            guard !seen.contains(entry.action) else { continue }
            if let dist = FuzzyMatch.levenshtein(
                normalized, entry.alias, budget: budget
            ) {
                seen.insert(entry.action)
                fuzzyHits.append((entry, dist))
            }
        }
        // Sort by ascending distance — closest typos first.
        fuzzyHits.sort { $0.1 < $1.1 }
        return Self.render(
            entries: fuzzyHits.prefix(8).map { $0.0 },
            targetAppName: targetAppName,
            // Fuzzy fallback ranks BELOW any prefix match (940) and below
            // file/folder exact-name matches from FileSearchService (~430).
            // A typo'd window action shouldn't beat a real exact-name file
            // hit; if the user genuinely meant the window action, more
            // typing will resolve via the prefix path.
            rankBase: 270,
            isFuzzy: true
        )
    }

    /// Render a deduped, ordered list of Entry values into the SearchResult
    /// shape both prefix and fuzzy paths produce. `rankBase` distinguishes
    /// prefix (940) from fuzzy (880) — they never appear in the same call,
    /// but the lower fuzzy band keeps the visual cue if anything else ever
    /// merges into the same list.
    private static func render(
        entries: [Entry],
        targetAppName: String?,
        rankBase: Int,
        isFuzzy: Bool = false
    ) -> [SearchResult] {
        entries.enumerated().map { idx, entry in
            let breadcrumb = "Window > \(entry.group)"
            let subtitle = targetAppName.map { "\(breadcrumb) · \($0)" } ?? breadcrumb
            return SearchResult(
                title: entry.canonical,
                subtitle: subtitle,
                source: .window,
                date: nil,
                badge: nil,
                openTarget: .windowAction(entry.action),
                rank: rankBase - idx,
                isFuzzyMatch: isFuzzy
            )
        }
    }

    /// True when the normalized query exactly matches one of our aliases.
    /// Used by the ViewModel's exclusivity rule — exact command match →
    /// hide content rows. Strict-equality only (not prefix) so partial
    /// typing keeps content visible until the user has committed to a
    /// command name.
    func hasExactMatch(query rawQuery: String) -> Bool {
        guard targetPID != nil else { return false }
        let normalized = Self.normalize(rawQuery)
        guard !normalized.isEmpty else { return false }
        return Self.entries.contains { $0.alias == normalized }
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

    // MARK: - Preview

    /// Returns the snap target as (destination screen, rect in NSScreen
    /// coords) so the overlay panel can be placed without an AX flip.
    /// Re-reads the focused window's frame on every call because the
    /// preview should track the actual current window's screen and size
    /// (for center / next-display, the rect depends on the live size).
    func previewRect(for action: WindowAction) -> (NSScreen, CGRect)? {
        guard let pid = targetPID, pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &winRef
        )
        guard copyStatus == .success, let win = winRef else { return nil }
        let window = win as! AXUIElement
        let currentRect = Self.readFrame(window) ?? .zero
        let currentScreen = Self.screenContaining(currentRect)

        switch action {
        case .minimize:
            // No snap target — the window is going to the Dock. Returning
            // nil tells the overlay controller to hide.
            return nil
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1 else { return nil }
            let ordered = screens.sorted {
                $0.visibleFrame.minX != $1.visibleFrame.minX
                    ? $0.visibleFrame.minX < $1.visibleFrame.minX
                    : $0.visibleFrame.minY < $1.visibleFrame.minY
            }
            guard let idx = ordered.firstIndex(of: currentScreen) else { return nil }
            let forward = (action == .nextDisplay)
            let nextIdx = forward
                ? (idx + 1) % ordered.count
                : (idx - 1 + ordered.count) % ordered.count
            let dest = ordered[nextIdx]
            let v = dest.visibleFrame
            let size = currentRect.size
            let nsRect = CGRect(
                x: v.minX + (v.width - size.width) / 2,
                y: v.minY + (v.height - size.height) / 2,
                width: size.width, height: size.height
            )
            return (dest, nsRect)

        case .center:
            let v = currentScreen.visibleFrame
            let size = currentRect.size
            let nsRect = CGRect(
                x: v.minX + (v.width - size.width) / 2,
                y: v.minY + (v.height - size.height) / 2,
                width: size.width, height: size.height
            )
            return (currentScreen, nsRect)

        default:
            let axRect = Self.rect(for: action, on: currentScreen)
            return (currentScreen, Self.axToNS(axRect))
        }
    }

    /// AX → NSScreen coord conversion. Both systems use the primary
    /// display as their origin; AX is top-left, NSScreen is bottom-left.
    /// Widths and heights are identical; only y flips.
    private static func axToNS(_ axRect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? axRect.maxY
        return CGRect(
            x: axRect.minX,
            y: primary - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
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
        case .minimize:
            // No frame change — just toggle the AX minimized attribute.
            // Snap-overlay preview already hid for this action because
            // previewRect returns nil.
            return setMinimized(window: window, true)
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

    /// Toggle kAXMinimizedAttribute on the focused window. Returns the
    /// AX status — false if the attribute is unsupported (rare; most
    /// app windows expose it).
    private func setMinimized(window: AXUIElement, _ minimized: Bool) -> Bool {
        let value = minimized as CFBoolean
        let status = AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, value
        )
        return status == .success
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
        case .topLeft:         return CGRect(x: x,           y: y,           width: w/2,    height: h/2)
        case .topRight:        return CGRect(x: x + w/2,     y: y,           width: w/2,    height: h/2)
        case .bottomLeft:      return CGRect(x: x,           y: y + h/2,     width: w/2,    height: h/2)
        case .bottomRight:     return CGRect(x: x + w/2,     y: y + h/2,     width: w/2,    height: h/2)
        case .leftThird:       return CGRect(x: x,           y: y,           width: w/3,    height: h)
        case .centerThird:     return CGRect(x: x + w/3,     y: y,           width: w/3,    height: h)
        case .rightThird:      return CGRect(x: x + 2*w/3,   y: y,           width: w/3,    height: h)
        case .maximize:        return CGRect(x: x,           y: y,           width: w,      height: h)
        case .minimize, .center, .nextDisplay, .previousDisplay:
            // Handled by their own code paths in execute() — these don't
            // have a static rect (minimize hides the window; center +
            // displays preserve the current size).
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
