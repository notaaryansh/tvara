import AppKit
import Combine
import Foundation

enum SearchTab: String, CaseIterable, Hashable {
    case apps
    case browser
    case files
    case messages
    case discord
    case imessage
    case mail
    case terminal
    case clipboard

    var label: String {
        switch self {
        case .apps:      return "Apps"
        case .browser:   return "Browser"
        case .files:     return "Files"
        case .messages:  return "WhatsApp"
        case .discord:   return "Discord"
        case .imessage:  return "iMessage"
        case .mail:      return "Mail"
        case .terminal:  return "Terminal"
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
    @Published private(set) var messageResults: [SearchResult] = []
    @Published private(set) var discordResults: [SearchResult] = []
    @Published private(set) var imessageResults: [SearchResult] = []
    @Published private(set) var mailResults: [SearchResult] = []
    @Published private(set) var terminalResults: [SearchResult] = []
    @Published private(set) var clipboardResults: [SearchResult] = []
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
    private let imessageService: AppleMessagesService
    private let mailService: AppleMailService
    private let terminalService: TerminalHistoryService
    private let clipboardService: ClipboardHistoryService
    private var cancellables = Set<AnyCancellable>()
    private var currentSearchID = 0

    init(
        browserService: BrowserDatabaseService = BrowserDatabaseService(),
        fileService: FileSearchService = FileSearchService(),
        appService: AppSearchService = AppSearchService(),
        whatsappService: WhatsAppService = WhatsAppService(),
        discordService: DiscordService = DiscordService(),
        imessageService: AppleMessagesService = AppleMessagesService(),
        mailService: AppleMailService = AppleMailService(),
        terminalService: TerminalHistoryService = TerminalHistoryService(),
        clipboardService: ClipboardHistoryService = ClipboardHistoryService()
    ) {
        self.browserService = browserService
        self.fileService = fileService
        self.appService = appService
        self.whatsappService = whatsappService
        self.discordService = discordService
        self.imessageService = imessageService
        self.mailService = mailService
        self.terminalService = terminalService
        self.clipboardService = clipboardService

        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.performSearch(q) }
            .store(in: &cancellables)

        Task { [appService] in await appService.warmCache() }
        Task { [discordService] in await discordService.warmCache() }
        // Start the clipboard history polling loop.
        Task { [clipboardService] in await clipboardService.start() }
    }

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
        case .apps:      return appResults.count
        case .browser:   return browserResults.count
        case .files:     return fileResults.count
        case .messages:  return messageResults.count
        case .discord:   return discordResults.count
        case .imessage:  return imessageResults.count
        case .mail:      return mailResults.count
        case .terminal:  return terminalResults.count
        case .clipboard: return clipboardResults.count
        }
    }

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            browserResults = []; fileResults = []; appResults = []
            messageResults = []; discordResults = []
            imessageResults = []; mailResults = []
            terminalResults = []; clipboardResults = []
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
            async let terminal  = terminalService.search(query: trimmed)
            async let clipboard = clipboardService.search(query: trimmed)
            let (b, f, a, w, d, im, ml, tm, cb) = await (
                browser, files, apps, whatsapp, discord, imsg, mail, terminal, clipboard
            )

            guard searchID == currentSearchID else { return }
            self.browserResults = b
            self.fileResults = f
            self.appResults = a
            self.messageResults = w
            self.discordResults = d
            self.imessageResults = im
            self.mailResults = ml
            self.terminalResults = tm
            self.clipboardResults = cb
            self.syncDisplayedResults(resetSelection: true)
            self.isLoading = false
        }
    }

    private func syncDisplayedResults(resetSelection: Bool) {
        switch activeTab {
        case .apps:      results = appResults
        case .browser:   results = browserResults
        case .files:     results = fileResults
        case .messages:  results = messageResults
        case .discord:   results = discordResults
        case .imessage:  results = imessageResults
        case .mail:      results = mailResults
        case .terminal:  results = terminalResults
        case .clipboard: results = clipboardResults
        }
        if resetSelection { selectedIndex = 0 }
    }

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
        messageResults = []; discordResults = []
        imessageResults = []; mailResults = []
        terminalResults = []; clipboardResults = []
        results = []; selectedIndex = 0; isLoading = false
        activeTab = .apps
    }
}
