# spotlight++ performance

Latency, indexing throughput, storage cost, and steady-state characteristics
of every search source. Numbers are measured on Apple Silicon (M-series, 16-32 GB RAM,
macOS 15+) unless noted. "Cold" means first call after launch; "warm" means
subsequent calls with caches populated.

The goal everywhere: **search responses within a single key-press time slice** —
under ~150ms warm. That budget is what makes the panel feel like Spotlight,
not like a search engine.

---

## Image search (Vision + MobileCLIP-S2)

The newest and most resource-heavy source. Indexes `~/Pictures`,
`~/Desktop`, `~/Downloads` (plus Photos library originals which live under
`~/Pictures/`) on first launch, then incrementally maintains the index.

### Models

| | Size on disk | Loaded RAM | Compute | Throughput per call |
|---|---|---|---|---|
| MobileCLIP-S2 image encoder (CoreML) | 68 MB | ~80 MB | CPU+GPU (ANE bypassed — see below) | ~80–120ms / image |
| MobileCLIP-S2 text encoder (CoreML) | 121 MB | ~140 MB | CPU+GPU | ~25–35ms / query |
| `VNClassifyImageRequest` | system | ~50 MB shared | ANE | ~10–30ms |
| `VNRecognizeTextRequest` (accurate) | system | ~80 MB shared | ANE | ~80–250ms (text-density dependent) |

> **Why CPU+GPU, not ANE, for CLIP?** ANE threw `NSGenericException` on a
> specific user image (HEIC with 16-bit-per-component HDR profile) which
> Swift `try?` cannot catch — it terminated the process. CPU+GPU is
> ~2-3× slower but robust across every CGImage shape Vision can decode.
> We pay the 30→100ms penalty per image once at index time; query-time
> text encoding is unaffected (<35ms).

### Index throughput (one-time cost)

Per image: load + decode + Vision classify + Vision OCR + CLIP image encode + thumbnail + SQLite upsert.

| Corpus size | First-run wall-clock |
|---|---|
| 100 images | ~10 sec |
| 1,000 | ~1.5 min |
| 7,000 (measured) | ~10–12 min |
| 50,000 (extrapolated) | ~75 min |

Index runs in a `Task.detached` so the UI never blocks. The sweep yields
between every image via `await Task.yield()` so a search call interleaves
mid-sweep without waiting for the whole pass.

### Storage

- SQLite: `~/Library/Application Support/spotlight++/images.db`
- Per row: 2KB embedding blob + ~512B labels JSON + ~50B OCR median + ~16B path. **~3 KB / image**.
- 7K images → ~30 MB DB. 50K → ~150 MB. Linear in corpus size.

### Query latency

| Stage | Cold (first query) | Warm |
|---|---|---|
| CoreML text encoder load | ~500–1000 ms | 0 (cached) |
| BPE tokenize query | ~5 ms | ~5 ms |
| Text encoder forward pass | ~30 ms | ~30 ms |
| Pull all 512-d embeddings from SQLite | ~30 ms (7K rows) | ~30 ms |
| Cosine over N vectors (vDSP_dotpr) | ~10 ms (7K) | ~10 ms |
| Build top-30 SearchResult rows + cached thumbnails | ~20 ms | ~20 ms |
| **Total** | **~600–1100 ms** | **~95–105 ms** |

> Above ~50K embeddings, the linear cosine scan starts to dominate.
> At that scale add an ANN index (FAISS, USearch, or hand-roll a HNSW)
> — gets us back under 100ms at ≥1M images.

### Incremental updates

Re-running on already-indexed files: ~0 ms each (mtime check is a single
indexed SQL row lookup). Sweeps complete in <500 ms when nothing changed.

---

## Mail (.emlx walker → SQLite FTS5)

Apple Mail stores messages as `.emlx` files under
`~/Library/Mail/V*/<MailboxUUID>/<MessageID>.emlx`. We walk every mailbox,
parse the multipart MIME, and index `(subject, sender, body)` into an
FTS5 virtual table.

### Index throughput

| Stage | Wall-clock |
|---|---|
| Walk all mailboxes, enumerate files | ~500 ms - 5 sec |
| Parse single .emlx + decode body | ~2-15 ms |
| Insert into FTS5 | <1 ms / row |
| **10K messages** | **~30-90 sec** |
| **100K messages** | **~5-15 min** |

Lifetime: refreshed via `refreshIfNeeded()` with a 300-second debounce.
Re-walks the mailbox tree but skips unchanged messages by ROWID.

### Storage

`~/Library/Application Support/spotlight++/mail_index.db`
- Per message: ~1-5 KB after FTS5 compression
- 100K messages ≈ 200-400 MB

### Query latency

| Stage | Time |
|---|---|
| Tokenize query into FTS5 MATCH expression | <1 ms |
| Run `SELECT ... FROM mail_fts WHERE ... MATCH ?` LIMIT 50 | **5–25 ms** (FTS5 is fast) |
| Build SearchResult rows | ~5 ms |
| **Total** | **~10–30 ms** |

Among the fastest sources. FTS5 BM25 ranking happens entirely in C, no
Swift roundtrip per row.

---

## Discord (cache parser → SQLite + optional OpenAI embedding rerank)

Discord stores chat history in a private CEF/Chromium cache at
`~/Library/Application Support/discord/Cache/Cache_Data`. We parse the
binary cache, extract message records, and index them.

### Index throughput

Bigger and more variable than Mail — the cache format is undocumented and
contains a lot of non-message data.

- Walk + parse: **~30-60 sec** for typical user cache (~10-50K messages).
- Lifetime: refreshed lazily, full re-walk on every cold sweep
  (~minutes for heavy users).

### Storage

`~/Library/Application Support/spotlight++/discord_index.db`
- Tables: `users(id, username, avatar_data)`, `channels(id, name, ...)`,
  `messages(id, author_id, content, timestamp)`.
- Per message: ~200 B + average content size. 50K messages ≈ 50 MB.

### Query latency

Two paths:

**1. Keyword search** (cheap):
- SQLite LIKE on `content`: 10-40 ms over 50K rows.
- Plus contact-card lookups (user_id resolution): +5 ms.
- **Total: ~20-50 ms.**

**2. Smart search with semantic rerank** (when the OpenAI planner
classifies the query as a "find a message about X" semantic query):
- Planner round-trip (gpt-4o-mini): 400-900 ms.
- OpenAI embedding for the query (text-embedding-3-small): 150-300 ms.
- Cosine vs. pre-built embeddings.db: 5-20 ms.
- **Total: ~600-1200 ms, but only when the AI path is taken.**

> Semantic rerank is gated on `EmbeddingStore.isAvailable()` — if
> `embeddings.db` hasn't been pre-built via `scripts/embed_messages.py`,
> we fall back to keyword.

---

## iMessage (`chat.db` SQLite read)

Apple Messages stores everything in `~/Library/Messages/chat.db` — an open
SQLite file. We read it directly; no indexing of our own.

### Query latency

| Stage | Time |
|---|---|
| Open + attach `chat.db` | ~5 ms (cached connection) |
| Query messages by handle or substring | **10-50 ms** depending on `chat.db` size |
| Contact resolution via `ContactsResolver` | 1-10 ms (cached) |
| **Total** | **~20-70 ms** |

No indexing cost — the heavy lifting is Apple's. Lifetime: connection
stays open; we rely on macOS's own WAL semantics for read consistency.

### Storage

Zero — we use Apple's `chat.db` in place. Read-only.

---

## Apple Notes (full-text via `NSNotes.sqlite`)

Apple Notes' SQLite store at
`~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`. We
read it directly. Encrypted notes are skipped.

### Query latency

| Stage | Time |
|---|---|
| `WHERE ztitle LIKE ? OR zbody LIKE ?` over typical 500-5K notes | **5-30 ms** |
| **Total** | **~10-40 ms** |

No indexing.

---

## Browser history (Chrome/Arc/Brave/Edge)

Each Chromium browser stores history in `History` SQLite at
`~/Library/Application Support/<Browser>/Default/History`. We open
read-only copies (the originals are locked while the browser is running).

### Query latency

| Stage | Time |
|---|---|
| Open `History.copy` (refreshed via lifetime) | <1 ms after first |
| `SELECT ... WHERE url LIKE ? OR title LIKE ?` LIMIT 30 | **15-50 ms** for typical 50K-row histories |
| Favicon fetch from `Favicons.copy` | ~5 ms per result |
| **Total per browser** | **~30-80 ms** |

Total in the fan-out: **~80-150 ms** across all four browsers (parallel).

### Storage

`~/Library/Application Support/spotlight++/browser_caches/` — periodic
copies of the source DBs to dodge locks while browsers run. ~20-80 MB.

---

## Apps (`AppSearchService`)

Scans `/Applications`, `~/Applications`, `/System/Applications` for
`.app` bundles, builds an in-memory list with metadata + icons.

| Stage | Time |
|---|---|
| Cold cache build | 200-500 ms for ~100-200 apps |
| Per-query match (substring over in-memory list) | **<5 ms** |

No persistent storage; rebuilds on launch. The fastest source.

---

## Clipboard history (poller → SQLite)

Polls `NSPasteboard.general.changeCount` every 500 ms; persists captured
strings to SQLite.

### Steady-state cost

- Polling: ~0.01% CPU (just a change-count read).
- Insert: ~1 ms per new entry.
- Storage: capped at 1000 entries × ~100 B avg = ~100 KB.

### Query latency

`SELECT ... WHERE content LIKE ?` over capped 1K rows: **<5 ms**.

---

## Terminal history

`~/.zsh_history` walker. Loaded once into memory, line-substring matched.

| Stage | Time |
|---|---|
| Load | ~10-30 ms for 10K-line history |
| Per-query match | **<10 ms** |

(Currently excluded from the active tab fan-out per UX direction —
kept in the codebase but not surfaced.)

---

## Smart search (LLM-routed)

When the query looks like natural language ("emails from X last week",
"the song mikki sent me yesterday"), `SmartSearchService` calls OpenAI
to produce a structured `QueryPlan` that names a source + extracts
keywords + a `search_term` for embedding rerank.

### Network cost

| Stage | Time |
|---|---|
| `planner` round-trip (gpt-4o-mini) | 400-900 ms |
| For semantic results: query embedding (text-embedding-3-small) | 150-300 ms |
| **Total smart overhead** | **~550-1200 ms** before any search runs** |

This is the only source that touches the network.

### When it triggers

- Long queries (>3 words)
- Quoted phrases ("…")
- Contact-shaped queries ("from drishtu", "to kev")

Otherwise the keyword fan-out runs directly.

---

## Memory + RAM budget (steady-state, idle)

| | Idle RAM |
|---|---|
| spotlight++ baseline (Swift runtime + SwiftUI window) | ~80 MB |
| Image search (CLIP models loaded) | +220 MB |
| Browser DB connections (×4) | +30 MB |
| Mail FTS5 + Discord SQLite | +40 MB |
| **Total typical** | **~370 MB** |

Models unload from RAM when the app is backgrounded for >30 sec — they
re-load lazily on next query (~500-1000 ms cold).

---

## App size on disk

| | Size |
|---|---|
| Binary (`spotlight++`) | ~3 MB |
| MobileCLIP-S2 models (both encoders) | ~190 MB |
| CLIP tokenizer (vocab + merges) | ~1.4 MB |
| **App bundle total** | **~195 MB** |

Models are fetched once via `scripts/fetch-clip-models.sh` (excluded from
git because GitHub's 100MB single-file limit blocks the weight.bin).

---

## Comparative latency summary

Sorted from fastest to slowest typical warm query. **Bold = source actually contacted on most queries.**

| Source | Typical | Notes |
|---|---|---|
| **Apps** | **<5 ms** | In-memory match. |
| **Clipboard** | **<5 ms** | SQLite LIKE over ≤1K rows. |
| Apple Notes | 10-40 ms | Direct SQLite. |
| **Mail (FTS5)** | **10-30 ms** | BM25 ranked. |
| iMessage (chat.db) | 20-70 ms | Apple's own SQLite. |
| Discord (keyword) | 20-50 ms | Indexed SQLite. |
| **Browser history (×4 parallel)** | **80-150 ms** | Open History dbs in parallel. |
| **Image search (CLIP)** | **~100 ms warm** | After first-query model load. |
| Image search (cold) | 600-1100 ms | One-time model load penalty. |
| Smart search (gpt-4o-mini planner) | 400-900 ms | Network. |
| Smart search + Discord semantic rerank | 600-1200 ms | Network ×2. |

Every keyword-only source is well under the 150 ms key-press budget. The
two that exceed it (smart search, image-search cold) do so because of
network or one-time model load — both surface a "Thinking…" or fade
indicator so the UI feels intentional rather than stuck.

---

## Where the perf gates are

Things to watch as the indexes grow:

1. **Image search beyond 50K photos** — the in-memory linear cosine pass
   becomes the bottleneck. Switch to an ANN index (HNSW / FAISS / USearch).

2. **Mail past 250K messages** — FTS5 stays fast for matching, but the
   `.emlx` walker holds the whole tree in memory during refresh.
   Streaming pass + bounded backlog is the fix.

3. **Discord cache parser on multi-server users** — current code re-parses
   the whole cache on every refresh. Incremental delta against last
   modification time would skip 90% of the work.

4. **Browser history > 200K rows** — LIKE without a prefix is O(n).
   The fix is FTS5 on `(title, url)`, which we do for Mail but not
   browsers yet.

5. **Smart search latency variance** — gpt-4o-mini can spike to >2s under
   load. The "Thinking…" spinner shows; consider a 1s fallback to
   keyword-only if the planner doesn't return.
