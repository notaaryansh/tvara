import AppKit
import Combine
import Foundation

enum SearchTab: String, CaseIterable, Hashable {
    case all
    case messages   // iMessage + WhatsApp + Discord merged
    case mail
    case apps
    case clipboard

    var label: String {
        switch self {
        case .all:       return "All"
        case .messages:  return "Messages"
        case .mail:      return "Mail"
        case .apps:      return "Apps"
        case .clipboard: return "Clipboard"
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var browserResults: [SearchResult] = []
    @Published private(set) var fileResults: [SearchResult] = []
    @Published private(set) var appResults: [SearchResult] = []
    @Published private(set) var whatsappResults: [SearchResult] = []
    @Published private(set) var discordResults: [SearchResult] = []
    @Published private(set) var imessageResults: [SearchResult] = []
    @Published private(set) var mailResults: [SearchResult] = []
    @Published private(set) var clipboardResults: [SearchResult] = []
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published var activeTab: SearchTab = .all {
        didSet { if oldValue != activeTab { syncDisplayedResults(resetSelection: true) } }
    }

    private let browserService: BrowserDatabaseService
    private let fileService: FileSearchService
    private let appService: AppSearchService
    private let whatsappService: WhatsAppService
    private let discordService: DiscordService
    private let imessageService: AppleMessagesService
    private let mailService: AppleMailService
    private let clipboardService: ClipboardHistoryService
    // Terminal history service intentionally not queried right now —
    // suppressed per UX direction. Kept in the codebase so we can re-enable
    // by adding back the async let + a SearchTab case.
    private var cancellables = Set<AnyCancellable>()
    private var currentSearchID = 0

    private static let allTabResultCap = 60
    private static let messagesTabResultCap = 50

    init(
        browserService: BrowserDatabaseService = BrowserDatabaseService(),
        fileService: FileSearchService = FileSearchService(),
        appService: AppSearchService = AppSearchService(),
        whatsappService: WhatsAppService = WhatsAppService(),
        discordService: DiscordService = DiscordService(),
        imessageService: AppleMessagesService = AppleMessagesService(),
        mailService: AppleMailService = AppleMailService(),
        clipboardService: ClipboardHistoryService = ClipboardHistoryService()
    ) {
        self.browserService = browserService
        self.fileService = fileService
        self.appService = appService
        self.whatsappService = whatsappService
        self.discordService = discordService
        self.imessageService = imessageService
        self.mailService = mailService
        self.clipboardService = clipboardService

        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.performSearch(q) }
            .store(in: &cancellables)

        Task { [appService] in await appService.warmCache() }
        Task { [discordService] in await discordService.warmCache() }
        Task { [clipboardService] in await clipboardService.start() }
    }

    // MARK: - Tabs

    func cycleTab(forward: Bool) {
        let all = SearchTab.allCases
        guard let idx = all.firstIndex(of: activeTab) else { return }
        let next = forward
            ? (idx + 1) % all.count
            : (idx - 1 + all.count) % all.count
        activeTab = all[next]
    }

    func count(for tab: SearchTab) -> Int {
        switch tab {
        case .all:
            // Reflects what the merged view actually shows (capped).
            return min(allMerged().count, Self.allTabResultCap)
        case .messages:
            return min(messagesMerged().count, Self.messagesTabResultCap)
        case .mail:      return mailResults.count
        case .apps:      return appResults.count
        case .clipboard: return clipboardResults.count
        }
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            browserResults = []; fileResults = []; appResults = []
            whatsappResults = []; discordResults = []
            imessageResults = []; mailResults = []
            clipboardResults = []
            results = []; selectedIndex = 0; isLoading = false
            return
        }

        currentSearchID &+= 1
        let searchID = currentSearchID
        isLoading = true

        Task {
            async let browser   = browserService.search(query: trimmed)
            async let files     = fileService.search(query: trimmed)
            async let apps      = appService.search(query: trimmed)
            async let whatsapp  = whatsappService.search(query: trimmed)
            async let discord   = discordService.search(query: trimmed)
            async let imsg      = imessageService.search(query: trimmed)
            async let mail      = mailService.search(query: trimmed)
            async let clipboard = clipboardService.search(query: trimmed)
            let (b, f, a, w, d, im, ml, cb) = await (
                browser, files, apps, whatsapp, discord, imsg, mail, clipboard
            )

            guard searchID == currentSearchID else { return }
            self.browserResults = b
            self.fileResults = f
            self.appResults = a
            self.whatsappResults = w
            self.discordResults = d
            self.imessageResults = im
            self.mailResults = ml
            self.clipboardResults = cb
            self.syncDisplayedResults(resetSelection: true)
            self.isLoading = false
        }
    }

    // MARK: - Tab → result merging

    /// "All" merges every source we surface — apps, browser, files, the
    /// three messaging sources, mail, and clipboard. Terminal results are
    /// intentionally excluded per UX direction. Sorted by rank desc so
    /// strong matches (contact name hits at 1000, exact-match apps at 600)
    /// land at the top regardless of source.
    private func allMerged() -> [SearchResult] {
        var merged: [SearchResult] = []
        merged.reserveCapacity(
            appResults.count + browserResults.count + fileResults.count
            + whatsappResults.count + discordResults.count + imessageResults.count
            + mailResults.count + clipboardResults.count
        )
        merged.append(contentsOf: appResults)
        merged.append(contentsOf: browserResults)
        merged.append(contentsOf: fileResults)
        merged.append(contentsOf: whatsappResults)
        merged.append(contentsOf: discordResults)
        merged.append(contentsOf: imessageResults)
        merged.append(contentsOf: mailResults)
        merged.append(contentsOf: clipboardResults)
        return merged.sorted(by: rankSort)
    }

    /// "Messages" pill: WhatsApp + iMessage + Discord, merged + rank-sorted.
    private func messagesMerged() -> [SearchResult] {
        var merged: [SearchResult] = []
        merged.reserveCapacity(
            whatsappResults.count + discordResults.count + imessageResults.count
        )
        merged.append(contentsOf: whatsappResults)
        merged.append(contentsOf: discordResults)
        merged.append(contentsOf: imessageResults)
        return merged.sorted(by: rankSort)
    }

    private func rankSort(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.rank != b.rank { return a.rank > b.rank }
        return (a.date ?? .distantPast) > (b.date ?? .distantPast)
    }

    private func syncDisplayedResults(resetSelection: Bool) {
        switch activeTab {
        case .all:
            results = Array(allMerged().prefix(Self.allTabResultCap))
        case .messages:
            results = Array(messagesMerged().prefix(Self.messagesTabResultCap))
        case .mail:
            results = mailResults
        case .apps:
            results = appResults
        case .clipboard:
            results = clipboardResults
        }
        if resetSelection { selectedIndex = 0 }
    }

    // MARK: - Selection / open

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let maxIdx = results.count - 1
        selectedIndex = min(max(selectedIndex + delta, 0), maxIdx)
    }

    @discardableResult
    func openSelected() -> Bool {
        guard results.indices.contains(selectedIndex) else { return false }
        return open(results[selectedIndex])
    }

    @discardableResult
    func open(_ result: SearchResult) -> Bool {
        switch result.openTarget {
        case .url(let s):
            guard let url = URL(string: s) else { return false }
            NSWorkspace.shared.open(url)
            return true

        case .file(let path):
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case .whatsappChat(let jid, let messageText):
            if !messageText.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(messageText, forType: .string)
            }
            if jid.hasSuffix("@s.whatsapp.net"),
               let at = jid.firstIndex(of: "@") {
                let phone = String(jid[..<at])
                if phone.allSatisfy({ $0.isNumber }),
                   let url = URL(string: "whatsapp://send?phone=\(phone)") {
                    NSWorkspace.shared.open(url)
                    return true
                }
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/WhatsApp.app"))

        case .imessageChat(let handle, let messageText):
            if !messageText.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(messageText, forType: .string)
            }
            if !handle.isEmpty,
               let url = URL(string: "sms:\(handle)") {
                NSWorkspace.shared.open(url)
                return true
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))

        case .copyToClipboard(let s):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
            return true
        }
    }

    func reset() {
        query = ""
        browserResults = []; fileResults = []; appResults = []
        whatsappResults = []; discordResults = []
        imessageResults = []; mailResults = []
        clipboardResults = []
        results = []; selectedIndex = 0; isLoading = false
        activeTab = .all
    }
}
