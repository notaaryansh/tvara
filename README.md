# tvara

**[trytvara.com](https://trytvara.com)**

> A new way to navigate your Mac.

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

## A new way to navigate your Mac

Every app on your Mac is yours. Every message you've sent, every photo
on your disk, every Mail thread, every Note, every link you copied last
Tuesday — all of it is sitting right here. You own it.

So why does finding any of it mean knowing which app it's in?

WhatsApp. iMessage. Discord. Mail. Notes. Photos. Browser history.
Clipboard. Each one a separate little searchbox, each one with its own
idea of what search should do, and you still have to remember which one
of them actually holds the thing you want. Your data is yours, but
navigating it feels like begging twelve different apps for permission
to look inside themselves.

There should be one box that knows about all of it. That's why tvara
exists.

`⌘K` from anywhere. Type what you remember — not what it was called.
The address Drish sent you last week. The photo with the dog at the
beach. The aws cli command from yesterday. The Chase email about your
card. Press `↩`. Done.

## Describe it. Find it.

You stop thinking in apps. You describe what you remember, and tvara
goes and gets it. Try:

- _"the message Sarah sent about the lease"_
- _"beautiful girl with glasses"_
- _"the chase email about my credit card last week"_
- _"that aws cli command I copied"_
- _"resume from 2026"_
- _"the transformers article I was skimming"_
- _"bluetooth settings"_
- _"snap this window to the top right"_
- _"send drish a message about this paragraph"_

Each one finds the thing on the first press. Across whatever app it
happens to live in. Photos by what's *in* them, not their filenames.
Messages by who, when, and what they were about — across WhatsApp,
iMessage, Discord at once. Emails, notes, clipboard history, browser
history, system settings, window layouts, all in the same textbox.

It gets sharper as you use it. Open the same result twice and tvara
remembers; the third time, it's at the top before you finish typing.

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
