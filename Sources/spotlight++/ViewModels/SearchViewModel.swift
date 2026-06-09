import AppKit
import Combine
import Foundation

enum SearchTab: String, CaseIterable, Hashable {
    case all
    case messages   // iMessage + WhatsApp + Discord merged
    case mail
    case apps
    case files
    case images
    case clipboard
    case notes

    var label: String {
        switch self {
        case .all:       return "All"
        case .messages:  return "Messages"
        case .mail:      return "Mail"
        case .apps:      return "Apps"
        case .files:     return "Files"
        case .images:    return "Images"
        case .clipboard: return "Clipboard"
        case .notes:     return "Notes"
        }
    }

    var icon: String {
        switch self {
        case .all:       return "square.grid.2x2.fill"
        case .messages:  return "bubble.left.and.bubble.right.fill"
        case .mail:      return "envelope.fill"
        case .apps:      return "app.fill"
        case .files:     return "folder.fill"
        case .images:    return "photo.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notes:     return "note.text"
        }
    }
}

/// Top-level UI mode for the results area. Replaces the old pill-strip
/// navigation — categories are reached via Tab (deck) → Enter (zoom), not
/// by clicking a pill.
enum ResultsViewMode: Equatable {
    case blended       // single ranked list of everything
    case deck          // category cards
    case zoomed        // single category's full list (uses activeTab)
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
    @Published private(set) var settingsResults: [SearchResult] = []
    @Published private(set) var folderResults: [SearchResult] = []
    @Published private(set) var systemActionResults: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isAIThinking: Bool = false
    @Published private(set) var aiExplanation: String? = nil
    @Published var activeTab: SearchTab = .all {
        didSet { if oldValue != activeTab { selectedIndex = 0 } }
    }

    /// Top-level UI mode: blended list → category deck (Tab) → zoomed
    /// category list (Enter on a card). Esc walks back up the stack.
    @Published var viewMode: ResultsViewMode = .blended
    /// Cursor within the category-deck view. Independent of `selectedIndex`
    /// so leaving and re-entering the deck doesn't reset list selection.
    @Published var selectedCardIndex: Int = 0

    /// Single source of truth for what the result list shows. Computed
    /// fresh from the @Published backing arrays + activeTab on every
    /// access — there's intentionally no cached `results` field, because
    /// caching it (which we used to do) inevitably drifted out of sync
    /// with `count(for:)` and produced the "All 3 / No matches" bug.
    /// SwiftUI re-renders any view that reads `results` on any @Published
    /// change of the object, so this stays reactive for free.
    var results: [SearchResult] {
        switch activeTab {
        case .all:
            return Array(allMerged().prefix(Self.allTabResultCap))
        case .messages:
            return Array(messagesMerged().prefix(Self.messagesTabResultCap))
        case .mail:
            return mailResults
        case .apps:
            return appResults.sorted(by: rankSort)
        case .files:
            return fileResults.sorted(by: rankSort)
        case .images:
            return imageResults
        case .clipboard:
            return clipboardResults
        case .notes:
            return notesResults
        }
    }

    /// Set true when the current query exactly matches a command alias
    /// (window action, settings pane, folder shortcut, or installed app
    /// name). Drives the allMerged filter — content sources (messages,
    /// mail, notes, files, images, clipboard, browser) are excluded while
    /// this is set, so typing "top right" doesn't surface random image
    /// hits alongside the actual command.
    @Published private(set) var commandExclusivity: Bool = false

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
    private let settingsService: SystemSettingsService
    private let folderService: FoldersService
    private let systemActionsService: SystemActionsService
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
        settingsService: SystemSettingsService = SystemSettingsService(),
        folderService: FoldersService = FoldersService(),
        systemActionsService: SystemActionsService = SystemActionsService(),
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
        self.settingsService = settingsService
        self.folderService = folderService
        self.systemActionsService = systemActionsService
        self.smartService = smartService
        self.embeddingStore = embeddingStore

        // v0 fires performSearch on EVERY keystroke — no debounce. The
        // command sources are sync alias-table loops (~5 µs each), so
        // debouncing was pure perceived latency with zero throughput
        // benefit. When content search is re-enabled, the right shape
        // is to split this into two pipelines: an immediate one for
        // commands and a debounced one (150-250 ms) for the API-heavy
        // content fan-out. For now we just want it instant.
        $query
            .removeDuplicates()
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
        case .apps:      return appResults.count
        case .files:     return fileResults.count
        case .images:    return imageResults.count
        case .clipboard: return clipboardResults.count
        case .notes:     return notesResults.count
        }
    }

    // MARK: - Search

    /// Minimum query length before ANY source runs. Single-letter queries
    /// like `s` returned 30+ matches across apps/settings/files — visual
    /// noise the user can't realistically pick from. Forcing 3 characters
    /// before matching trades a 2-keystroke delay for a focused list.
    /// Exposed publicly so SearchView can also gate UI chrome (tab strip,
    /// results area) on the same threshold and not just live-update
    /// state silently.
    static let minimumQueryLengthForUI = 3
    private static var minimumQueryLength: Int { minimumQueryLengthForUI }

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Treat anything below the minimum length the same as empty —
        // clears everything and shows the empty state. Avoids the
        // "typed `s`, got 30 things" problem.
        guard trimmed.count >= Self.minimumQueryLength else {
            browserResults = []; fileResults = []; appResults = []
            whatsappResults = []; discordResults = []
            imessageResults = []; mailResults = []; notesResults = []
            notionResults = []; linearResults = []; spotifyResults = []
            clipboardResults = []; imageResults = []; windowResults = []
            settingsResults = []; folderResults = []
            systemActionResults = []
            selectedIndex = 0; selectedCardIndex = 0
            viewMode = .blended
            activeTab = .all
            isLoading = false; isAIThinking = false; aiExplanation = nil
            commandExclusivity = false
            return
        }

        // ── v0 scope ─────────────────────────────────────────────────
        // The launcher only surfaces commands + apps + folders + settings.
        // Content sources (messages/mail/notes/files/images/clipboard/
        // browser history) stay in the codebase intact — services are
        // still constructed, properties still exist — but are not queried
        // or merged here. Flip `Self.contentSearchEnabled = true` when
        // we're ready to bring content search back into the UI.
        windowResults        = windowService.match(query: trimmed)
        settingsResults      = settingsService.match(query: trimmed)
        folderResults        = folderService.match(query: trimmed)
        systemActionResults  = systemActionsService.match(query: trimmed)

        // Clear EVERY @Published source array SYNCHRONOUSLY so the merged
        // view doesn't briefly show stale results from the previous query
        // while new ones stream in. Each per-source Task below overwrites
        // its own array as it lands; nothing else mutates the others, so
        // the streaming wave can't accidentally clobber a sibling.
        appResults = []; fileResults = []; browserResults = []
        whatsappResults = []; discordResults = []; imessageResults = []
        mailResults = []; notesResults = []; notionResults = []
        linearResults = []; spotifyResults = []; clipboardResults = []
        imageResults = []
        selectedIndex = 0
        selectedCardIndex = 0
        aiExplanation = nil

        currentSearchID &+= 1
        let searchID = currentSearchID
        isLoading = true

        // v0 commands-only path: apps + folder-filtered files only. Same
        // shape as before — apps come from in-process FileManager (~5 ms),
        // files come from mdfind (50-500 ms) but are filtered to folder
        // rows so the deck card is small + scannable.
        if !Self.contentSearchEnabled {
            Task { [searchID] in
                let apps = await self.appService.search(query: trimmed)
                guard searchID == self.currentSearchID else { return }
                self.appResults = apps
                self.isAIThinking = false
                self.isLoading = false
            }
            Task { [searchID] in
                let files = await self.fileService.search(query: trimmed)
                guard searchID == self.currentSearchID else { return }
                self.fileResults = files.filter { $0.source == .folder }
            }
        }

        // Cancel any in-flight smart task from a previous query so it
        // doesn't quietly land late and toggle UI state.
        inflightSmartTask?.cancel()

        if Self.contentSearchEnabled {
            // ── content search (DISABLED FOR v0) ─────────────────────
            // Kept here verbatim so re-enabling is one flag-flip away.
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
            let smart = smartService
            let heuristic = smart.shouldUseSmartSearch(query: trimmed)
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
    }

    /// Feature flag — when true, the ViewModel falls back to its full
    /// content-search fan-out (messages, mail, notes, files, images,
    /// clipboard, browser, smart search). Flipped back to true for the
    /// category-deck UX experiment so we can see how mixed-source results
    /// look in the new deck/zoom layout.
    private static let contentSearchEnabled = true

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
        self.selectedIndex = 0
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

        // Apps exclusivity arrives late because the cache lookup is async.
        // If the typed query exactly matches an installed app name and we
        // didn't already lock in exclusivity from a window/settings/folder
        // hit, lock it now so content sources drop on this render.
        if !commandExclusivity {
            let exact = await appService.hasExactNameMatch(query: query)
            guard searchID == currentSearchID else { return }
            if exact { commandExclusivity = true }
        }

        self.selectedIndex = 0
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
            self.selectedIndex = 0
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
            self.selectedIndex = 0
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
        // Commands + apps + every content source we surface. Used by both
        // the blended-list view (current main UX) and the count badge on
        // the All deck card. Terminal results are intentionally excluded.
        var all: [SearchResult] = []
        all.append(contentsOf: appResults)
        all.append(contentsOf: windowResults)
        all.append(contentsOf: settingsResults)
        all.append(contentsOf: folderResults)
        all.append(contentsOf: fileResults)
        all.append(contentsOf: systemActionResults)
        if Self.contentSearchEnabled {
            all.append(contentsOf: whatsappResults)
            all.append(contentsOf: imessageResults)
            all.append(contentsOf: discordResults)
            all.append(contentsOf: mailResults)
            all.append(contentsOf: notesResults)
            all.append(contentsOf: notionResults)
            all.append(contentsOf: linearResults)
            all.append(contentsOf: spotifyResults)
            all.append(contentsOf: clipboardResults)
            all.append(contentsOf: imageResults)
            all.append(contentsOf: browserResults)
        }

        // Fuzzy suppression: if ANY non-fuzzy match exists in the merged
        // set, drop all fuzzy matches. Fuzzy is a typo-tolerant fallback
        // — it should only be visible when nothing else matched at all.
        // Keeps "shirim" from listing Siri alongside the real shirim
        // folder.
        if all.contains(where: { !$0.isFuzzyMatch }) {
            all.removeAll(where: { $0.isFuzzyMatch })
        }
        return all.sorted(by: rankSort)
    }

    // MARK: - Category deck

    /// One card per non-empty content category. Always-on commands
    /// (apps, window snaps, system settings, etc.) stay folded into the
    /// blended list and don't get their own card — the deck is about
    /// surfacing the *content* dimensions of a query (your messages,
    /// your files, your photos), not the launcher commands.
    struct CategoryCard: Identifiable, Hashable {
        let tab: SearchTab
        let count: Int
        let topPreview: SearchResult?
        var id: SearchTab { tab }
    }

    var categoryCards: [CategoryCard] {
        var cards: [CategoryCard] = []
        func add(_ tab: SearchTab, _ results: [SearchResult]) {
            guard !results.isEmpty else { return }
            cards.append(CategoryCard(
                tab: tab,
                count: results.count,
                topPreview: results.sorted(by: rankSort).first
            ))
        }
        add(.apps, appResults)
        add(.files, fileResults)
        let msgs = messagesMerged()
        if !msgs.isEmpty {
            cards.append(CategoryCard(
                tab: .messages, count: msgs.count,
                topPreview: msgs.first
            ))
        }
        add(.mail, mailResults)
        add(.notes, notesResults)
        add(.images, imageResults)
        add(.clipboard, clipboardResults)
        return cards
    }

    // MARK: - Mode transitions (Tab / Esc / Enter from deck)

    /// Tab toggles the deck. From inside a zoomed category Tab steps back
    /// up to the deck so the user can pick another category without
    /// having to Esc-then-Tab.
    func toggleDeck() {
        guard !categoryCards.isEmpty else { return }
        switch viewMode {
        case .blended:
            viewMode = .deck
            selectedCardIndex = 0
        case .deck:
            viewMode = .blended
        case .zoomed:
            viewMode = .deck
        }
    }

    /// Zoom into the currently-highlighted card. No-op when the cursor
    /// is out of bounds (e.g. the card under it just disappeared because
    /// results re-ranked while the deck was open).
    func zoomSelectedCard() {
        let cards = categoryCards
        guard cards.indices.contains(selectedCardIndex) else { return }
        activeTab = cards[selectedCardIndex].tab
        viewMode = .zoomed
        selectedIndex = 0
    }

    /// Vertical arrow navigation within the deck.
    func moveCardSelection(by delta: Int) {
        let cards = categoryCards
        guard !cards.isEmpty else { return }
        selectedCardIndex = min(max(selectedCardIndex + delta, 0), cards.count - 1)
    }

    /// Whether Esc was consumed by a layer-pop. False means the window
    /// controller should dismiss the panel (we ran out of layers).
    enum EscapeOutcome { case handled, dismiss }

    /// Hierarchical Esc:
    ///   zoomed → deck
    ///   deck → blended
    ///   blended + query → clear query
    ///   blended + empty → dismiss
    func handleEscape() -> EscapeOutcome {
        switch viewMode {
        case .zoomed:
            viewMode = .deck
            return .handled
        case .deck:
            viewMode = .blended
            return .handled
        case .blended:
            if !query.isEmpty {
                query = ""
                return .handled
            }
            return .dismiss
        }
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

    // `results` is computed (see top of file). Selection reset is handled
    // explicitly at each call site that previously called
    // syncDisplayedResults(resetSelection: true).

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

        case .systemAction(let action):
            // NSAppleScript dispatch runs on a detached task inside the
            // service; we return true immediately so the panel dismisses.
            // Shut down / restart / log out trigger macOS' own 60-second
            // confirmation dialog, so there's no extra safety prompt
            // needed from our side.
            return systemActionsService.execute(action)
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
        // `results` is computed off backing arrays; clearing query already
        // empties them via performSearch's empty branch.
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
        settingsResults = []; folderResults = []
        systemActionResults = []
        selectedIndex = 0; selectedCardIndex = 0
        viewMode = .blended
        isLoading = false; isAIThinking = false; aiExplanation = nil
        commandExclusivity = false
        activeTab = .all
        composeState = nil; actingOn = nil
    }
}
