# spotlight++

A Spotlight-style launcher for macOS, written in Swift + SwiftUI. Floating
panel summoned by a global hotkey; sub-millisecond per-keystroke matching
across apps, window-management commands, System Settings panes, and folder
shortcuts. Plus a live desktop snap-zone overlay for window actions.

## Hotkey

`⌘ K` — toggle the panel. `Esc` hides it. `↑/↓` move selection. `↩` runs
the highlighted result.

> To rebind, edit `kVK_ANSI_K` and the modifier mask in `SpotlightApp.swift`.
> Carbon hotkeys take one keycode + standard modifiers (`cmdKey`, `shiftKey`,
> `optionKey`, `controlKey`); chords aren't supported by the API.

## What it does (v0)

The launcher surfaces four **command sources**. Each is a flat alias table
matched per keystroke — prefix first, Levenshtein-distance fallback for
typos, no scoring math. Total cost per keystroke: ~5 µs across ~250 aliases.

**Apps.** Every `.app` under `/Applications`, `/System/Applications`,
`/System/Library/CoreServices`, and `~/Applications`. Exact-name match
bumps to the top (`chrome` → Chrome, `notion` → Notion). Fuzzy fallback
catches typos: `spottify` / `noton` / `chrme` land their intended targets
at distance ≤ 2.

**Window management.** 14 actions across 4 groups — Halves, Quadrants,
Thirds, Display. Targets the previously-frontmost window via the
Accessibility API. Selecting a window-action row pops up a translucent
steel-blue rectangle on the actual desktop at the snap target, so you see
where the window will land before pressing ↩. Slides between presets as
you arrow through. Powered by `WindowManagerService` + the click-through
`WindowSnapOverlayController`.

| Group | Actions |
| --- | --- |
| Halves | Left Half · Right Half |
| Quadrants | Top Left · Top Right · Bottom Left · Bottom Right |
| Thirds | Left Third · Center Third · Right Third |
| Display | Maximize · Minimize · Center Window · Next/Previous Display |

**System Settings.** ~30 hand-curated panes accessible via the documented
`x-apple.systempreferences:<extension-id>` URL scheme — no AppleScript, no
UI scripting, no Accessibility taps. Type `bluetooth` → opens straight to
the Bluetooth pane. Aliases include both the canonical name and common
shorthand (`wifi` / `wi-fi` / `wireless` → Wi-Fi). Grouped into Hardware,
System, Privacy, Identity; the path surfaces in the row subtitle
("Settings > Privacy → Camera").

**Folders.** 10 fast destinations (Downloads, Documents, Desktop, Home,
Applications, Pictures, Movies, Music, iCloud Drive, Trash) with aliases
like `dl` / `docs`. Opens the target in Finder via `NSWorkspace.open`.

### Typo tolerance

When prefix matching returns zero hits, each command source falls back to
bounded Levenshtein with a length-based budget:

| Query length | Edit budget |
| --- | --- |
| ≤ 3 chars | 0 (no fuzzy — too short, would match noise) |
| 4 chars | 1 |
| 5+ chars | 2 |

Capped at 2 so genuinely-nonsense input (e.g. `aldjasfjsafd`) can't
route to a real command. The DP terminates early when the per-row minimum
exceeds budget, so non-matches reject in microseconds. See
`Utils/FuzzyMatch.swift`.

### Command exclusivity

When the typed query *exactly* matches a command alias (window action,
settings pane, folder shortcut, or an installed app's name), other sources
are suppressed for that render. Strict-equality only, not prefix — keeps
the typing phase forgiving while cleanly committing to a known command
once enough is typed.

## What's NOT enabled in v0

Content search across messages (WhatsApp / iMessage / Discord), Mail,
Notes, Notion, Linear, Spotify, Clipboard, Files, Browser history, and
the MobileCLIP image semantic index are all **still in the codebase** but
gated behind a single flag (`SearchViewModel.contentSearchEnabled`,
currently `false`). The services run their permission/warm-up at startup;
they just don't get queried or merged into the result list yet.

Flip the flag to bring content back. The UI shape for blending content
with commands is still being designed.

## Build & run

```bash
./build-app.sh
open ./spotlight++.app
```

Behind the scenes:

1. `swift build -c release` produces the binary.
2. The script assembles a proper `.app` bundle with `Info.plist`
   (`LSUIElement = true` → no Dock icon).
3. SPM resource bundles (containing the MobileCLIP `.mlmodelc` files)
   are restructured into Cocoa layout (`Contents/Info.plist` +
   `Contents/Resources/`) so they're code-signable.
4. Each nested bundle is signed first, then the outer app, with a stable
   Apple Development cert SHA-1 (see `SIGNING_IDENTITY` in the script).

The stable signing identity matters: macOS's TCC subsystem ties
permission grants to the code signature, so an unstable ad-hoc signature
would prompt for Accessibility / Contacts / Calendar on **every rebuild**.
With the dev cert pinned, grants persist across rebuilds.

To swap the signing identity, list yours with:

```bash
security find-identity -v -p codesigning
```

…and edit `SIGNING_IDENTITY` in `build-app.sh`.

For quick iteration without bundling:

```bash
swift run
```

…but global hotkeys may not register reliably for an unbundled binary,
and the bundle restructure isn't applied — use the `.app` for the real
experience.

## Permissions

TCC services touched by spotlight++:

- **Accessibility** — required for the global hotkey (Carbon
  `RegisterEventHotKey`) and for executing window-management actions
  against other apps' windows.
- **Contacts**, **Calendar**, **Full Disk Access**, **Automation →
  Messages / Spotify** — used by the (currently gated-off) content
  services. Bootstrapped at launch so the system prompts are batched
  together rather than surprising mid-flow.

`PermissionsBootstrap.requestAll()` is *check-before-prompt*: it queries
each service's authorization status first and only invokes the prompting
API when status is undetermined. Combined with stable signing, the user
sees prompts on first install and never again.

## Architecture

```
Sources/spotlight++/
├── SpotlightApp.swift                  # @main AppDelegate; hotkey + menu wiring
├── Models/
│   ├── SearchResult.swift              # row model + per-source icon/tint
│   ├── WindowAction.swift              # discrete window-management presets
│   └── ComposeAction.swift             # acting-mode compose payloads
├── Utils/
│   └── FuzzyMatch.swift                # bounded Levenshtein + length-based budget
├── ViewModels/
│   └── SearchViewModel.swift           # @MainActor; immediate (no debounce) match
├── Views/
│   ├── SearchView.swift                # bubble: input + tab strip + results
│   ├── SearchResultRow.swift           # icon badge, title, subtitle, badge
│   ├── WindowActionPreview.swift       # tiny schematic of the snap rect
│   ├── ComposeView.swift               # send-message / create-event compose
│   ├── CalendarComposeView.swift       # event editor
│   ├── TabStripView.swift              # All / Messages / Mail / Apps pills
│   └── VisualEffectView.swift          # NSVisualEffectView (HUD blur) bridge
└── Services/
    ├── WindowManagerService.swift          # AX-driven snap + alias matching
    ├── WindowSnapOverlayController.swift   # the live desktop blue-zone overlay
    ├── SystemSettingsService.swift         # x-apple.systempreferences: deep-links
    ├── FoldersService.swift                # folder-shortcut aliases
    ├── AppSearchService.swift              # /Applications scan + exact/fuzzy match
    ├── HotKeyManager.swift                 # Carbon RegisterEventHotKey
    ├── SearchWindowController.swift        # NSPanel host + key event monitor
    ├── PermissionsBootstrap.swift          # check-before-prompt TCC bootstrap
    ├── TextSelectionCapture.swift          # grabs selection in frontmost app
    └── (content sources — gated behind contentSearchEnabled)
        ├── BrowserDatabaseService.swift    # Chrome / Arc / Brave / Edge history
        ├── FileSearchService.swift         # mdfind shell-out
        ├── AppleMailService.swift          # Mail FTS index
        ├── AppleMessagesService.swift      # chat.db search
        ├── AppleNotesService.swift         # Notes index
        ├── WhatsAppService.swift           # WhatsApp Mac chat search
        ├── DiscordService.swift            # Discord cache parser
        ├── NotionService.swift             # Notion API
        ├── LinearService.swift             # Linear GraphQL
        ├── SpotifyService.swift            # Spotify Web API + AppleScript
        ├── ClipboardHistoryService.swift   # pasteboard observer
        ├── ImageIndexService.swift         # MobileCLIP + Vision + FTS5 RRF
        ├── SmartSearchService.swift        # OpenAI query planner
        └── EmbeddingStore.swift            # message-content embedding cache
```

The view layer holds zero business logic. Views observe `SearchViewModel`,
which fires the command sources synchronously per keystroke (no debounce
— local alias-table loops finish before perceivable latency) and routes
results into a single merged `[SearchResult]` list. Hotkey, window, and
permission plumbing live in `Services/` so the ViewModel stays
platform-agnostic.

## Roadmap

- **Re-enable content search** behind a real UX — the working theory is a
  compact-vs-expanded mode (Tab to drill into a richer view with sidebar
  + preview pane). Today's design conversation centered on "commands +
  apps inline, content only on demand."
- **System actions** as another command source (lock screen, sleep,
  toggle dark mode, empty trash, etc.).
- **Calculator and unit conversion** detection for `2+2`-shape queries.
- **Custom user-config shortcuts** (project folders, URL aliases) loaded
  from `~/.spotlight++/aliases.toml`.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+
- Xcode Command Line Tools (`xcode-select --install`)
- An Apple Development cert in Keychain for stable signing
  (Xcode → Settings → Accounts → + Apple ID → Manage Certificates →
  Apple Development)
