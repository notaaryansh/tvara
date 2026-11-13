import AppKit
import ApplicationServices
import Foundation

/// One open tab in a running browser, as captured when the panel opened.
struct BrowserTab: Hashable {
    let bundleID: String
    let pid: pid_t
    let browserName: String
    /// AppleScript window id (Chromium family, Safari). 0 for browsers read
    /// through Accessibility, which address windows by position instead.
    let windowID: Int
    /// Position of the window in the browser's window list, 0-based.
    let windowIndex: Int
    /// Position of the tab in its window, 1-based.
    let tabIndex: Int
    let title: String
    /// Empty when it couldn't be found (a Firefox tab opened seconds ago).
    var url: String
    /// Set on the copy handed to a result row: its icon is the page's
    /// favicon rather than the browser's app icon.
    var hasFavicon = false
}

/// Open tabs of every running browser, searchable by title and switchable
/// from the launcher.
///
/// Two ways in, because no single one covers every browser:
///  - Chromium family, Safari and Arc expose their tabs to AppleScript.
///    That gives titles and URLs for every window on every Space, behind
///    the per-browser Automation prompt.
///  - Firefox has no scripting support at all, so its tab strip is read
///    through the Accessibility tree (titles only), which needs the
///    Accessibility grant the window commands already use.
///
/// The tab list is read once per panel open, off the main thread, and
/// matching is a plain in-memory scan, so typing never waits on a browser.
@MainActor
final class BrowserTabsService {

    private enum Kind { case chromium, safari, arc, firefox }

    private static let browsers: [String: Kind] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "com.apple.Safari": .safari,
        "company.thebrowser.Browser": .arc,
        "org.mozilla.firefox": .firefox,
        "org.mozilla.firefoxdeveloperedition": .firefox,
        "org.mozilla.nightly": .firefox,
        "app.zen-browser.zen": .firefox,
    ]

    /// Called on the main actor whenever a browser's tab list lands, so the
    /// view model can re-run the current query against it.
    var onUpdate: (() -> Void)?

    private var tabsByBrowser: [String: [BrowserTab]] = [:]
    private var iconByBrowser: [String: Data] = [:]
    /// Page URL → favicon PNG, for the tabs currently known.
    private var faviconByURL: [String: Data] = [:]
    private nonisolated let faviconStore = TabFaviconStore()
    private var frontmostBundleID: String?
    private var refreshInFlight = false

    /// AppleScript and AX calls run here: off the main thread, and one at a
    /// time because NSAppleScript is not safe to run concurrently.
    private static let queue = DispatchQueue(label: "tvara.browser-tabs", qos: .userInitiated)

    // MARK: - Refresh

    /// Re-read the open tabs of every running browser. Called when the
    /// panel opens, with the app that was frontmost before it did, so that
    /// browser's tabs rank on top.
    func refresh(frontmostBundleID: String?) {
        self.frontmostBundleID = frontmostBundleID
        // A previous read can still be parked on a browser's Automation
        // prompt; don't stack another behind it.
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let known = Self.browsers
        let haveIcons = Set(iconByBrowser.keys)
        let faviconStore = self.faviconStore
        Self.queue.async { [weak self] in
            var running: [(bundleID: String, kind: Kind, app: NSRunningApplication)] = []
            for (bundleID, kind) in known {
                if let app = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first {
                    running.append((bundleID, kind, app))
                }
            }
            // Accessibility browsers first: they never prompt, so they
            // can't end up waiting behind another browser's Automation
            // prompt the first time this runs.
            running.sort { ($0.kind == .firefox ? 0 : 1) < ($1.kind == .firefox ? 0 : 1) }
            let runningIDs = Set(running.map(\.bundleID))
            Self.debug("refresh: running=\(running.map(\.bundleID)) axTrusted=\(AXIsProcessTrusted())")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Drop browsers that have quit since the last open.
                    let stale = self.tabsByBrowser.keys.filter { !runningIDs.contains($0) }
                    guard !stale.isEmpty else { return }
                    for id in stale { self.tabsByBrowser[id] = nil }
                    self.onUpdate?()
                }
            }

            func read(_ entry: (bundleID: String, kind: Kind, app: NSRunningApplication)) -> [BrowserTab] {
                let name = entry.app.localizedName ?? "Browser"
                let pid = entry.app.processIdentifier
                switch entry.kind {
                case .chromium, .safari, .arc:
                    return Self.scriptedTabs(
                        bundleID: entry.bundleID, kind: entry.kind, pid: pid, name: name)
                case .firefox:
                    // The accessibility tree has titles only; the session
                    // file supplies each tab's address.
                    var tabs = Self.accessibilityTabs(
                        bundleID: entry.bundleID, pid: pid, name: name)
                    guard !tabs.isEmpty else { return tabs }
                    let urlByTitle = faviconStore.firefoxURLsByTitle(bundleID: entry.bundleID)
                    for i in tabs.indices { tabs[i].url = urlByTitle[tabs[i].title] ?? "" }
                    return tabs
                }
            }
            func deliver(_ bundleID: String, _ tabs: [BrowserTab], icon: Data?) {
                let favicons = faviconStore.favicons(bundleID: bundleID, urls: tabs.map(\.url))
                Self.debug("\(bundleID): \(tabs.count) tabs, "
                           + "\(tabs.filter { !$0.url.isEmpty }.count) with url, "
                           + "\(tabs.filter { favicons[$0.url] != nil }.count) with favicon")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let icon { self.iconByBrowser[bundleID] = icon }
                        var changed = false
                        for (url, png) in favicons where self.faviconByURL[url] != png {
                            self.faviconByURL[url] = png
                            changed = true
                        }
                        if self.tabsByBrowser[bundleID] != tabs {
                            self.tabsByBrowser[bundleID] = tabs
                            changed = true
                        }
                        if changed { self.onUpdate?() }
                    }
                }
            }

            var asleep: [(bundleID: String, kind: Kind, app: NSRunningApplication)] = []
            for entry in running {
                let tabs = read(entry)
                var icon: Data?
                if !haveIcons.contains(entry.bundleID),
                   let path = entry.app.bundleURL?.path {
                    icon = encodeAppIconPNG(path: path)
                }
                if tabs.isEmpty, entry.kind == .firefox { asleep.append(entry) }
                deliver(entry.bundleID, tabs, icon: icon)
            }
            // Firefox builds its accessibility tree only once something
            // asks for it, so the first read after it launches comes back
            // empty. That read is what wakes it; ask again shortly after.
            if !asleep.isEmpty {
                Thread.sleep(forTimeInterval: 0.7)
                for entry in asleep {
                    let tabs = read(entry)
                    if !tabs.isEmpty { deliver(entry.bundleID, tabs, icon: nil) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshInFlight = false }
            }
        }
    }

    /// `tvara -dumpTabs YES` appends what each refresh found (counts only,
    /// never titles) to ~/Library/Logs/tvara/tabs.log.
    private nonisolated static func debug(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "dumpTabs") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/tvara", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tabs.log")
        let data = Data("\(Date()) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Match

    func match(query rawQuery: String) -> [SearchResult] {
        let q = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }

        var scored: [(tab: BrowserTab, rank: Int)] = []
        for (bundleID, tabs) in tabsByBrowser {
            let isFrontmost = bundleID == frontmostBundleID
            for tab in tabs {
                if let rank = Self.rank(tab: tab, query: q, browserIsFrontmost: isFrontmost) {
                    scored.append((tab, rank))
                }
            }
        }
        scored.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.tab.windowIndex != $1.tab.windowIndex {
                return $0.tab.windowIndex < $1.tab.windowIndex
            }
            return $0.tab.tabIndex < $1.tab.tabIndex
        }
        return scored.prefix(8).map { tab, rank in
            var tab = tab
            let favicon = faviconByURL[tab.url]
            tab.hasFavicon = favicon != nil
            return SearchResult(
                title: tab.title.isEmpty ? tab.url : tab.title,
                subtitle: Self.subtitle(for: tab),
                source: .browserTab,
                date: nil,
                badge: nil,
                openTarget: .browserTab(tab),
                rank: rank,
                iconData: favicon ?? iconByBrowser[tab.bundleID]
            )
        }
    }

    /// Rank for one tab against a lowercased query, or nil when it doesn't
    /// match. Tabs of the browser the user was just in sit above ordinary
    /// app matches (they opened the launcher from that browser) but still
    /// below an exact app name; tabs of other browsers sit just under the
    /// equivalent app tier.
    nonisolated static func rank(tab: BrowserTab, query q: String, browserIsFrontmost: Bool) -> Int? {
        let title = tab.title.lowercased()
        let tier: Int
        if title.hasPrefix(q) {
            tier = 3
        } else if wordPrefix(title, q) {
            tier = 2
        } else if title.contains(q) {
            tier = 1
        } else if tab.url.lowercased().contains(q) {
            tier = 0
        } else {
            return nil
        }
        let frontmost = [1150, 1250, 1350, 1450]
        let background = [190, 210, 360, 480]
        return (browserIsFrontmost ? frontmost : background)[tier]
    }

    /// True when any word in `text` starts with `q`.
    private nonisolated static func wordPrefix(_ text: String, _ q: String) -> Bool {
        var atWordStart = true
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isLetter || ch.isNumber {
                if atWordStart, text[idx...].hasPrefix(q) { return true }
                atWordStart = false
            } else {
                atWordStart = true
            }
            idx = text.index(after: idx)
        }
        return false
    }

    private nonisolated static func subtitle(for tab: BrowserTab) -> String {
        guard let host = URL(string: tab.url)?.host, !host.isEmpty else {
            return "\(tab.browserName) tab"
        }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "\(tab.browserName) tab · \(trimmed)"
    }

    // MARK: - Switch

    /// Bring the tab to the front: select it, raise its window, activate
    /// the browser. Runs off the main thread; the panel is already gone.
    func activate(_ tab: BrowserTab) {
        guard let kind = Self.browsers[tab.bundleID] else { return }
        Self.queue.async {
            switch kind {
            case .chromium, .safari, .arc:
                Self.scriptedActivate(tab, kind: kind)
            case .firefox:
                Self.accessibilityActivate(tab)
            }
            NSRunningApplication(processIdentifier: tab.pid)?.activate(options: [])
        }
    }

    // MARK: - AppleScript browsers

    private nonisolated static func scriptedTabs(
        bundleID: String, kind: Kind, pid: pid_t, name: String
    ) -> [BrowserTab] {
        // One Apple event per property per window, not per tab: asking for
        // `title of tabs of w` returns the whole list in a single round trip.
        let titleProperty = kind == .safari ? "name" : "title"
        let source = """
        tell application id "\(bundleID)"
            set out to {}
            repeat with w in windows
                try
                    set end of out to {id of w, \(titleProperty) of tabs of w, URL of tabs of w}
                end try
            end repeat
            return out
        end tell
        """
        guard let result = run(source, label: "list \(bundleID)") else { return [] }

        var tabs: [BrowserTab] = []
        guard result.numberOfItems > 0 else { return [] }
        for w in 1...result.numberOfItems {
            guard let window = result.atIndex(w), window.numberOfItems == 3,
                  let titles = window.atIndex(2), let urls = window.atIndex(3)
            else { continue }
            let windowID = Int(window.atIndex(1)?.int32Value ?? 0)
            guard titles.numberOfItems > 0 else { continue }
            for t in 1...titles.numberOfItems {
                let title = titles.atIndex(t)?.stringValue ?? ""
                let url = t <= urls.numberOfItems ? (urls.atIndex(t)?.stringValue ?? "") : ""
                guard !title.isEmpty || !url.isEmpty else { continue }
                tabs.append(BrowserTab(
                    bundleID: bundleID, pid: pid, browserName: name,
                    windowID: windowID, windowIndex: w - 1, tabIndex: t,
                    title: title, url: url
                ))
            }
        }
        return tabs
    }

    private nonisolated static func scriptedActivate(_ tab: BrowserTab, kind: Kind) {
        let select: String
        switch kind {
        case .safari:
            select = "set current tab of w to tab \(tab.tabIndex) of w"
        case .arc:
            select = "tell tab \(tab.tabIndex) of w to select"
        case .chromium, .firefox:
            select = "set active tab index of w to \(tab.tabIndex)"
        }
        let source = """
        tell application id "\(tab.bundleID)"
            set w to first window whose id is \(tab.windowID)
            \(select)
            set index of w to 1
        end tell
        """
        _ = run(source, label: "activate \(tab.bundleID)")
    }

    private nonisolated static func run(_ source: String, label: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 = the user declined the Automation prompt for this
            // browser. Nothing to do but show no tabs for it.
            NSLog("[tabs] %@ failed: %@", label,
                  (error[NSAppleScript.errorMessage] as? String) ?? "\(error)")
            return nil
        }
        return result
    }

    // MARK: - Accessibility browsers (Firefox)

    private nonisolated static func accessibilityTabs(
        bundleID: String, pid: pid_t, name: String
    ) -> [BrowserTab] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)

        var tabs: [BrowserTab] = []
        for (w, window) in axChildren(app, kAXWindowsAttribute).enumerated() {
            for (t, button) in tabButtons(in: window).enumerated() {
                let title = axString(button, kAXTitleAttribute)
                guard !title.isEmpty else { continue }
                tabs.append(BrowserTab(
                    bundleID: bundleID, pid: pid, browserName: name,
                    windowID: 0, windowIndex: w, tabIndex: t + 1,
                    title: title, url: ""
                ))
            }
        }
        return tabs
    }

    private nonisolated static func accessibilityActivate(_ tab: BrowserTab) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(tab.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        let windows = axChildren(app, kAXWindowsAttribute)

        // The tab is most likely still where it was a few seconds ago; if
        // the strip changed since, fall back to the first tab with that title.
        func press(_ window: AXUIElement, _ button: AXUIElement) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if windows.indices.contains(tab.windowIndex) {
            let window = windows[tab.windowIndex]
            let buttons = tabButtons(in: window)
            if buttons.indices.contains(tab.tabIndex - 1),
               axString(buttons[tab.tabIndex - 1], kAXTitleAttribute) == tab.title {
                press(window, buttons[tab.tabIndex - 1])
                return
            }
        }
        for window in windows {
            for button in tabButtons(in: window)
            where axString(button, kAXTitleAttribute) == tab.title {
                press(window, button)
                return
            }
        }
    }

    /// The tab buttons of a browser window: the radio buttons of the first
    /// tab group found near the top of the tree. Page content is never
    /// entered, so a page with its own tab widgets can't be mistaken for
    /// the tab strip and a huge page can't slow the walk down.
    private nonisolated static func tabButtons(in window: AXUIElement) -> [AXUIElement] {
        var frontier = [window]
        var visited = 0
        for _ in 0..<6 {
            var next: [AXUIElement] = []
            for element in frontier {
                for child in axChildren(element, kAXChildrenAttribute) {
                    visited += 1
                    if visited > 400 { return [] }
                    let role = axString(child, kAXRoleAttribute)
                    if role == "AXTabGroup" {
                        let buttons = axChildren(child, kAXChildrenAttribute)
                            .filter { axString($0, kAXRoleAttribute) == "AXRadioButton" }
                        if !buttons.isEmpty { return buttons }
                    }
                    if role != "AXWebArea" { next.append(child) }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return []
    }

    private nonisolated static func axChildren(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private nonisolated static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return "" }
        return (value as? String) ?? ""
    }
}
