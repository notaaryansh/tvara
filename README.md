# tvara

**Open and search anything on your Mac. Fast, and light on memory.**

[Download for Mac](https://github.com/notaaryansh/tvara/releases/latest) · [trytvara.com](https://trytvara.com)

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

Press `⌘K` anywhere, type a few letters, press `↩`. One search box for
your apps, files, messages, mail, notes and photos.

## Why tvara

**It's fast.** Apps and commands match in under 5 ms, in the same frame
as your keystroke. Most other sources answer in 10–70 ms, and results
stream in as each one returns, so you never wait on the slowest.

**It's light.** tvara idles at about 150 MB with every source switched
on. Photo search loads its models only when you search photos and
frees them after five minutes.

Per-source numbers and how they were measured are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## What it opens and searches

- Apps, files and folders
- Messages: iMessage, WhatsApp, Discord
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
   permission is optional and nothing is requested until you click.

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
you add your own API key. Without a key, nothing is sent anywhere.

## Build from source

```bash
scripts/fetch-clip-models.sh
scripts/build-app.sh
open ./tvara.app
```

You need the Xcode Command Line Tools and a code-signing certificate in
your Keychain; set `SIGNING_IDENTITY` in `scripts/build-app.sh`. Signing
keeps macOS permissions from resetting on every rebuild.

How it's put together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[GNU Affero General Public License v3.0](LICENSE).
