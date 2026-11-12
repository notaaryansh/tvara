# tvara

A launcher for Mac. Press `⌘K`, type, press `↩`.

[Download](https://github.com/notaaryansh/tvara/releases/latest) · [trytvara.com](https://trytvara.com)

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

## What it searches

- Messages: iMessage, WhatsApp, Discord
- Apps, files, folders
- Mail and Notes
- Photos, by what's in them ("dog at the beach")
- Clipboard history
- Browser history: Chrome, Arc, Brave, Edge
- System Settings

It also snaps windows ("left half") and runs system actions (sleep, restart).

## Compared to the others

| | tvara | Spotlight | Alfred | Raycast |
| --- | :---: | :---: | :---: | :---: |
| WhatsApp messages | ✓ | – | – | – |
| Discord messages | ✓ | – | – | – |
| iMessage | ✓ | ✓ | – | – |
| Photos by content | ✓ | ✓ | – | – |
| Window snapping | ✓ | – | – | ✓ |
| Launch time | 96 ms | n/a | 114 ms | 234 ms |
| Memory at idle | 36 MB | n/a | 29 MB | 57 MB |
| Open source | ✓ | – | – | – |
| Price | Free | Built in | Free + paid | Free + paid |

Built-in features only. Measured on an M4, macOS 27. How to reproduce:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Install

1. Download the `.dmg` from [Releases](https://github.com/notaaryansh/tvara/releases/latest).
2. Drag tvara to Applications and open it.
3. Pick a shortcut and choose what it can search. Every permission is optional.

Needs macOS 14 or later, Apple Silicon.

## Keys

| Key | Action |
| --- | --- |
| `⌘K` | open (change it in Settings) |
| `↑` `↓` | move |
| `↩` | open the result |
| `⇥` | browse by category |
| `esc` | back, then close |

## Privacy

Everything runs on your Mac. No account, no analytics.

Two things use the network:

- OpenAI, for natural-language queries, only if you add your own API key.
- Spotify's image server, for cover art on Spotify results.

## Build

```bash
scripts/fetch-clip-models.sh
scripts/build-app.sh
open ./tvara.app
```

Needs full Xcode and a code-signing certificate; set `SIGNING_IDENTITY`
in `scripts/build-app.sh`.

Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[AGPL-3.0](LICENSE)
