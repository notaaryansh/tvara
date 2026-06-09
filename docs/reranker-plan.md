# Frequency Reranker — Plan & Checklist

## Goal

Add a usage-aware reranker that learns from explicit user selections. Every
selection is a pairwise statement: "I prefer this result, out of the ones
shown." The chosen result's score goes up; the other top-3 visible results
go down. Bounded at cap=3, floor=0 so misclicks recover fast and stale
preferences fade as you change habits.

## Behaviour (locked-in spec)

- **Storage**: one row per `stable_result_id`. SQLite at
  `~/Library/Application Support/spotlight++/selection_history.db`.
- **On Enter / Cmd+Enter (with query >= 2 chars)**:
  - chosen result: `count = min(3, count + 1)`, `last_selected_at = now`
  - top-3 visible results (excluding chosen): `count = max(0, count - 1)`
- **At query time** (per search):
  - lookup history for every candidate's stable_id
  - sort: `(count DESC, last_selected_at DESC, base_rank DESC)` — within
    band only, never lets frequency cross a band boundary
- **Blacklisted source types** (never tracked, never boosted): `systemAction`,
  `window`, `images` (low repeat-rate), and calendar events (transient).
  Apps, files, URLs, chats, Spotify, Notes, settings, folders, clipboard,
  notion, linear, mail, terminal — all participate.
- **Privacy**: explicit "Clear search history" menu item that nukes the
  table. No telemetry, no network. Plain-text local DB (FileVault handles
  at-rest encryption).

## Non-goals (this session)

- Time-based decay (the +1/-1 mechanism handles calibration through usage).
- Per-query leaderboards (we use a single global counter; revisit if
  same-prefix-different-intent failures actually appear in practice).
- UI badges showing "this was boosted." Invisible by default.
- Misclick-correction heuristics beyond the basic penalty mechanism.

## Target shape

```
Sources/spotlight++/
  Models/
    SearchResult.swift               # add `stableId` computed property
  Services/
    SelectionHistoryStore.swift      # SQLite actor: record / lookup / clear
    FrequencyReranker.swift          # pure scoring + sort, within-band
  ViewModels/
    SearchViewModel.swift            # wire store, call recordSelection,
                                     # apply reranker after search merge
  SpotlightApp.swift                 # menu item: "Clear search history"
Tests/
  spotlight++Tests/
    SearchResultStableIdTests.swift  # per openTarget + blacklist behaviour
    SelectionHistoryStoreTests.swift # cap=3 / floor=0 / record / lookup / clear
    FrequencyRerankerTests.swift     # ordering, band preservation, recency tiebreak
```

## Checklist

`swift build` must be green after every checked item.
`swift test` must be green after each phase ends.
Do NOT proceed if either is broken.

### Phase 0 — Baseline
- [ ] `swift build` green (current state)
- [ ] `swift test` green (49 existing tests still passing)

### Phase 1 — `SearchResult.stableId`
- [ ] Add `stableId: String?` computed property on `SearchResult`
- [ ] Returns nil for blacklisted sources (`systemAction`, `window`, `images`)
- [ ] Derives ID per openTarget:
  - `.url(s)` → `"url:" + s`
  - `.file(p)` → `"file:" + p`
  - `.whatsappChat(jid, _)` → `"whatsapp:" + jid`
  - `.imessageChat(handle, _)` → `"imessage:" + handle`
  - `.copyToClipboard(s)` → `"clip:" + s`
  - `.notesNote(title)` → `"notes:" + title`
  - `.spotifyPlay(uri, _)` → `"spotify:" + uri`
  - `.windowAction(_)` / `.systemAction(_)` → nil
- [ ] Write `SearchResultStableIdTests.swift` — one test per openTarget case
- [ ] `swift build` + `swift test` green

### Phase 2 — `SelectionHistoryStore`
- [ ] Create `Services/SelectionHistoryStore.swift` as an `actor`
- [ ] SQLite at `~/Library/Application Support/spotlight++/selection_history.db`
- [ ] Schema: `(stable_id TEXT PRIMARY KEY, count INT NOT NULL, last_selected_at INT NOT NULL)`
- [ ] `init(dbPath:)` — accepts a custom path for tests; defaults to support dir
- [ ] `recordSelection(chosenId:visibleIds:)` async — one SQLite transaction:
  - chosen: `INSERT ... ON CONFLICT DO UPDATE SET count = MIN(3, count+1), last_selected_at = ?`
  - others: `UPDATE SET count = MAX(0, count-1) WHERE stable_id IN (...)` (only existing rows)
- [ ] `lookup(_ ids: [String])` async → `[String: (count: Int, lastSelectedAt: Int64)]`
- [ ] `clear()` async — `DELETE FROM selection_history`
- [ ] Write `SelectionHistoryStoreTests.swift`:
  - cap at 3 over many selections
  - floor at 0 over many penalties
  - record + lookup round-trip
  - clear empties the table
  - non-existent visible IDs don't error
- [ ] `swift build` + `swift test` green

### Phase 3 — `FrequencyReranker`
- [ ] Create `Services/FrequencyReranker.swift`
- [ ] Pure static function:
  `apply(to results: [SearchResult], history: [String: (count: Int, lastSelectedAt: Int64)]) -> [SearchResult]`
- [ ] Stable-sort within each `source` band by `(count DESC, lastSelectedAt DESC, base_rank DESC)`
- [ ] Rewrite ranks via `withRank(...)` so the ViewModel's downstream sort
      preserves the new ordering (per existing `rank` ownership rule)
- [ ] Write `FrequencyRerankerTests.swift`:
  - empty history → results unchanged
  - higher count wins
  - tied counts: more recent wins
  - tied counts + recency: base rank wins
  - blacklisted-source results (stableId=nil) skipped from reranking
  - never crosses band boundaries
- [ ] `swift build` + `swift test` green

### Phase 4 — Wire into SearchViewModel
- [ ] Initialize `historyStore: SelectionHistoryStore` in init (with default support dir path)
- [ ] In `performSearch`, after async-let merge, apply `FrequencyReranker.apply(...)`
      to each per-source backing array's results before assignment
- [ ] In `open(_ result:)`, call `historyStore.recordSelection(...)` with the
      chosen result's stableId and the top-3 of current visible `results`
- [ ] In `submitActionIntent()` / `confirmSend()`, also record the selection
      against the originally `actingOn` result
- [ ] Skip recording when `query.count < 2` or `chosen.stableId == nil`
- [ ] `swift build` + existing 49 tests green

### Phase 5 — "Clear search history" menu item
- [ ] Add menu item to the status-bar `NSMenu` in `SpotlightApp.swift`
- [ ] Wires to `Task { await historyStore.clear() }`
- [ ] Confirmation? — no, the user already typed Clear; nuke immediately
- [ ] `swift build` green

### Phase 6 — Final verification
- [ ] `swift build` green
- [ ] `swift test` green (49 baseline + ~15 new = ~64 total)
- [ ] Manual smoke: select same result 4 times → see it stick at top;
      select competitor 4 times → see it overtake
- [ ] Note in plan: how to extend (different cap, decay, etc)

## How to tune later

- **Change the cap**: one constant in `SelectionHistoryStore` (`maxCount = 3`).
- **Change the visible-set size**: one constant in `SearchViewModel` where
  `recordSelection` is called (currently top-3).
- **Add decay**: extend `lookup` to compute `count * exp(-Δt/halfLife)`
  rather than raw count, used at sort time only — no write amplification.
- **Allow images to participate**: remove `.images` from the blacklist in
  `SearchResult.stableId`.

## Risk register

- **File rename/move orphans history** — accepted; per earlier discussion.
- **Misclick on top result reinforces it** — mitigated by penalty mechanism
  (next correct pick: chosen +1, misclick -1; one-round recovery from floor).
- **Plaintext query selections on disk** — only the result IDs are stored,
  not the query strings. The DB does not contain "what the user typed."
  This is a deliberate privacy property of the design.
- **Self-fulfilling top-of-list** — mitigated by cap=3 ceiling: after 3
  selections the boost is maxed; further selections don't widen the gap,
  letting other results compete on base relevance again.
