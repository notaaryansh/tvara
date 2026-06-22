# tvara architecture

How the launcher is wired end-to-end: what owns state, what runs on which
thread, what talks to what, and where the seams are.

Reading order: skim **§1 Mental model** to get the layer cake, then jump to
**§5 Data flow walkthroughs** for the "what happens when I type" view. Use
**§9 Module map** as a directory lookup table.

---

## 1. Mental model

Four layers, top to bottom:

```
┌──────────────────────────────────────────────────────────────────┐
│ SwiftUI Views                                                    │
│   SearchView · SearchResultRow · PhotoCollectionRow              │
│   ComposeView · CompactMessageRow · CategoryDeckView · …          │
│                          observes ▼ @ObservedObject              │
├──────────────────────────────────────────────────────────────────┤
│ SearchViewModel  (@MainActor, single instance)                    │
│   17 @Published result arrays · search routing · sectioning       │
│   compose flow · navigation state · 80ms smart-search debounce    │
│                       awaits ▼                                    │
├──────────────────────────────────────────────────────────────────┤
│ Service layer  (~25 services, mostly actors)                      │
│   ┌── Command sources (sync, @MainActor or stateless) ──┐         │
│   │  AppSearchService · WindowManagerService             │         │
│   │  SystemSettingsService · FoldersService              │         │
│   │  SystemActionsService                                │         │
│   ├── Content sources (async, actor) ───────────────────┤         │
│   │  AppleMessagesService · WhatsAppService              │         │
│   │  DiscordService · AppleMailService                   │         │
│   │  AppleNotesService · FileSearchService               │         │
│   │  ImageIndexService · ClipboardHistoryService         │         │
│   │  BrowserDatabaseService · NotionService              │         │
│   │  LinearService · SpotifyService                      │         │
│   ├── Cross-cutting ────────────────────────────────────┤         │
│   │  SmartSearchService (LLM planner)                    │         │
│   │  ContactsResolver · FrequencyReranker                │         │
│   │  IconCache · AppIconStore · EmbeddingStore           │         │
│   │  SelectionHistoryStore                               │         │
│   ├── Push ingestion (EventBus) ────────────────────────┤         │
│   │  EventBus · WorkerRunner                             │         │
│   │  Producers: IMessage · File · Image                  │         │
│   │  Workers: MessageIndex · FileIndex · ImageIndex      │         │
│   └────────────────────────────────────────────────────────┘       │
│                       reads/writes ▼                              │
├──────────────────────────────────────────────────────────────────┤
│ Data layer                                                        │
│   ~/Library/Application Support/tvara/                            │
│   ├── events.db          (EventBus queue)                         │
│   ├── images.db          (Vision labels · OCR · CLIP embeddings)  │
│   ├── app_icons.db       (pre-encoded app icon PNGs)              │
│   ├── files_recent.db    (FSEvents file metadata)                 │
│   ├── embeddings.db      (read-only Discord message vectors)      │
│   └── decoded_text/*     (per-source decoded message caches)      │
│                                                                   │
│ External:                                                         │
│   chat.db · WhatsApp ChatStorage · Discord cache · Mail envelope  │
│   ~/Pictures · ~/Desktop · ~/Downloads · ~/Documents              │
│   NSWorkspace · AppleScript · FSEvents · FoundationModels         │
│   Apple Vision · MobileCLIP-S2 (CoreML)                            │
└──────────────────────────────────────────────────────────────────┘
```

The arrows only point downward. Views never call services directly;
services never call into the ViewModel. The data layer never reaches
back up. This is enforced by Swift's actor isolation, not by convention.

---

## 2. Concurrency model

Three execution contexts. Knowing which is which prevents 80% of the bugs
you'd otherwise write.

### 2.1 MainActor — the SwiftUI side

Everything that needs to drive the UI lives here. `SearchViewModel` is
`@MainActor`, so all `@Published` writes are main-thread, which is what
SwiftUI requires.

The synchronous command services (`AppSearchService`, `WindowManagerService`,
`SystemSettingsService`, `FoldersService`, `SystemActionsService`) are also
on main. This is **deliberate**: they're alias-table lookups (~5 µs each)
where the cost of an actor hop would dominate the work. Putting them on
main lets the "spoti → Spotify" path render in the same frame as the
keystroke instead of a frame later.

Caching this:

- `AppSearchService` is `@MainActor` because hot-path search runs sync
  from `SearchViewModel.performSearch`. The expensive scan + icon decode
  happens in `refreshCacheIfNeeded` which spawns `Task.detached` for the
  CPU-heavy parts. See `Sources/tvara/Services/AppSearchService.swift`.

### 2.2 Actor executors — the service side

Every content service is an `actor`. Each owns its SQLite handle, file
descriptors, and in-memory caches. The actor's serial executor guarantees
no two queries against the same service ever race.

- `AppleMessagesService` (actor) — owns `imessage_index.db`, copies
  `chat.db`, decodes attributedBody.
- `WhatsAppService` (actor) — copies WhatsApp's ChatStorage.
- `DiscordService` (actor) — owns 6-table Discord cache index, walks
  Chromium cache.
- `ImageIndexService` (actor) — owns `images.db`, runs Vision +
  MobileCLIP inference.
- All others follow the same shape: actor owns its data, exposes
  `async` search.

### 2.3 Cooperative pool — the fan-out side

Most "do work then write back to main" happens in `Task.detached(priority: .utility)`.
The pattern looks like:

```swift
Task.detached { [weak self] in
    let results = await service.search(query: q, limit: 30)     // actor hop
    let history = await historyStore.lookup(results.compactMap(\.stableId))
    let reranked = FrequencyReranker.apply(to: results, history: history)
    await self?.assignSection(.discord, searchID: id, results: reranked)   // main hop
}
```

Three executor changes per Task: detached → actor → main. Each `await` is
a suspension point where the runtime can park the task and run something
else. The ViewModel's `searchID` counter guards the final main-actor write
— if the user has typed a new query mid-search, the stale write is
discarded.

### 2.4 The 80ms debounce

`SearchViewModel.performSearch` synchronously fires:

- Command sources (`match()` calls on main)
- Per-source array clears (`whatsappResults = []` etc.)

Then schedules an `inflightSmartTask = Task { … }` that sleeps 80ms before
calling the smart-search planner. A new keystroke cancels this task before
it wakes. **Commands are instant; content is debounced.** The split lives
in `Sources/tvara/ViewModels/SearchViewModel.swift:471-510`.

---

## 3. Views ↔ ViewModel contract

### 3.1 What flows up

Only user intent — typed query, arrow keys, Enter, Tab, Esc. Views never
mutate ViewModel state directly except through:

- `viewModel.query = …` (the `@Binding` on the TextField)
- `viewModel.cycleTab(forward:)`, `viewModel.advanceThumbSelection()`, etc.
  — public methods that take action verbs, not state mutations.
- `viewModel.activateSelected()` for Enter — the ViewModel owns the open
  dispatch.

### 3.2 What flows down

The 17 `@Published` result arrays + a handful of nav/state flags. Views
subscribe via `@ObservedObject` (no `@StateObject` — the ViewModel is
owned by `SearchWindowController`, which outlives any individual view).

Derived view-state lives on the ViewModel as **memoized computed
properties**:

- `blendedSections` — the sectioned merge of all 17 arrays. Cached in
  `blendedSectionsCache`, invalidated via `didSet` on every input array
  + `expandedSections` + `loadingSections`. Without the cache, SwiftUI
  body re-eval called this 4-5 times per re-eval × 10 re-evals per
  search wave = ~40 redundant runs of the 8-sort pipeline. With it: 10.
- `results` — flat list from `blendedSections.flatMap(\.items)` for the
  current tab. Free re-derivation since `blendedSections` is cached.

### 3.3 Compose flow (parallel sub-machine)

`SearchView` has two modes:

1. **Search mode** (default) — bubble shows search bar + results.
2. **Compose mode** — bubble shows the message/event editor.

Switching happens via `viewModel.beginActing(on: result)` (selection
captures the row you want to act on) and then `viewModel.submitActionIntent(…)`
(the LLM plans whether to send a message or create a calendar event).
The compose state is `viewModel.composeState: ComposeState?` and
`viewModel.actingOn: SearchResult?`. Search results are dropped while
acting — the two flows don't bleed into each other.

---

## 4. Service-by-service interactions

Services are grouped by what kind of work they do.

### 4.1 Command sources (sync, instant)

All four conform to the same shape: stateless or `@MainActor`, expose
`func match(query:) -> [SearchResult]`. They iterate small alias tables
in microseconds.

| Service | What it returns | Source of truth |
|---|---|---|
| `AppSearchService` | Installed `.app` bundles | In-memory cache, refreshed every 5 min via `mdfind` + dir walk |
| `WindowManagerService` | Window snap actions | 46 hardcoded aliases |
| `SystemSettingsService` | System Settings panes | 70 hardcoded aliases |
| `FoldersService` | Common ~/folders | 18 hardcoded aliases |
| `SystemActionsService` | Power/sleep/lock/screenshot | ~10 hardcoded aliases |

The hardcoded tables live as `private static let entries: [Entry]` in
each service file. `AppSearchService` is the only one with a real
warm-cache pipeline (see §4.6).

### 4.2 Content sources (async, actor)

All conform to `ContentSearchSource` (`Sources/tvara/Services/ContentSearchSource.swift`):

```swift
protocol ContentSearchSource: Sendable {
    func search(query: String, limit: Int) async -> [SearchResult]
}
```

`SearchViewModel.runKeywordSearch` iterates a list of `(BlendedSection.Kind, any ContentSearchSource)`
pairs and fans them out via `Task.detached`. Adding a new SQLite-backed
source is now `(kind, service)` — no per-source Task block needed.

| Service | Owns | Reads | Index location |
|---|---|---|---|
| `AppleMessagesService` | `imessage_index.db` (decoded_text) | `~/Library/Messages/chat.db` (copy) | Cache only |
| `WhatsAppService` | nothing persistent | `~/Library/Group Containers/…/ChatStorage.sqlite` (copy) | Read-only |
| `DiscordService` | 6-table cache index | Discord's Chromium cache files | Full index |
| `AppleMailService` | FTS5 envelope index | `~/Library/Mail/V*/Envelope Index` | Read-only + FTS mirror |
| `AppleNotesService` | nothing persistent | Notes group container db (copy) | Read-only |
| `FileSearchService` | nothing persistent | `mdfind` subprocess | Process pool of 1 |
| `ImageIndexService` | `images.db` (CLIP + Vision) | Filesystem | Full index |
| `ClipboardHistoryService` | clipboard history sqlite | `NSPasteboard` polling | Owns it |
| `BrowserDatabaseService` | nothing persistent | Chrome/Arc/Brave/Edge history dbs (copy) | Read-only |
| `NotionService` / `LinearService` / `SpotifyService` | nothing persistent | HTTP APIs | Stateless |

### 4.3 SmartSearchService — the LLM planner

`SmartSearchService` (actor) is the brain that decides "this isn't keyword
search, plan a query." Called from `SearchViewModel` after the 80ms
debounce when the query is sentence-like (>5 chars, ≥4 words).

Pipeline:

1. **Heuristic gate** — `shouldUseSmartSearch(query:)` decides if it's worth
   asking the LLM. Cheap keyword queries skip this entirely.
2. **Planner** — `plan(query:)` returns a `QueryPlan`: which source to
   search, what the keywords actually are, named contact, time window.
   Uses Apple's FoundationModels (`SystemLanguageModel`) on macOS 26+. The
   OpenAI fallback has been removed; if FM is unavailable the planner
   throws and the ViewModel falls back to keyword search.
3. **Action planner** — `planAction(intent:sourceContent:)` decides if a
   compose action is a message-send or a calendar event. Used by the
   compose flow only, not search.

### 4.4 ContactsResolver — name → user_id

Cross-cutting service that resolves a planner-given contact name ("drish")
to the underlying contact identifiers (phone number, Discord user_id, etc.).
The key insight from `feedback_contact_vs_content.md`: when the planner
returns `contact:`, you filter on the FK column, never on content LIKE.

### 4.5 FrequencyReranker — selection history bump

`SelectionHistoryStore` (actor) records every Enter the user presses
(`recordSelection(chosenId:visibleIds:)`). When the same row appears again
in a future search, `FrequencyReranker.apply(to:history:)` bumps its rank.
This is invisible chrome — happens inside every per-source `Task.detached`
in the keyword fan-out.

### 4.6 Icon caches — IconCache vs AppIconStore

Two layers, deliberately:

- **`AppIconStore`** (actor, on disk) — SQLite at
  `~/Library/Application Support/tvara/app_icons.db`. PNG bytes keyed by
  `(path, bundle_mtime)`. Encoded once at warm time via ImageIO at 64×64.
  Survives app restarts so the second launch onward renders icons in the
  same frame as the row.
- **`IconCache`** (@MainActor, in-memory) — `[String: NSImage]`. Used by
  `FileIconView` for non-app file rows (Notes, files, settings). Pre-warmed
  in the background; first row render of a cached path is no-decode-on-draw.

App rows now bypass `IconCache` entirely — `AppEntry.iconData` carries the
PNG bytes through to `SearchResult.iconData`, and `SearchResultRow` renders
`NSImage(data:)` directly.

---

## 5. Data flow walkthroughs

### 5.1 User types "spoti"

```
Keystroke
   │
   ▼
SearchView TextField  →  $viewModel.query = "spoti"
   │
   ▼  (Combine sink on main)
SearchViewModel.performSearch("spoti")
   │
   ├──► windowService.match("spoti")     ───►  []     (sync, ~5 µs)
   ├──► settingsService.match("spoti")   ───►  []
   ├──► folderService.match("spoti")     ───►  []
   ├──► systemActionsService.match("spoti") ►  []
   ├──► appService.match("spoti")        ───►  [Spotify] (sync, ~50 µs)
   │       │
   │       └─► writes appResults = [Spotify]  → SwiftUI re-render
   │
   └──► inflightSmartTask = Task {
          sleep(80ms)
          if not cancelled:
              if smart-heuristic passes:
                  smartService.plan(query)  →  routeSmartSearch
              else:
                  runKeywordSearch(query)
        }

  ┌─► First frame: row for "Spotify" renders with icon from AppEntry.iconData
  └─► 80ms later: content fan-out begins (11 Task.detached per source)
```

Frame budget: ~5ms on main for the sync command pass. The 80ms debounce
collapses a typing burst into a single content fan-out instead of N.

### 5.2 User types "address i sent to drish"

```
Keystroke
   │
   ▼
performSearch("address i sent to drish")
   │
   ├──► commands return [] (no matches)
   │
   ▼
inflightSmartTask:
   sleep(80ms)
   smartService.plan(...)
   │
   ▼   QueryPlan {
   │     source: .messages,
   │     keywords: ["address"],
   │     contact: "drish",
   │     timeWindow: nil
   │   }
   ▼
routeSmartSearch(plan):
   │
   ├─► whatsappService.search("drish")
   ├─► discordService.messagesInvolving(contactName: "drish")
   │     │
   │     └─► ContactsResolver → user_id 1234567
   │     └─► messages WHERE author_id = 1234567 OR mention = 1234567
   │
   ├─► imessageService.search("drish")
   │
   └─► filter each set by keywords containing "address"
       │
       └─► If Discord results have embeddings:
           semanticRerank(query: "address i sent to drish", candidates)
           via EmbeddingStore.vectors(forDiscordMessages:)
```

The Discord semantic rerank path is the one place where embeddings
flow. Other sources use keyword + frequency reranker only.

### 5.3 A new iMessage arrives (push ingestion)

```
chat.db gains ROWID 50001
   │
   ▼  (poll every 5s)
IMessageProducer.tick:
   service.fetchNewRowIds(since: 50000)  →  [50001]
   bus.enqueue(
     type: "message_added",
     payload: { rowid: 50001 },
     dedupeKey: "imessage:50001"
   )
   lastEmittedRowId = 50001
   │
   ▼  (within ~3s, the next claim)
MessageIndexWorker.processBatch([event 50001]):
   imessage.indexRowIds([50001])
     │
     └─► copies chat.db to temp
     └─► SELECT attributedBody WHERE ROWID = 50001
     └─► decodes archived NSAttributedString
     └─► INSERT OR REPLACE INTO decoded_text
     └─► writeLastMessageId(50001)
   │
   ▼
bus.complete(id: event.id)
```

This is the push path. The legacy path (`AppleMessagesService.refreshIfNeeded`)
still runs on the next search if `EventBusConfig.legacyPullRefreshEnabled = true`,
which it is. Both paths write the same `decoded_text` table idempotently
via INSERT OR REPLACE.

### 5.4 User presses Enter on a row

```
Enter
   │
   ▼
SearchView.handleEnter()  →  viewModel.activateSelected()
   │
   ▼
SearchViewModel.open(result):
   │
   ├─► historyStore.recordSelection(chosenId, visibleIds)
   │     (rank bump for next time this row appears)
   │
   └─► switch result.openTarget {
         case .file(path)         →  NSWorkspace.open(URL(fileURLWithPath: path))
         case .url(s)             →  NSWorkspace.open(URL(string: s)!)
         case .whatsappChat(...)  →  open whatsapp:// URL + AX focus
         case .imessageChat(...)  →  open imessage:// URL
         case .copyToClipboard(s) →  NSPasteboard.general.setString
         case .notesNote(...)     →  AppleScript activates Notes.app
         case .spotifyPlay(...)   →  SpotifyPlayer (AppleScript)
         case .windowAction(a)    →  WindowManagerService.execute(a)
         case .systemAction(a)    →  SystemActionsService.execute(a)
         case .imagesCollection   →  zoom into Images tab
         case .expandSection      →  toggleSectionExpanded
       }
```

The ViewModel is the only dispatcher. No view ever opens a URL directly.

---

## 6. Persistence layer

Every SQLite database in the project lives in
`~/Library/Application Support/tvara/`. Each has a single owning actor.

| Database | Owner | Schema | Read pattern | Write pattern |
|---|---|---|---|---|
| `events.db` | `EventBus` | events queue with status/attempts/backoff/dedupe | Workers claim atomically | Producers enqueue |
| `images.db` | `ImageIndexService` | images + labels + image_labels + FTS5(ocr) | Search: cosine over all rows + BM25 over FTS | Indexer: per-image after Vision/CLIP |
| `app_icons.db` | `AppIconStore` | (path, bundle_mtime, png) | Bulk fetch all paths at warm | Insert/replace on cache miss |
| `files_recent.db` | `FileIndexService` | path/basename/kind/size/mtime/added_at | Not yet wired into search | Worker upserts on FSEvent |
| `embeddings.db` | `EmbeddingStore` | (message_id, source, model, embedding BLOB) | Discord rerank pool | **Read-only** — built by `scripts/embed_messages.py` |
| `imessage_index.db` | `AppleMessagesService` | decoded_text(message_id, text) + metadata | Search joins this against chat.db | Both legacy refresh + queue worker write |
| `discord_cache_index.db` | `DiscordService` | 6 tables: guilds/channels/users/messages/avatars/guild_icons | Search + rerank pool | Periodic cache scan |

Read-only copies (OS-owned, copied at query time to a temp path):

- `chat.db` (`AppleMessagesService.copyChatDb`)
- WhatsApp `ChatStorage.sqlite` (`WhatsAppService`)
- Discord's Chromium cache files (raw read, not SQLite)
- Browser histories (`BrowserDatabaseService` — Chrome / Arc / Brave / Edge)

Each copy path follows the same shape (`copyItem` source + `-wal` + `-shm`,
defer cleanup). This is the #1 candidate for an extracted utility — see
the audit recommendations in `docs/refactor-plan.md`.

---

## 7. EventBus push pipeline

The newest subsystem. Replaces the "refresh on next search" pattern for
sources where push is feasible. Lives in `Sources/tvara/Services/EventBus/`.

### 7.1 Pieces

- **`EventBus`** (actor) — durable queue over SQLite. Methods:
  `enqueue` (throws on real failure, returns id or nil-on-dedupe),
  `claim` (atomic flip to processing), `complete` / `fail` (the latter
  with exponential backoff capped at 5 min, finalises as `failed` after
  5 attempts).
- **`Event`** — row from `claim`: id, type, source, payload (JSON
  string), attempts, enqueuedAt.
- **`EventWorker`** protocol — `eventType`, `batchSize`, `pollInterval`,
  `processBatch(_:) async -> [BatchResult]`. Default `processBatch` loops
  `process(_:)` per event; workers that benefit from amortized setup
  (e.g. one chat.db copy per claim) override `processBatch`.
- **`WorkerRunner`** (actor) — runs a worker against the bus in a
  detached Task. Loop: claim → processBatch → complete/fail. Cancellation
  honoured at next claim boundary (finalises all in-flight events first).
- **`EventBusPipeline`** — owns every producer, worker, and runner so they
  outlive their setup closure. Held as a property on `SearchViewModel`.

### 7.2 Producers

| Producer | Source signal | Dedupe key | Emits |
|---|---|---|---|
| `IMessageProducer` | chat.db ROWID poll every 5s | `imessage:<rowid>` | `message_added` |
| `FileProducer` | FSEvents on ~/Downloads, ~/Desktop, ~/Documents | `fs:<path>:<mtime_µs>` | `file_added` |
| `ImageProducer` | FSEvents on ~/Pictures, ~/Desktop, ~/Downloads | `img:<path>:<mtime_µs>` | `image_added` |

The mtime-µs bucket in the dedupe key matters: a path-only key would
permanently suppress all future re-saves of the same file. The
microsecond resolution catches APFS-precision back-to-back saves that
second-level bucketing would silence.

### 7.3 Workers

| Worker | Event type | Delegates to | batchSize |
|---|---|---|---|
| `MessageIndexWorker` | `message_added` | `AppleMessagesService.indexRowIds` | 100 (chat.db copy amortized) |
| `FileIndexWorker` | `file_added` | `FileIndexService.upsert` | 50 |
| `ImageIndexWorker` | `image_added` | `ImageIndexService.indexPath` | 5 (CoreML inference is heavy) |

### 7.4 Current dual-mode

`EventBusConfig.legacyPullRefreshEnabled = true`. While this flag is true,
the legacy `AppleMessagesService.refreshIfNeeded` (called from every
search) **also** runs alongside the producer. Both paths write the same
decoded_text table idempotently. The flag exists so we can flip it off
once the queue has proven itself in production.

Only one source (iMessage) is in dual-mode today. Files and Images are
queue-only — the file/image services were never on the pull path.

### 7.5 What's not yet on the queue

- Discord — `DiscordService.refreshIfNeeded` still runs on every search.
- WhatsApp — no producer; queries copy ChatStorage on-demand.
- Mail — `AppleMailService.refreshIfNeeded` on every search.
- Notes, Clipboard — never had refreshIfNeeded; not strictly queue
  candidates (Clipboard self-polls via NSPasteboard).

Roadmap and exit plan (when to flip the flag): `docs/event-queue-plan.md`.

---

## 8. Key invariants & gotchas

### 8.1 The `searchID` guard

Every async writeback to a `@Published` array is gated by
`guard searchID == currentSearchID else { return }`. A new keystroke bumps
`currentSearchID`, so any stale fan-out lands and is silently dropped.
**Never write a `@Published` from a Task.detached without this check.**

### 8.2 The `rank` field owns final order

`SearchResult.rank: Int` is the single sortable key. After every merge or
rerank step the ViewModel re-sorts by `rank` (see
`feedback_rank_field_owns_ordering.md`). Any reranker that wants its
ordering to stick **must** overwrite `rank`. Producing a returned-in-the-right-order
array is not enough — it'll get re-sorted and silently reverted.

### 8.3 Contact filters → user_id, not content

When the smart-search planner returns `contact:`, resolve via
`ContactsResolver` to a stable user identifier and filter on the FK column.
**Never** filter on `content LIKE '%name%'` — that only matches messages
whose text contains the name, which is not what "messages with drish" means.
See `feedback_contact_vs_content.md`.

### 8.4 chat.db is OS-owned

Never open `~/Library/Messages/chat.db` directly. Copy it to a temp path,
along with `-wal` and `-shm` siblings, then open the copy read-only.
Failing to copy WAL means missing the most recent (uncommitted) messages.
The same pattern applies to WhatsApp's ChatStorage and the browser history
databases.

### 8.5 The 17 @Published arrays are not duplication

Every per-source result array is its own `@Published` because each source
lands asynchronously and writes independently. They're the contract between
the per-source `Task.detached` and SwiftUI, not redundant state. Don't try
to "consolidate" them into a single `[SearchResult]` — you'll lose the
per-section streaming UX (apps land at 5ms, images keeps spinning until
300ms).

### 8.6 IconData vs FileIconView

App rows ship pre-encoded PNG bytes in `SearchResult.iconData` and render
via `NSImage(data:)` synchronously. Non-app file rows (Notes, files,
settings) use `FileIconView` which reads from `IconCache` (in-memory
NSImage cache). **Both paths exist on purpose** — `IconCache` handles the
arbitrary-path file case where pre-encoding isn't viable.

---

## 9. Module map

A directory tour. Open files in this order if you're new to the project.

```
Sources/tvara/
│
├── SpotlightApp.swift              — app entry, status bar item, hot-key
├── Models/
│   ├── SearchResult.swift          — the single result type used everywhere
│   ├── SearchResult+StableId.swift — stable id for frequency reranker
│   ├── SystemAction.swift          — system action enum
│   └── WindowAction.swift          — window action enum
│
├── ViewModels/
│   └── SearchViewModel.swift       — THE orchestrator (~1850 lines)
│
├── Views/
│   ├── SearchView.swift            — main bubble
│   ├── SearchResultRow.swift       — per-row renderer (handles every source)
│   ├── PhotoCollectionRow.swift    — horizontal thumb strip
│   ├── CompactMessageRow.swift     — one-line message row for blended view
│   ├── ComposeView.swift           — message + event editor
│   ├── CategoryDeckView.swift      — Tab navigation deck
│   ├── SeeMoreRow.swift            — per-section "+ N more" footer
│   ├── TabStripView.swift          — top tab strip
│   ├── VisualEffectView.swift      — NSVisualEffectView wrapper
│   └── WindowActionPreview.swift   — schematic window preview
│
├── Services/
│   ├── (command sources — sync match() on main)
│   │   ├── AppSearchService.swift          ← warm-cache + AppIconStore
│   │   ├── WindowManagerService.swift
│   │   ├── SystemSettingsService.swift
│   │   ├── FoldersService.swift
│   │   └── SystemActionsService.swift
│   │
│   ├── (content sources — actor + async search)
│   │   ├── AppleMessagesService.swift      ← dual-mode (legacy + queue)
│   │   ├── WhatsAppService.swift
│   │   ├── DiscordService.swift
│   │   ├── AppleMailService.swift
│   │   ├── AppleNotesService.swift
│   │   ├── FileSearchService.swift
│   │   ├── ImageIndexService.swift          ← Vision + MobileCLIP
│   │   ├── ClipboardHistoryService.swift
│   │   ├── BrowserDatabaseService.swift
│   │   ├── NotionService.swift
│   │   ├── LinearService.swift
│   │   ├── SpotifyService.swift / SpotifyPlayer.swift
│   │   └── TerminalHistoryService.swift
│   │
│   ├── (cross-cutting)
│   │   ├── ContentSearchSource.swift        ← the protocol
│   │   ├── SmartSearchService.swift         ← FoundationModels planner
│   │   ├── ContactsResolver.swift
│   │   ├── FrequencyReranker.swift
│   │   ├── SelectionHistoryStore.swift
│   │   ├── IconCache.swift                  ← in-memory NSImage cache
│   │   ├── AppIconStore.swift               ← on-disk PNG cache
│   │   ├── EmbeddingStore.swift             ← read-only Discord vectors
│   │   ├── HotKeyManager.swift
│   │   ├── PermissionsBootstrap.swift
│   │   ├── SearchWindowController.swift     ← owns SearchViewModel
│   │   ├── TextSelectionCapture.swift       ← compose: capture from frontmost
│   │   └── WindowSnapOverlayController.swift
│   │
│   ├── EventBus/                            ← push ingestion pipeline
│   │   ├── EventBus.swift                   ← the SQLite queue
│   │   ├── EventBusConfig.swift             ← legacyPullRefreshEnabled
│   │   ├── EventBusPipeline.swift           ← owns producers + workers
│   │   ├── EventTypes.swift                 ← payload types
│   │   ├── EventWorker.swift                ← protocol + WorkerRunner
│   │   ├── FSEventsWatcher.swift            ← FSEvents wrapper
│   │   ├── IMessageProducer.swift
│   │   ├── FileProducer.swift
│   │   ├── ImageProducer.swift
│   │   ├── MessageIndexWorker.swift
│   │   ├── FileIndexWorker.swift
│   │   ├── ImageIndexWorker.swift
│   │   └── FileIndexService.swift           ← files_recent.db owner
│   │
│   ├── CLIP/                                ← MobileCLIP-S2 tokenizer + models
│   ├── ChromiumCacheParser.swift            ← Discord cache files
│   └── EmlxParser.swift                     ← Mail .emlx files
│
├── Actions/                                 ← compose action types
├── Utils/                                   ← FuzzyMatch, etc.
└── Resources/
```

---

## 10. Where to look when…

| Symptom | Start here |
|---|---|
| Search feels laggy on typing | `SearchViewModel.performSearch` + `blendedSections` memoization |
| Icons pop in late | `AppIconStore` warm path + `SearchResultRow` `.file` branch |
| A new message doesn't appear until I search | `IMessageProducer.tick` + `MessageIndexWorker` + the `legacyPullRefreshEnabled` flag |
| A planner-returned source is wrong | `SmartSearchService.plan` + `routeSmartSearch` in the ViewModel |
| Ranking feels off | Check `rank` field on every reranker; `FrequencyReranker.apply` and the final sort in `blendedSections` |
| Compose flow misbehaves | `composeState` / `actingOn` on the ViewModel + `ComposeView` |
| A new SQLite db is misbehaving | Owner actor's `ensureOpen` / `createSchema` — error handling is inconsistent across services |
| FSEvents not firing | `FSEventsWatcher.start` — checks `FSEventStreamStart` return value; logs on failure |

---

## 11. Companion docs

- `docs/PERFORMANCE.md` — latency budgets, storage costs, scaling
  characteristics per source.
- `docs/event-queue-plan.md` — original EventBus design + migration
  phases + exit plan for the legacy flag.
- `docs/refactor-plan.md` — extraction backlog from the most recent
  architecture audit (SQLiteDatabase abstraction, FSEventsProducer base,
  Debouncer, ResultMerger).
- `docs/reranker-plan.md` — semantic rerank design (Discord-specific).
- `docs/DISCORD_IPC.md` — Discord cache parsing notes.
