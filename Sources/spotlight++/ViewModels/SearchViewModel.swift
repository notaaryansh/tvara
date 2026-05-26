import AppKit
import Combine
import Foundation

enum SearchTab: String, CaseIterable, Hashable {
    case apps
    case browser
    case files
    case messages
    case discord

    var label: String {
        switch self {
        case .apps:     return "Apps"
        case .browser:  return "Browser"
        case .files:    return "Files"
        case .messages: return "Messages"
        case .discord:  return "Discord"
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var browserResults: [SearchResult] = []
    @Published private(set) var fileResults: [SearchResult] = []
    @Published private(set) var appResults: [SearchResult] = []
    @Published private(set) var messageResults: [SearchResult] = []
    @Published private(set) var discordResults: [SearchResult] = []
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published var activeTab: SearchTab = .apps {
        didSet { if oldValue != activeTab { syncDisplayedResults(resetSelection: true) } }
    }

    private let browserService: BrowserDatabaseService
    private let fileService: FileSearchService
    private let appService: AppSearchService
    private let whatsappService: WhatsAppService
    private let discordService: DiscordService
    private var cancellables = Set<AnyCancellable>()
    private var currentSearchID = 0

    init(
        browserService: BrowserDatabaseService = BrowserDatabaseService(),
        fileService: FileSearchService = FileSearchService(),
        appService: AppSearchService = AppSearchService(),
        whatsappService: WhatsAppService = WhatsAppService(),
        discordService: DiscordService = DiscordService()
    ) {
        self.browserService = browserService
        self.fileService = fileService
        self.appService = appService
        self.whatsappService = whatsappService
        self.discordService = discordService

        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.performSearch(q) }
            .store(in: &cancellables)

        // Populate slow indexes in the background so the first ⌘K → query
        // doesn't pay for cold scans.
        Task { [appService] in await appService.warmCache() }
        Task { [discordService] in await discordService.warmCache() }
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
        case .apps:     return appResults.count
        case .browser:  return browserResults.count
        case .files:    return fileResults.count
        case .messages: return messageResults.count
        case .discord:  return discordResults.count
        }
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            browserResults = []
            fileResults = []
            appResults = []
            messageResults = []
            discordResults = []
            results = []
            selectedIndex = 0
            isLoading = false
            return
        }

        currentSearchID &+= 1
        let searchID = currentSearchID
        isLoading = true

        Task {
            async let browser  = browserService.search(query: trimmed)
            async let files    = fileService.search(query: trimmed)
            async let apps     = appService.search(query: trimmed)
            async let messages = whatsappService.search(query: trimmed)
            async let discord  = discordService.search(query: trimmed)
            let (b, f, a, m, d) = await (browser, files, apps, messages, discord)

            // Drop stale responses (user kept typing).
            guard searchID == currentSearchID else { return }
            self.browserResults = b
            self.fileResults = f
            self.appResults = a
            self.messageResults = m
            self.discordResults = d
            self.syncDisplayedResults(resetSelection: true)
            self.isLoading = false
        }
    }

    private func syncDisplayedResults(resetSelection: Bool) {
        switch activeTab {
        case .apps:     results = appResults
        case .browser:  results = browserResults
        case .files:    results = fileResults
        case .messages: results = messageResults
        case .discord:  results = discordResults
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
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(messageText, forType: .string)

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
        }
    }

    func reset() {
        query = ""
        browserResults = []
        fileResults = []
        appResults = []
        messageResults = []
        discordResults = []
        results = []
        selectedIndex = 0
        isLoading = false
        activeTab = .apps
    }
}
