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
    @Published private(set) var isAIThinking: Bool = false
    @Published private(set) var aiExplanation: String? = nil
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
    private let smartService: SmartSearchService
    private let embeddingStore: EmbeddingStore
    // Terminal history service intentionally not queried right now —
    // suppressed per UX direction. Kept in the codebase so we can re-enable
    // by adding back the async let + a SearchTab case.
    private var cancellables = Set<AnyCancellable>()
    private var currentSearchID = 0

    private static let allTabResultCap = 60
    private static let messagesTabResultCap = 50

    /// Minimum cosine similarity a semantically-reranked result must clear
    /// to be shown. Below this we treat it as noise from the candidate pool
    /// (e.g. unrelated chitchat in the same channel as the real matches).
    /// Empirical: addresses → 0.45-0.6, neighborhood mentions → 0.3-0.4,
    /// one-word chitchat → < 0.15. 0.25 is the cleanest separator.
    private static let semanticScoreFloor: Float = 0.25

    init(
        browserService: BrowserDatabaseService = BrowserDatabaseService(),
        fileService: FileSearchService = FileSearchService(),
        appService: AppSearchService = AppSearchService(),
        whatsappService: WhatsAppService = WhatsAppService(),
        discordService: DiscordService = DiscordService(),
        imessageService: AppleMessagesService = AppleMessagesService(),
        mailService: AppleMailService = AppleMailService(),
        clipboardService: ClipboardHistoryService = ClipboardHistoryService(),
        smartService: SmartSearchService = SmartSearchService(),
        embeddingStore: EmbeddingStore = EmbeddingStore()
    ) {
        self.browserService = browserService
        self.fileService = fileService
        self.appService = appService
        self.whatsappService = whatsappService
        self.discordService = discordService
        self.imessageService = imessageService
        self.mailService = mailService
        self.clipboardService = clipboardService
        self.smartService = smartService
        self.embeddingStore = embeddingStore

        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.performSearch(q) }
            .store(in: &cancellables)

        // Fire every TCC-gated service up front so macOS shows all the
        // permission prompts on launch #1 instead of staggering them across
        // launches as the user first searches each source.
        Task { [appService] in await appService.warmCache() }
        Task { [discordService] in await discordService.warmCache() }
        Task { [clipboardService] in await clipboardService.start() }
        Task { [whatsappService] in await whatsappService.warmCache() }
        Task { [imessageService] in await imessageService.warmCache() }
        Task { [mailService] in await mailService.warmCache() }
        Task { [smartService] in await smartService.warmCache() }
        Task { [fileService] in await fileService.warmCache() }
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
        case .apps:      return appResults.count + fileResults.count
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
            results = []; selectedIndex = 0
            isLoading = false; isAIThinking = false; aiExplanation = nil
            return
        }

        currentSearchID &+= 1
        let searchID = currentSearchID
        isLoading = true

        // Decide once at search-start whether this query is "sentence-like"
        // enough to spend an LLM call on. The check itself is sync + cheap;
        // availability check is sync after the first call (it caches).
        let smart = smartService
        // Heuristic is sync + nonisolated; key availability requires actor hop.
        let heuristic = smart.shouldUseSmartSearch(query: trimmed)
        Task {
            var useSmart = false
            if heuristic {
                useSmart = await smart.isAvailable()
            }

            if useSmart {
                await self.runSmartSearch(query: trimmed, searchID: searchID)
            } else {
                await self.runKeywordSearch(query: trimmed, searchID: searchID)
                self.aiExplanation = nil
                self.isAIThinking = false
            }
        }
    }

    /// Direct keyword search across all services. Existing behavior.
    private func runKeywordSearch(query: String, searchID: Int) async {
        async let browser   = browserService.search(query: query)
        async let files     = fileService.search(query: query)
        async let apps      = appService.search(query: query)
        async let whatsapp  = whatsappService.search(query: query)
        async let discord   = discordService.search(query: query)
        async let imsg      = imessageService.search(query: query)
        async let mail      = mailService.search(query: query)
        async let clipboard = clipboardService.search(query: query)
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

    /// Smart path: ask the LLM to plan the query, then drive existing
    /// services with structured filters. On planner failure, falls back
    /// to plain keyword search transparently.
    private func runSmartSearch(query: String, searchID: Int) async {
        isAIThinking = true
        aiExplanation = nil

        let plan: QueryPlan
        do {
            plan = try await smartService.plan(query: query)
        } catch {
            await runKeywordSearch(query: query, searchID: searchID)
            isAIThinking = false
            return
        }

        guard searchID == currentSearchID else { return }
        aiExplanation = plan.explanation

        // Route based on the plan's structured fields, not just a
        // concatenated string. Critical for queries like "address i sent
        // to drish" — we don't want LIKE '%address drish%' (matches zero
        // rows), we want messages WITH drish containing 'address'.
        await routeSmartSearch(plan: plan, searchID: searchID)

        guard searchID == currentSearchID else { return }
        if let mappedTab = Self.mapPlannedSource(plan.source) {
            activeTab = mappedTab
        }
        isAIThinking = false
    }

    /// Per-source routing of a planner result.
    private func routeSmartSearch(plan: QueryPlan, searchID: Int) async {
        // Messages with a named contact: fetch contact-matched results
        // from each chat source. Discord goes through the semantic reranker
        // (we have pre-computed embeddings for those); WhatsApp/iMessage
        // fall back to the keyword filter for v0.
        if plan.source == .messages, let contact = plan.contact, !contact.isEmpty {
            // Discord uses the user_id-anchored pool (messages involving the
            // contact), not content LIKE — content search would only find
            // messages whose *text* contains the contact's name, which is
            // not what "messages with drish" actually means.
            async let wa = whatsappService.search(query: contact)
            async let dc = discordService.messagesInvolving(contactName: contact)
            async let im = imessageService.search(query: contact)
            let (w, d, i) = await (wa, dc, im)
            guard searchID == currentSearchID else { return }

            let filterTerms = plan.keywords.map { $0.lowercased() }
            func passes(_ r: SearchResult) -> Bool {
                guard !filterTerms.isEmpty else { return true }
                let hay = (r.title + " " + r.subtitle).lowercased()
                return filterTerms.contains(where: { hay.contains($0) })
            }
            // Contact-card rows have empty messageText; always keep those
            // (they're the "open chat with X" shortcut, useful regardless).
            func isContactCard(_ r: SearchResult) -> Bool {
                if case .whatsappChat(_, let m) = r.openTarget, m.isEmpty { return true }
                if case .imessageChat(_, let m) = r.openTarget, m.isEmpty { return true }
                return false
            }

            // Discord: try semantic rerank with embeddings; fall back to
            // keyword filter when search_term missing or embeddings store
            // unavailable.
            let rerankedD = await semanticRerank(
                results: d,
                searchTerm: plan.searchTerm,
                keepIf: isContactCard
            ) ?? d.filter { isContactCard($0) || passes($0) }

            let filteredW = w.filter { isContactCard($0) || passes($0) }
            let filteredI = i.filter { isContactCard($0) || passes($0) }

            self.whatsappResults = filteredW
            self.discordResults = rerankedD
            self.imessageResults = filteredI
            self.appResults = []
            self.browserResults = []
            self.fileResults = []
            self.mailResults = []
            self.clipboardResults = []
            self.syncDisplayedResults(resetSelection: true)
            self.isLoading = false
            return
        }

        // Messages without a contact: the planner extracted a topic but no
        // person ("what was the modding tool i talked about on discord").
        // Pull the full Discord index and let the semantic reranker do the
        // work — that's the only thing that handles "concept search" well.
        // Keyword LIKE here would fail any time the planner included a
        // source-hint word (e.g. "discord") that doesn't appear in the
        // target message contiguously.
        if plan.source == .messages {
            let candidates = await discordService.allMessagesForRerank()
            guard searchID == currentSearchID else { return }
            let reranked = await semanticRerank(
                results: candidates,
                searchTerm: plan.searchTerm,
                keepIf: { _ in false }
            ) ?? []
            self.discordResults = reranked
            self.whatsappResults = []
            self.imessageResults = []
            self.appResults = []
            self.browserResults = []
            self.fileResults = []
            self.mailResults = []
            self.clipboardResults = []
            self.syncDisplayedResults(resetSelection: true)
            self.isLoading = false
            return
        }

        // Mail with a planner that mentioned a contact: include the
        // contact as an additional FTS term (Mail FTS already indexes
        // sender + subject + body).
        if plan.source == .mail {
            var terms = plan.keywords
            if let c = plan.contact, !c.isEmpty { terms.append(c) }
            let aiQuery = terms.joined(separator: " ")
            await runKeywordSearch(query: aiQuery, searchID: searchID)
            return
        }

        // Single-source plans (apps/browser/files/clipboard): just use
        // the extracted keywords. Contact (if any) is appended as another
        // search term — it'd be ignored by services that don't have one,
        // and may help on services like browser history that index URLs.
        if plan.source != .any {
            await runKeywordSearch(query: plan.searchQuery, searchID: searchID)
            return
        }

        // Plan said "any" — keyword search across everything with the
        // planner's distilled query.
        await runKeywordSearch(query: plan.searchQuery, searchID: searchID)
    }

    /// Semantic rerank for Discord results: embed the planner's search_term
    /// once, look up pre-computed vectors for the candidate set, sort by
    /// cosine. Returns nil when we can't run (no key, no embeddings, empty
    /// search_term, no candidates with stored vectors) — callers should
    /// fall back to keyword filtering.
    ///
    /// Rows kept by `keepIf` (e.g. contact-card shortcuts) are pinned at
    /// the top regardless of similarity.
    private func semanticRerank(
        results: [SearchResult],
        searchTerm: String,
        keepIf shouldPin: (SearchResult) -> Bool
    ) async -> [SearchResult]? {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        guard await embeddingStore.isAvailable() else { return nil }
        guard let key = await smartService.apiKey() else { return nil }

        // Split out pinned rows (contact cards / non-Discord) from rerankable.
        var pinned: [SearchResult] = []
        var candidates: [SearchResult] = []
        for r in results {
            if shouldPin(r) || r.discordMessageId == nil {
                pinned.append(r)
            } else {
                candidates.append(r)
            }
        }
        let ids = candidates.compactMap { $0.discordMessageId }
        guard !ids.isEmpty else { return nil }

        let vectors = await embeddingStore.vectors(forDiscordMessages: ids)
        guard !vectors.isEmpty else { return nil }

        let qVec: [Float]
        do {
            qVec = try await embeddingStore.embedQuery(term, apiKey: key)
        } catch {
            return nil
        }

        // Two buckets: candidates we have a vector for (scored + reranked),
        // and candidates we don't (dropped entirely when a semantic rerank
        // is running — keeping them would just be the channel's chitchat
        // shown unranked alongside genuine matches, which is the bug the
        // user just flagged).
        var scored: [(SearchResult, Float)] = []
        for r in candidates {
            if let id = r.discordMessageId, let v = vectors[id] {
                scored.append((r, EmbeddingStore.cosine(qVec, v)))
            }
        }
        // Apply similarity floor BEFORE sorting so noise never appears
        // at all — not just buried at the bottom. The candidate pool is
        // intentionally wide (any message in a channel where the contact
        // has spoken) to recover the user's own sent messages, but most
        // of that pool is off-topic chitchat that needs trimming.
        scored = scored.filter { $0.1 >= Self.semanticScoreFloor }
        scored.sort { $0.1 > $1.1 }

        // CRITICAL: overwrite each reranked result's `rank` field with a
        // synthetic monotonically-decreasing value. Without this, the
        // downstream messagesMerged() / allMerged() re-sorts by `rank`
        // (which Discord assigns by recency) and the semantic ordering
        // is silently discarded — making different queries produce the
        // same recency-ordered output. Use 999..900-ish so reranked rows
        // sit above keyword-Discord (rank ≤ 140) but below pinned contact
        // cards (rank 1000).
        let reranked: [SearchResult] = scored.enumerated().map { (idx, pair) in
            pair.0.withRank(999 - idx)
        }
        return pinned + reranked
    }

    /// Translate the LLM's planned source name into the pill it should
    /// activate. "browser" / "files" don't have their own pill anymore
    /// (they live inside "All"), so we route those to .all.
    private static func mapPlannedSource(_ source: QueryPlan.Source) -> SearchTab? {
        switch source {
        case .messages:  return .messages
        case .mail:      return .mail
        case .apps:      return .apps
        case .clipboard: return .clipboard
        case .browser, .files, .any: return .all
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
            // "Apps" pill is really "things you can open" — apps + files + folders,
            // ranked together so app exact-matches sit above looser file substrings.
            results = (appResults + fileResults).sorted(by: rankSort)
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
        results = []; selectedIndex = 0
        isLoading = false; isAIThinking = false; aiExplanation = nil
        activeTab = .all
    }
}
