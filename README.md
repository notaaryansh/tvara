# tvara

**[trytvara.com](https://trytvara.com)** — a Spotlight-style launcher for
macOS. Swift + SwiftUI. Floating panel summoned with `⌘K`. Searches apps,
files, messages (WhatsApp / iMessage / Discord), mail, notes, clipboard,
browser history, and your photos — the last via on-device CLIP semantic
image search.

![demo](Resources/demo.gif)

## Install

```bash
./build-app.sh
open ./tvara.app
```

Requires macOS 14+, Swift 5.9+, and an Apple Development cert (so TCC
grants persist across rebuilds — `security find-identity -v -p codesigning`
and update `SIGNING_IDENTITY` in `build-app.sh`).

## Keys

| Key | Action |
| --- | --- |
| `⌘K` | toggle panel |
| `↑ ↓` | move selection |
| `↩` | open selected |
| `⌘↩` | act on selected (compose / event) |
| `⇥` | open category deck |
| `↩` (in deck) | zoom into category |
| `esc` | walk back one layer (zoom → deck → blended → clear query → hide) |

## What it searches

- **Apps** — every `.app` under `/Applications`, `~/Applications`, system folders
- **Files & folders** — via `mdfind`
- **Window management** — 14 snap actions across halves, quadrants, thirds, displays
- **System Settings** — ~30 panes via the `x-apple.systempreferences:` URL scheme
- **System actions** — sleep, lock, restart, shut down, log out
- **Messages** — WhatsApp / iMessage / Discord chat history, deep-linked
- **Mail / Notes** — Apple Mail FTS, Notes index
- **Clipboard history** — pasteboard observer
- **Browser history** — Chrome / Arc / Brave / Edge
- **Images** — on-device MobileCLIP semantic search ("beautiful girl with glasses")
- **Notion / Linear / Spotify** — when keys are configured

## Architecture (brief)

`SpotlightApp` → `SearchWindowController` (NSPanel host + key monitor) →
`SearchViewModel` (@MainActor, fans out per-source `Task`s on every
keystroke) → `Services/*` (per-source searchers). Views observe the VM.
Result rows merge into a single ranked list; Tab swaps to a category deck.

```
Sources/tvara/
├── SpotlightApp.swift
├── Models/        — SearchResult, WindowAction, ComposeAction
├── Utils/         — FuzzyMatch (bounded Levenshtein)
├── ViewModels/    — SearchViewModel
├── Views/         — SearchView, CategoryDeckView, SearchResultRow, …
└── Services/      — App/File/Window/Settings/Folder + content sources
                    (Browser, Mail, Messages, Notes, Clipboard, Images, …)
                    + SmartSearchService (OpenAI planner) + EmbeddingStore
```

## Status

v0. Active: streaming per-source results, category-deck UX, frequency
reranker (weights selections you make). Content search uses an OpenAI
planner today; a local-LLM planner via Ollama is being benchmarked
(`experiments/bench_local_planner.py`).

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — source-available, free for
personal / hobby / research / noncommercial-organization use. Commercial
use reserved. Contact aaryansh@pally.com for licensing inquiries.
