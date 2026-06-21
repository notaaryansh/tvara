# Event Queue Plan

A unified, push-based ingestion bus that replaces today's pull-based `refreshIfNeeded()` model. Producers detect new content (new iMessage row, new file, new photo) and emit typed events. Type-specific workers consume events in the background and update the existing per-source indexes.

## Decisions (v1)

- **In-process.** Indexing lives inside the main tvara app, same as today. No XPC/daemon (yet).
- **SQLite-backed durable queue** at `~/Library/Application Support/tvara/events.db`.
- **Gradual migration.** Existing `refreshIfNeeded()` paths stay as a fallback while sources are moved over one at a time.
- **Embeddings are their own event type.** `embed_message` events let us rate-limit the OpenAI call independently from cheap indexing work.
- **v1 scope:** iMessage + Files + Images. Discord/WhatsApp/Mail follow the same template later.

## Architecture

```
producers ──► EventBus (events.db) ──► workers ──► per-type indexes
                                                   (imessage_index.db, images.db, …)
```

- **EventBus**: single Swift actor. Owns `events.db`. API: `enqueue`, `claim`, `complete`, `fail`.
- **Producers**: watermark pollers (ROWID for chat DBs) + `FSEvents` watchers (filesystem). Emit one event per new item.
- **Workers**: one actor per event type. Claim N, hand off to the existing indexer, mark done. Exponential backoff + max-attempts on failure.
- **Recovery**: any `processing` rows older than a timeout revert to `pending` on app launch (covers crash-mid-index).

## Schema

```sql
CREATE TABLE events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  type        TEXT NOT NULL,             -- 'message_added' | 'file_added' | 'image_added' | 'embed_message'
  source      TEXT NOT NULL,             -- 'imessage' | 'discord' | 'whatsapp' | 'fs' | …
  payload     TEXT NOT NULL,             -- JSON
  status      TEXT NOT NULL,             -- 'pending' | 'processing' | 'done' | 'failed'
  attempts    INTEGER NOT NULL DEFAULT 0,
  error       TEXT,
  enqueued_at REAL NOT NULL,
  claimed_at  REAL,
  dedupe_key  TEXT UNIQUE                -- e.g. "imessage:42891"
);
CREATE INDEX idx_events_status_type ON events(status, type);
CREATE INDEX idx_events_dedupe ON events(dedupe_key);
```

---

## Checklist

### Phase 0 — Plan
- [x] Write this doc

### Phase 1 — EventBus core
- [x] `Sources/tvara/Services/EventBus/EventBus.swift` — actor, SQLite-backed
- [x] `Sources/tvara/Services/EventBus/EventTypes.swift` — typed event enum + payload structs
- [x] Schema bootstrap (`events.db`)
- [x] `enqueue(_:)` with dedupe-key UNIQUE conflict → no-op
- [x] `claim(type:limit:)` atomic status flip pending → processing
- [x] `complete(id:)` and `fail(id:error:)` with attempt count
- [x] Stale-`processing` recovery on init
- [x] `Tests/tvaraTests/EventBusTests.swift` — enqueue, dedupe, claim, complete, fail, recovery (12 tests)

### Phase 2 — Worker framework
- [x] `Sources/tvara/Services/EventBus/EventWorker.swift` — protocol + `WorkerRunner` loop
- [x] Exponential backoff (lives in `EventBus.fail` from Phase 1; verified in `testBackoffPreventsImmediateReclaim`)
- [x] Max-attempts cap → `failed` (in `EventBus.fail`; verified in `testFailFinalisesAfterMaxAttempts`)
- [x] Start/stop lifecycle (`WorkerRunner.start/stop`; verified in `testStopHaltsTheLoop`)

### Phase 3 — iMessage (first end-to-end slice)
- [x] iMessage watermark producer (ROWID poll → `message_added` events) — `IMessageProducer.swift`
- [x] `MessageIndexWorker` consuming `message_added(source: imessage)`, delegates to `AppleMessagesService.indexRowIds(_:)`
- [x] Wire producer + worker into `SearchViewModel` startup (in-process, parallel to legacy `warmCache` while migration bakes)
- [ ] Manual verify: new iMessage appears in index without a search-triggered refresh _(requires live app run — defer until user smoke-tests)_

### Phase 4 — Files
- [x] `FSEvents`-based file producer (configurable dir set) — `FSEventsWatcher.swift`, `FileProducer.swift`
- [x] `FileIndexWorker` (initial: metadata cache only — mdfind stays for live search) — `FileIndexService.swift`, `FileIndexWorker.swift`
- [x] Wire into `SearchViewModel`; tests cover upsert, idempotency, missing-path handling, end-to-end worker loop, and producer filtering

### Phase 5 — Images
- [x] Image producer (FSEvents on image-bearing dirs) — `ImageProducer.swift`
- [x] `ImageIndexWorker` delegating to `ImageIndexService.indexPath(_:)` — exposed new path entry on the service
- [x] Wire into `SearchViewModel`; producer filter test coverage (CoreML pipeline runs live, not in tests)

### Phase 6 — Embeddings as a separate event type
- [x] `embed_message` event type (added in Phase 1 enum)
- [x] `MessageIndexWorker` enqueues `embed_message` after raw index (gated by optional `bus:`)
- [x] `EmbedMessageWorker` with batch + per-source dispatch; ported from `embed_messages.py` (same model, same schema, same `MIN_CHARS=4`). Silent no-op when `OPENAI_API_KEY` is missing. Backoff comes from `EventBus.fail` if the API errors.

### Phase 7 — Migration
- [x] Guard `refreshIfNeeded()` for migrated sources behind `EventBusConfig.legacyPullRefreshEnabled` (default **true** while v1 bakes — flip to false once trusted). Wired into `AppleMessagesService.refreshIfNeeded`.
- [x] Update `docs/PERFORMANCE.md` to describe push-based flow + per-source freshness budget

### Phase 8 — Observability
- [x] Log queue depth + failed count on startup (`SearchViewModel` detached task at app launch)
- [x] Log recent failed events with id/type/source (uses `EventBus.recentFailures(limit:)`)

---

## Open items

- If we want indexing-while-app-quit, revisit XPC daemon split after v1 is stable.
- Unifying per-source indexes into one DB is explicitly out of scope here — covered separately if pursued.
