# tvara

**[trytvara.com](https://trytvara.com)**

> Your Mac as one searchable surface. Stop hunting through twelve apps
> to find one thing.

![demo](Resources/demo.gif)

## A new way to navigate your Mac

Your Mac is not one computer. It is twelve computers stitched together
by ⌘Tab. Messages over here. Photos over there. Mail in its own world.
Notes, browser, clipboard, files — every one of them a separate place
you have to remember to look. The thing you want is always *somewhere*.
You just have to remember which somewhere.

tvara collapses all of it into one textbox.

`⌘K` from anywhere. Type what you remember — not what it was called.
The address Drish sent you last week. The photo with the dog at the
beach. The aws cli command you copied yesterday. The Chase email about
your card. Press `↩`. Done.

It is the launcher that replaces tab-switching with typing.

## What "everything" means

You don't think about which app it's in. You just describe what you
remember:

- _"the message Sarah sent about the lease"_ — searches WhatsApp +
  iMessage + Discord, deep-links to the exact thread
- _"beautiful girl with glasses"_ — finds the photo by what's *in it*,
  not its filename. On-device. No cloud upload, no tagging.
- _"the chase email about my credit card last week"_ — Apple Mail with
  natural-language time filters
- _"that aws cli command I copied"_ — pasteboard history, semantically
  recalled
- _"resume from 2026"_ — files + folders, via Spotlight's own index
- _"the transformers article I was skimming"_ — browser history across
  Chrome, Arc, Brave, Edge
- _"bluetooth settings"_ — every System Settings pane by name or alias
- _"snap this window to the top right"_ — Accessibility-API window
  management with a live snap-zone preview on the desktop
- _"send drish a message about this paragraph"_ — capture text from any
  app, compose, send. Without leaving the launcher.

It learns from you. Pick the same result twice and it surfaces first
next time. Press Tab to fan results into category cards if you want to
think by source instead of by relevance.

## Install

```bash
./build-app.sh
open ./tvara.app
```

Requires macOS 14+ and an Apple Development cert in Keychain (so TCC
grants persist across rebuilds).

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
