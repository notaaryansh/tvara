# tvara

**One search box for your Mac, including your messages.**

[Download for Mac](https://github.com/notaaryansh/tvara/releases/latest) · [trytvara.com](https://trytvara.com)

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

Press `⌘K` anywhere, type a few letters, press `↩`. tvara opens your
apps and files like any launcher. It also searches the things other
launchers can't reach: your iMessage, WhatsApp and Discord
conversations, your mail, your notes, and what's inside your photos.

## Why tvara

**It finds what you said, not just what you saved.** "The address Sam
sent me" lives in a chat, not a file. tvara searches your message
history from the same box you launch apps from.

**It's fast.** Apps and commands match in under 5 ms, in the same frame
as your keystroke. Most other sources answer in 10–70 ms, and results
stream in as each one returns, so you never wait on the slowest.

**It's free and open source.** No account, no paid tier, no analytics.

## How it compares

| | tvara | Spotlight | Alfred | Raycast |
| --- | :---: | :---: | :---: | :---: |
| Searches WhatsApp messages | ✓ | – | – | – |
| Searches Discord messages | ✓ | – | – | – |
| Searches iMessage | ✓ | ✓ | – | – |
| Finds photos by what's in them | ✓ | ✓ | – | – |
| Snaps windows | ✓ | – | – | ✓ |
| Memory at idle | 36 MB | n/a | 29 MB | 57 MB |
| Open source | ✓ | – | – | – |
| Price | Free | Built in | Free, paid Powerpack | Free, paid Pro |

Built-in features only; Alfred and Raycast can add more through
workflows and extensions. Memory measured on an Apple M4, macOS 27; see
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) to reproduce it.

## What it opens and searches

- Messages: iMessage, WhatsApp, Discord
- Apps, files and folders
- Mail and Notes
- Photos, by what's in them ("dog at the beach")
- Clipboard history
- Browser history: Chrome, Arc, Brave, Edge
- System Settings panes
- Window snapping ("left half", "top right") and system actions
  (sleep, restart)

## Install

1. Download the latest `.dmg` from
   [Releases](https://github.com/notaaryansh/tvara/releases/latest).
2. Drag tvara to Applications and open it.
3. Pick your shortcut and choose what tvara can search. Every
   permission is optional.

Requires macOS 14 or later on Apple Silicon.

## Keys

| Key | Action |
| --- | --- |
| `⌘K` | open tvara (change it in Settings) |
| `↑` `↓` | move selection |
| `↩` | open |
| `⌘↩` | act on the selection (send a message, create an event) |
| `⇥` | browse by category |
| `esc` | go back, then close |

## Privacy

Search runs on your Mac, against each app's own local data. Photo
search uses an on-device model, so images never leave your disk.
tvara has no analytics and no account.

Natural-language queries and message drafting can use OpenAI, only if
you add your own API key. Without a key, none of your queries or data are
sent anywhere. The one other network request is cover art for Spotify
results, fetched from Spotify's image server.

## Build from source

```bash
scripts/fetch-clip-models.sh
scripts/build-app.sh
open ./tvara.app
```

You need Xcode (the full app, not just the Command Line Tools: the model
step uses its Core ML compiler) and a code-signing certificate in your
Keychain; set `SIGNING_IDENTITY` in `scripts/build-app.sh`. Signing
keeps macOS permissions from resetting on every rebuild.

How it's put together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[GNU Affero General Public License v3.0](LICENSE).
