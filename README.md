# tvara

**[trytvara.com](https://trytvara.com)**

> A new way to navigate your Mac.

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

## A new way to navigate your Mac

Your messages, photos, emails, notes, browser history, clipboard —
they all live on this disk. To find any one of them today, you open
the right app and use its searchbox. Twelve apps, twelve searchboxes,
twelve different ideas of what search should do.

tvara is one searchbox across all of them.

`⌘K` from anywhere. Type a few words. Press `↩`.

## What it searches

- Apps, files, folders
- Messages — WhatsApp, iMessage, Discord
- Mail
- Notes
- Clipboard history
- Browser history — Chrome, Arc, Brave, Edge
- Photos — on-device semantic image search (CLIP)
- System Settings panes
- Window snap actions and system actions (lock, sleep, restart)

Queries can be natural-language: _"the chase email about my credit
card"_, _"the photo with the dog at the beach"_, _"snap this window top
right"_. The launcher tracks which results you pick and weights them up
within their rank band, so things you reach for often start surfacing
higher over time.

## Install

A signed binary is coming to **[trytvara.com](https://trytvara.com)**.
For now, build from source:

```bash
./build-app.sh
open ./tvara.app
```

**Requirements**

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools — `xcode-select --install`
- An Apple Development cert in Keychain. The build script signs the
  bundle with it so macOS TCC grants (Accessibility, Contacts, Full
  Disk Access, Automation) persist across rebuilds — otherwise you'd
  re-click those prompts every time you rebuild. List yours with
  `security find-identity -v -p codesigning` and update
  `SIGNING_IDENTITY` in `build-app.sh`.

**First launch.** macOS will prompt for permissions in a batch — grant
them once and you're done. tvara summons with `⌘K` from anywhere.

## Keys

| Key | Action |
| --- | --- |
| `⌘K` | summon |
| `↑ ↓` | move selection |
| `↩` | open |
| `⌘↩` | act on selected (send a message, create an event) |
| `⇥` | category deck |
| `↩` (in deck) | zoom into a category |
| `esc` | back one layer (zoom → deck → blended → clear → hide) |

## How it works

Per-keystroke fan-out across local sources — files via Spotlight's own
`mdfind`, messages via direct SQLite reads from each app's local store,
photos via on-device MobileCLIP semantic embeddings, mail via Apple
Mail's FTS index. Results stream into a single ranked list as each
source returns; you see the fastest hits in milliseconds while the
slower ones land underneath.

An optional natural-language planner (OpenAI today, on-device next)
routes ambiguous queries — "address i sent drish last week" gets parsed
into source: messages, contact: drish, time: week, search_term:
"street address" — so the right source gets the right query without you
thinking about it.

A frequency reranker watches which results you actually pick and
weights them up within their rank band. The launcher gets sharper
the more you use it.

## Status

Active development. Some sources (Notion, Linear, Spotify) require API
keys; others (Messages, Mail, WhatsApp, Discord, Notes, Clipboard,
Photos) work out of the box once macOS permission prompts are granted
on first launch. The architecture is set; the polish is in flight.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free for personal, hobby,
research, and non-commercial-organization use. Commercial use reserved.
Commercial licensing: aaryansh@pally.com.
