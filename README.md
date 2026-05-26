# spotlight++

A Spotlight-style launcher for macOS, written in Swift + SwiftUI. v0 reads your
Chromium-family browser history and lets you fuzzy-search it from a floating
panel summoned by a global hotkey.

## Hotkey

`⌘ K` — toggle the panel. `Esc` hides it, `↑/↓` move selection,
`↩` opens the highlighted result in your default browser.

> To rebind, edit `kVK_ANSI_K` / modifiers in `SpotlightApp.swift`. Carbon
> hotkeys take one keycode + the standard modifier mask (`cmdKey`, `shiftKey`,
> `optionKey`, `controlKey`) — chords aren't supported by the API.

## Sources

**Browser history.** The `urls` table is read (read-only) from each browser's
`History` SQLite db. The live file is locked, so the app copies it to `/tmp`
first.

| Browser | Path |
| --- | --- |
| Chrome | `~/Library/Application Support/Google/Chrome/Default/History` |
| Arc    | `~/Library/Application Support/Arc/User Data/Default/History` |
| Brave  | `~/Library/Application Support/BraveSoftware/Brave-Browser/Default/History` |
| Edge   | `~/Library/Application Support/Microsoft Edge/Default/History` |

Safari is intentionally skipped — its history db lives under `~/Library/Safari/`
and requires Full Disk Access plus a different schema. Worth doing in a later
pass.

**Files & folders.** `FileSearchService` shells out to `mdfind` (macOS's
Spotlight-index CLI), scoped to your home dir, name-matching with a 1.5s hard
timeout. Real macOS file icons via `NSWorkspace.shared.icon(forFile:)`. No
indexer to maintain — Apple's `mds` daemon keeps the index hot.

## Build & run

```bash
./build-app.sh
open ./spotlight++.app
```

The script runs `swift build -c release`, assembles a proper `.app` bundle with
`Info.plist` (`LSUIElement = true` so there's no Dock icon), and ad-hoc
codesigns it so macOS will let the global hotkey register.

For quick iteration without bundling:

```bash
swift run
```

…but global hotkeys may not register reliably for an unbundled binary. Use the
bundled `.app` for the real experience.

## Architecture (MVVM)

```
Sources/spotlight++/
├── SpotlightApp.swift          # @main AppDelegate, hotkey + menu wiring
├── Models/
│   └── SearchResult.swift      # row model + per-browser icon/tint
├── ViewModels/
│   └── SearchViewModel.swift   # @MainActor, Combine debounce, stale-result drop
├── Views/
│   ├── SearchView.swift        # bubble: search bar + results list
│   ├── SearchResultRow.swift   # icon badge, title, url, visit meta
│   └── VisualEffectView.swift  # NSVisualEffectView (HUD blur) bridge
└── Services/
    ├── BrowserDatabaseService.swift  # actor; copies + reads SQLite
    ├── HotKeyManager.swift           # Carbon RegisterEventHotKey
    └── SearchWindowController.swift  # NSPanel host + key event monitor
```

The view layer holds zero business logic. Views observe a `SearchViewModel`,
which owns the debounce pipeline (150 ms) and delegates I/O to
`BrowserDatabaseService`. Hotkey + window plumbing live in `Services/` so the
ViewModel stays platform-agnostic and easy to unit-test later.

## SQL today, indexed db tomorrow

v0 hits the browser dbs directly with `LIKE '%query%'`. Plan for v1:

- Build a unified SQLite db (`spotlight.db`) with an FTS5 virtual table over
  `(title, url, content, path, source)`.
- A `launchd` agent watches the browser History files (and later, file system
  events under `~/Documents` etc.) and runs an incremental indexer.
- Swap `BrowserDatabaseService` for `IndexedSearchService` behind the same
  `SearchViewModel` protocol — the UI shouldn't change.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+
- Xcode command line tools (`xcode-select --install`)
