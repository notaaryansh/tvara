import AppKit
import Combine
import Foundation

enum SearchTab: String, CaseIterable, Hashable {
    case all
    case messages   // iMessage + WhatsApp + Discord merged
    case mail
    case apps
    case images
    case clipboard

    var label: String {
        switch self {
        case .all:       return "All"
        case .messages:  return "Messages"
        case .mail:      return "Mail"
        case .apps:      return "Apps"
        case .images:    return "Images"
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
    @Published private(set) var notesResults: [SearchResult] = []
    @Published private(set) var notionResults: [SearchResult] = []
    @Published private(set) var linearResults: [SearchResult] = []
    @Published private(set) var spotifyResults: [SearchResult] = []
    @Published private(set) var clipboardResults: [SearchResult] = []
    @Published private(set) var imageResults: [SearchResult] = []
    @Published private(set) var windowResults: [SearchResult] = []
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isAIThinking: Bool = false
    @Published private(set) var aiExplanation: String? = nil
    @Published var activeTab: SearchTab = .all {
        didSet { if oldValue != activeTab { syncDisplayedResults(resetSelection: true) } }
    }

    /// Compose flow: nil = normal search. When non-nil, the SearchView swaps
    /// the results area for the ComposeView. `actingOn` is set when the user
    /// has selected a result and pressed ⌘↩ to "act on" it — they then type
    /// an intent (e.g. "send drishtu a message about this") that gets routed
    /// through SmartSearchService.planAction and lands in `composeState`.
    @Published var composeState: ComposeState? = nil
    @Published private(set) var actingOn: SearchResult? = nil

    private let browserService: BrowserDatabaseService
    private let fileService: FileSearchService
    private let appService: AppSearchService
    private let whatsappService: WhatsAppService
    private let discordService: DiscordService
    private let imessageService: AppleMessagesService
    private let mailService: AppleMailService
    private let notesService: AppleNotesService
    private let notionService: NotionService
    private let linearService: LinearService
    private let spotifyService: SpotifyService
    private let clipboardService: ClipboardHistoryService
    private let imageService: ImageIndexService
    private let windowService: WindowManagerService
    private let smartService: SmartSearchService
    private let embeddingStore: EmbeddingStore
    // Terminal history service intentionally not queried right now —
    // suppressed per UX direction. Kept in the codebase so we can re-enable
    // by adding back the async let + a SearchTab case.
    private var cancellables = Set<AnyCancellable>()
    private var currentSearchID = 0
    /// Latest in-flight smart-search task. Cancelled when a new search
    /// starts so we (a) stop paying for stale OpenAI calls and (b) avoid
    /// the "Thinking…" spinner pile-up where older tasks leave the flag
    /// set true.
    private var inflightSmartTask: Task<Void, Never>?

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
        notesService: AppleNotesService = AppleNotesService(),
        notionService: NotionService = NotionService(),
        linearService: LinearService = LinearService(),
        spotifyService: SpotifyService = SpotifyService(),
        clipboardService: ClipboardHistoryService = ClipboardHistoryService(),
        imageService: ImageIndexService = ImageIndexService(),
        windowService: WindowManagerService = WindowManagerService(),
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
        self.notesService = notesService
        self.notionService = notionService
        self.linearService = linearService
        self.spotifyService = spotifyService
        self.clipboardService = clipboardService
        self.imageService = imageService
        self.windowService = windowService
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
        Task { [notesService] in await notesService.warmCache() }
        Task { [notionService] in await notionService.warmCache() }
        // MobileCLIP-S2 image index — warms the CoreML models and triggers
        // an incremental sweep of ~/Pictures, ~/Desktop, ~/Downloads.
        Task.detached { [imageService] in await imageService.warmCache() }
        // Calendar (EventKit) — used by Create Event in compose.
        Task { await CalendarEventSaver.warmAccess() }
        // Automation (Apple Events) → Messages.app — used by real iMessage
        // send. Runs on a detached task because AEDeterminePermission may
        // block until the user dismisses the TCC dialog.
        Task.detached { IMessageSender.warmAccess() }
        // Automation → Spotify.app — used by playlist shuffle-play.
        Task.detached { SpotifyPlayer.warmAccess() }
    }

    // MARK: - Window-management target

    /// Set by SearchWindowController BEFORE NSApp.activate() steals focus,
    /// so window-management commands snap the previously-frontmost app's
    /// window rather than our own panel. Pass nil to clear (e.g. opened
    /// via status-bar with no prior focus).
    func setWindowTarget(pid: pid_t?, appName: String?) {
        windowService.targetPID = pid
        windowService.targetAppName = appName
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
        case .images:    return imageResults.count
        case .clipboard: return clipboardResults.count
        }
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            browserResults = []; fileResults = []; appResults = []
            whatsappResults = []; discordResults = []
            imessageResults = []; mailResults = []; notesResults = []
            notionResults = []; linearResults = []; spotifyResults = []
            clipboardResults = []; imageResults = []; windowResults = []
            results = []; selectedIndex = 0
            isLoading = false; isAIThinking = false; aiExplanation = nil
            return
        }

        // Window-management commands resolve synchronously — flat scan of
        // a ~60-entry alias table, sub-millisecond, no I/O. Setting these
        // here (and re-syncing below) means "left" / "max" appear in the
        // list the same frame the keystroke lands, before any async
        // service responds.
        windowResults = windowService.match(query: trimmed)
        syncDisplayedResults(resetSelection: false)

        currentSearchID &+= 1
        let searchID = currentSearchID
        isLoading = true

        // Static intent shortcut: queries like "open project tracker in
        // notion" or "open tickets in linear" are routed straight to the
        // matching service. The trigger word ("notion", "linear", etc.)
        // is stripped along with filler words; what survives becomes the
        // needle. Cheap + reliable — no LLM call needed for these.
        switch Self.detectAppIntent(query: trimmed) {
        case .notion(let needle):
            Task { await self.runAppOnly(.notion, needle: needle, searchID: searchID) }
            return
        case .linear(let needle):
            Task { await self.runAppOnly(.linear, needle: needle, searchID: searchID) }
            return
        case .spotify(let needle):
            Task { await self.runAppOnly(.spotify, needle: needle, searchID: searchID) }
            return
        case .none:
            break
        }

        // Decide once at search-start whether this query is "sentence-like"
        // enough to spend an LLM call on. The check itself is sync + cheap;
        // availability check is sync after the first call (it caches).
        let smart = smartService
        // Heuristic is sync + nonisolated; key availability requires actor hop.
        let heuristic = smart.shouldUseSmartSearch(query: trimmed)
        // Cancel any prior in-flight smart task so we (a) don't pile up
        // OpenAI calls (each was ~$0.001 wasted before) and (b) keep
        // isAIThinking semantically tied to ONE active query at a time.
        inflightSmartTask?.cancel()
        inflightSmartTask = Task {
            var useSmart = false
            if heuristic {
                useSmart = await smart.isAvailable()
            }
            if Task.isCancelled { return }

            if useSmart {
                await self.runSmartSearch(query: trimmed, searchID: searchID)
            } else {
                await self.runKeywordSearch(query: trimmed, searchID: searchID)
                self.aiExplanation = nil
                self.isAIThinking = false
            }
        }
    }

    /// Known third-party apps we route directly when their name appears in
    /// the query. The string is the trigger keyword (must be present as a
    /// word in the query); the case carries the cleaned needle.
    private enum AppIntent {
        case notion(needle: String)
        case linear(needle: String)
        case spotify(needle: String)
        case none
    }

    /// Common filler words stripped from app-intent queries before the
    /// remainder is used as the search needle.
    private static let appIntentStopwords: Set<String> = [
        "open", "in", "on", "the", "my", "find", "search", "for", "page",
        "doc", "document", "to", "a", "an", "show", "me", "get",
        "from", "into", "please", "pls", "with", "and",
        // Spotify-flavored stopwords; safe to drop because they don't
        // disambiguate playlist names.
        "play", "songs", "song", "track", "tracks", "shuffle", "random",
        "music"
    ]

    /// Decides whether the query is "open X in <app>" intent and which
    /// app it targets. Specific app names take priority over generic
    /// verbs ("play") so "open notion page about play time" stays a
    /// Notion intent rather than getting hijacked by the Spotify trigger.
    private static func detectAppIntent(query: String) -> AppIntent {
        let tokens = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        func cleaned(_ stripping: Set<String>) -> String {
            let drop = stripping.union(appIntentStopwords)
            return tokens.filter { !drop.contains($0) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        // Specific app names first.
        if tokens.contains("notion")  { return .notion(needle: cleaned(["notion"])) }
        if tokens.contains("linear")  { return .linear(needle: cleaned(["linear"])) }
        if tokens.contains("spotify") {
            let needle = cleaned(["spotify"])
            // "spotify" alone (no needle) → just open Spotify, no junk.
            return .spotify(needle: needle)
        }

        // Generic "play X" → Spotify intent ONLY when no specific app
        // matched AND there's a target word after "play". Catches "play
        // random songs from cherry heart" but skips bare "play" which
        // would otherwise match every playlist alphabetically.
        if tokens.contains("play") {
            let needle = cleaned(["play"])
            guard needle.count >= 2 else { return .none }
            return .spotify(needle: needle)
        }

        return .none
    }

    /// Identifies which third-party app the user is routing to.
    /// Used as a small enum to keep `runAppOnly` source-agnostic.
    private enum AppTarget {
        case notion, linear, spotify
    }

    /// Single-source search path used by app-intent shortcuts. Clears
    /// every other result list so the user sees a focused, one-row-ish
    /// view they can hit Enter on. Sets an explanation banner so the
    /// intent recognition is visible in the UI.
    private func runAppOnly(_ app: AppTarget, needle: String, searchID: Int) async {
        let results: [SearchResult]
        let label: String
        switch app {
        case .notion:
            results = await notionService.search(query: needle)
            label = "Notion"
        case .linear:
            results = await linearService.search(query: needle)
            label = "Linear"
        case .spotify:
            results = await spotifyService.search(query: needle)
            label = "Spotify"
        }
        guard searchID == currentSearchID else { return }
        self.notionResults  = (app == .notion)  ? results : []
        self.linearResults  = (app == .linear)  ? results : []
        self.spotifyResults = (app == .spotify) ? results : []
        self.browserResults = []
        self.fileResults = []
        self.appResults = []
        self.whatsappResults = []
        self.discordResults = []
        self.imessageResults = []
        self.mailResults = []
        self.notesResults = []
        self.clipboardResults = []
        self.activeTab = .all
        self.aiExplanation = needle.isEmpty
            ? "Opening \(label)"
            : "Looking in \(label) for \"\(needle)\""
        self.syncDisplayedResults(resetSelection: true)
        self.isLoading = false
        self.isAIThinking = false
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
        async let notes     = notesService.search(query: query)
        async let notion    = notionService.search(query: query)
        async let clipboard = clipboardService.search(query: query)
        async let images    = imageService.search(query)
        let (b, f, a, w, d, im, ml, nt, nn, cb, ig) = await (
            browser, files, apps, whatsapp, discord, imsg, mail, notes, notion, clipboard, images
        )

        guard searchID == currentSearchID else { return }
        self.browserResults = b
        self.fileResults = f
        self.appResults = a
        self.whatsappResults = w
        self.discordResults = d
        self.imessageResults = im
        self.mailResults = ml
        self.notesResults = nt
        self.notionResults = nn
        self.clipboardResults = cb
        self.imageResults = ig
        self.syncDisplayedResults(resetSelection: true)
        self.isLoading = false
    }

    /// Smart path: ask the LLM to plan the query, then drive existing
    /// services with structured filters. On planner failure, falls back
    /// to plain keyword search transparently.
    private func runSmartSearch(query: String, searchID: Int) async {
        isAIThinking = true
        aiExplanation = nil

        // Clear the "Thinking…" spinner on EVERY exit path (success,
        // throw, guard-bailout, or cancellation). Only the latest in-
        // flight search owns the flag — stale tasks bail without
        // touching it so they don't toggle UI for a query the user
        // already moved past.
        defer {
            if searchID == currentSearchID {
                isAIThinking = false
            }
        }

        let plan: QueryPlan
        do {
            plan = try await smartService.plan(query: query)
        } catch {
            await runKeywordSearch(query: query, searchID: searchID)
            return
        }
        if Task.isCancelled { return }
        guard searchID == currentSearchID else { return }
        aiExplanation = plan.explanation

        // Route based on the plan's structured fields, not just a
        // concatenated string. Critical for queries like "address i sent
        // to drish" — we don't want LIKE '%address drish%' (matches zero
        // rows), we want messages WITH drish containing 'address'.
        await routeSmartSearch(plan: plan, searchID: searchID)

        if Task.isCancelled { return }
        guard searchID == currentSearchID else { return }
        if let mappedTab = Self.mapPlannedSource(plan.source) {
            activeTab = mappedTab
        }
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
            self.notesResults = []
            self.notionResults = []
            self.linearResults = []
            self.spotifyResults = []
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
            self.notesResults = []
            self.notionResults = []
            self.linearResults = []
            self.spotifyResults = []
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
            + mailResults.count + notesResults.count + notionResults.count
            + linearResults.count + spotifyResults.count + clipboardResults.count
        )
        merged.append(contentsOf: appResults)
        merged.append(contentsOf: browserResults)
        merged.append(contentsOf: fileResults)
        merged.append(contentsOf: whatsappResults)
        merged.append(contentsOf: discordResults)
        merged.append(contentsOf: imessageResults)
        merged.append(contentsOf: mailResults)
        merged.append(contentsOf: notesResults)
        merged.append(contentsOf: notionResults)
        merged.append(contentsOf: linearResults)
        merged.append(contentsOf: spotifyResults)
        merged.append(contentsOf: clipboardResults)
        merged.append(contentsOf: imageResults)
        merged.append(contentsOf: windowResults)
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
        case .images:
            results = imageResults
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

        case .notesNote(let title):
            // Apple Notes has no stable external per-note deep link, so we
            // copy the title to the clipboard and open Notes.app — the user
            // can ⌘F + ⌘V to jump to the note. Same fallback pattern we use
            // for iMessage chats.
            if !title.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(title, forType: .string)
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))

        case .spotifyPlay(let uri, let shuffle):
            // AppleScript blocks until Spotify responds (~100ms); run off
            // the main thread so the launcher's dismiss animation isn't
            // janky. We treat any failure as "still consider it opened"
            // — Spotify will be foregrounded by the activate command even
            // if the play track step fails (e.g. invalid URI).
            Task.detached {
                try? SpotifyPlayer.play(uri: uri, shuffle: shuffle)
            }
            return true

        case .windowAction(let action):
            // AX position/size set runs synchronously and returns in well
            // under a frame — fine on the main actor. Returning true
            // closes the panel; the freshly-snapped window comes back to
            // the foreground because its app was already the previously
            // frontmost.
            return windowService.execute(action)
        }
    }

    // MARK: - Compose flow

    /// Enter acting mode using arbitrary text captured from the user's
    /// current selection (e.g. text highlighted in Chrome or any other
    /// app when they hit ⌘K). We map the originating app to a Source
    /// when we recognize it so the acting card shows "FROM WHATSAPP" /
    /// "FROM MESSAGES" / "FROM SAFARI" etc with the right icon — falls
    /// back to generic .file for unknown apps.
    func beginActingWithSelection(text: String, sourceAppName: String? = nil) {
        let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return }
        let synthetic = SearchResult(
            title: "Selected text",
            subtitle: snippet,
            source: Self.sourceForAppName(sourceAppName),
            date: nil,
            badge: nil,
            openTarget: .copyToClipboard(snippet),
            rank: 0
        )
        // Stash the original app name so the acting card can show it
        // verbatim instead of the Source enum's stylized name (e.g.
        // "Cursor" instead of "File" when we don't recognize the app).
        actingSourceDisplayName = sourceAppName
        beginActing(on: synthetic)
    }

    /// Display name to override `source.rawValue` in the acting context
    /// card. Set by selection-capture; nil for normal search-result acting.
    @Published private(set) var actingSourceDisplayName: String?

    /// Map a frontmost-app name to one of our known Source enum cases so
    /// the acting card gets the appropriate icon + tint. Unknown apps
    /// fall back to .file; the actual app name still surfaces via
    /// `actingSourceDisplayName`.
    private static func sourceForAppName(_ name: String?) -> SearchResult.Source {
        guard let lower = name?.lowercased() else { return .file }
        switch lower {
        case "whatsapp":              return .whatsapp
        case "messages":              return .imessage
        case "discord":               return .discord
        case "mail":                  return .mail
        case "notes":                 return .notes
        case "notion":                return .notion
        case "linear":                return .linear
        case "spotify":               return .spotify
        case "safari":                return .chrome  // closest available
        case "google chrome", "chrome": return .chrome
        case "arc":                   return .arc
        case "brave browser":         return .brave
        case "microsoft edge":        return .edge
        case "terminal", "iterm", "iterm2": return .terminal
        default:                      return .file
        }
    }

    /// Enter acting mode for a result. The search bar's next Enter becomes
    /// an action intent (not a search). UI shows a context card with the
    /// result snippet so the user can see what they're acting on.
    func beginActing(on result: SearchResult) {
        actingOn = result
        composeState = nil
        query = ""
        results = []
        aiExplanation = nil
    }

    /// Called when the user submits an action intent in acting mode.
    /// Routes through SmartSearchService.planAction → fills composeState.
    func submitActionIntent() {
        guard let source = actingOn else { return }
        let intent = query.trimmingCharacters(in: .whitespaces)
        guard !intent.isEmpty else { return }

        let sourceContent = source.subtitle.isEmpty ? source.title : source.subtitle
        composeState = ComposeState(
            sourceSnippet: sourceContent, stage: .planning, kind: nil
        )

        Task { [smartService, whatsappService, discordService, imessageService] in
            let kind: ComposeKind
            do {
                kind = try await smartService.planAction(
                    intent: intent, sourceContent: sourceContent
                )
            } catch {
                // On planner failure, fall back to an empty message stub
                // so the user still sees a compose panel they can edit.
                self.composeState = ComposeState(
                    sourceSnippet: sourceContent,
                    stage: .ready,
                    kind: .sendMessage(MessageAction(
                        platform: .whatsapp,
                        recipientName: "",
                        content: sourceContent,
                        contactAvatar: nil
                    ))
                )
                return
            }

            // Enrich the message variant with a contact avatar; event
            // variant doesn't need enrichment beyond what the planner gave.
            let enriched: ComposeKind
            switch kind {
            case .sendMessage(var msg):
                msg.contactAvatar = await Self.resolveContactAvatar(
                    name: msg.recipientName,
                    platform: msg.platform,
                    whatsapp: whatsappService,
                    discord: discordService,
                    imessage: imessageService
                )
                enriched = .sendMessage(msg)
            case .createEvent:
                enriched = kind
            }
            self.composeState = ComposeState(
                sourceSnippet: sourceContent, stage: .ready, kind: enriched
            )
        }
    }

    func updateComposeContent(_ s: String) {
        guard var state = composeState, case .sendMessage(var msg) = state.kind else { return }
        msg.content = s
        state.kind = .sendMessage(msg)
        composeState = state
    }

    /// Field-by-field setters the CalendarComposeView uses to round-trip
    /// edits back into the published state.
    func updateEventTitle(_ s: String)        { updateEvent { $0.title = s } }
    func updateEventStartDate(_ d: Date)      { updateEvent { $0.startDate = d } }
    func updateEventDuration(_ n: Int)        { updateEvent { $0.durationMinutes = n } }
    func updateEventLocation(_ s: String)     { updateEvent { $0.location = s } }
    func updateEventNotes(_ s: String)        { updateEvent { $0.notes = s } }
    func updateEventAttendees(_ a: [String])  { updateEvent { $0.attendees = a } }

    private func updateEvent(_ mutate: (inout EventAction) -> Void) {
        guard var state = composeState, case .createEvent(var ev) = state.kind else { return }
        mutate(&ev)
        state.kind = .createEvent(ev)
        composeState = state
    }

    /// Confirm: ready → sending → sent → reset. Real-action paths:
    ///   - iMessage: AppleScript through Messages.app (Automation TCC).
    ///   - Event:    EventKit save to the default calendar (Calendar TCC).
    /// Other platforms are UI-only for now so the demo still flows.
    func confirmSend() {
        guard var state = composeState, state.stage == .ready,
              let kind = state.kind
        else { return }
        state.stage = .sending
        composeState = state

        let imsg = imessageService

        Task { @MainActor in
            var sentOk = true

            switch kind {
            case .sendMessage(let msg):
                if msg.platform == .imessage {
                    sentOk = await Self.sendIMessage(
                        recipientName: msg.recipientName,
                        content: msg.content,
                        service: imsg
                    )
                } else {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            case .createEvent(let ev):
                sentOk = await Task.detached {
                    do {
                        try await CalendarEventSaver.save(ev)
                        return true
                    } catch {
                        return false
                    }
                }.value
            }

            guard var s = composeState, s.stage == .sending else { return }
            s.stage = sentOk ? .sent : .ready   // fail = bounce back to editable
            composeState = s
            guard sentOk else { return }

            try? await Task.sleep(nanoseconds: 900_000_000)
            cancelCompose()
        }
    }

    /// Look up the recipient's iMessage handle by reusing the existing
    /// chat.db search — first message hit's `imessageChat(handle:)` carries
    /// the handle we need. Then drive Messages.app via AppleScript.
    private static func sendIMessage(
        recipientName: String,
        content: String,
        service: AppleMessagesService
    ) async -> Bool {
        guard !recipientName.isEmpty, !content.isEmpty else { return false }
        let results = await service.search(query: recipientName)
        // Pick the first result whose openTarget exposes a non-empty handle.
        var handle = ""
        for r in results {
            if case .imessageChat(let h, _) = r.openTarget, !h.isEmpty {
                handle = h
                break
            }
        }
        guard !handle.isEmpty else { return false }
        return await Task.detached {
            do {
                try IMessageSender.send(to: handle, text: content)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Discard the compose flow entirely and return to a clean search state.
    func cancelCompose() {
        composeState = nil
        actingOn = nil
        query = ""
        results = []
    }

    /// Best-effort avatar lookup. We do a quick `search(query: name)` on
    /// the appropriate service and pull `iconData` off the first hit that
    /// has one. Cheap (~50ms) and runs off the main actor.
    private static func resolveContactAvatar(
        name: String,
        platform: ComposePlatform,
        whatsapp: WhatsAppService,
        discord: DiscordService,
        imessage: AppleMessagesService
    ) async -> Data? {
        guard !name.isEmpty else { return nil }
        let results: [SearchResult]
        switch platform {
        case .whatsapp: results = await whatsapp.search(query: name)
        case .imessage: results = await imessage.search(query: name)
        case .discord:  results = await discord.search(query: name)
        case .mail:     return nil
        }
        return results.first(where: { $0.iconData != nil })?.iconData
    }

    func reset() {
        query = ""
        browserResults = []; fileResults = []; appResults = []
        whatsappResults = []; discordResults = []
        imessageResults = []; mailResults = []; notesResults = []
        clipboardResults = []; windowResults = []
        results = []; selectedIndex = 0
        isLoading = false; isAIThinking = false; aiExplanation = nil
        activeTab = .all
        composeState = nil; actingOn = nil
    }
}
