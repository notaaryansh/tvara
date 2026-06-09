# tvara

**[trytvara.com](https://trytvara.com)**

> A new way to navigate your Mac.

<p align="center">
  <img src="Resources/demo.gif" alt="tvara demo" width="100%" />
</p>

## A new way to navigate your Mac

Your messages, photos, emails, notes, browser history, and clipboard
all live on this disk. To find any one of them today, you open the
right app and use its searchbox. Twelve apps, twelve searchboxes,
twelve different ideas of what search should do.

tvara is one searchbox across all of them.

`⌘K` from anywhere. Type a few words. Press `↩`.

## What it searches

- Apps, files, folders
- Messages: WhatsApp, iMessage, Discord
- Mail
- Notes
- Clipboard history
- Browser history: Chrome, Arc, Brave, Edge
- Photos: on-device semantic image search (CLIP)
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
./scripts/build-app.sh
open ./tvara.app
```

**Requirements**

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)
- An Apple Development cert in Keychain. The build script signs the
  bundle with it so macOS TCC grants (Accessibility, Contacts, Full
  Disk Access, Automation) persist across rebuilds. Otherwise you'd
  re-click those prompts every time you rebuild. List yours with
  `security find-identity -v -p codesigning` and update
  `SIGNING_IDENTITY` in `scripts/build-app.sh`.

**First launch.** macOS will prompt for permissions in a batch. Grant
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

Per-keystroke fan-out across local sources: files via Spotlight's own
`mdfind`, messages via direct SQLite reads from each app's local store,
photos via on-device MobileCLIP semantic embeddings, mail via Apple
Mail's FTS index. Results stream into a single ranked list as each
source returns. You see the fastest hits in milliseconds while the
slower ones land underneath.

An optional natural-language planner (OpenAI today, on-device next)
routes ambiguous queries. For example, "address i sent sam last week"
gets parsed into source: messages, contact: sam, time: week,
search_term: "street address", so the right source gets the right query
without you thinking about it.

A frequency reranker watches which results you actually pick and
weights them up within their rank band. The launcher gets sharper
the more you use it.

## Privacy

Your data is yours. tvara is built to keep it local by default. We
think that's table stakes for any tool that touches your messages,
photos, and mail.

**What stays on your Mac.** All search across apps, files, messages
(WhatsApp / iMessage / Discord), Mail, Notes, browser history,
clipboard, and System Settings runs locally against each app's own
database or via macOS APIs. Photo semantic search uses MobileCLIP
running on-device via CoreML, so images never leave your disk. The
frequency reranker stores selection counts in
`~/Library/Application Support/tvara/` as local SQLite, never synced.

**What touches the cloud.** Two narrow paths use OpenAI today. Both are
BYOK (bring your own key; we don't proxy, broker, or aggregate keys)
and only fire when invoked:

- **Natural-language query planner** (`gpt-5.5`). When you type a query
  like _"the chase email about my credit card last week,"_ tvara sends
  *just the query string* to OpenAI to parse out source + contact +
  keywords + time. The structured plan comes back, and tvara searches
  your local data. Your actual messages, files, photos, and results
  never leave the machine.
- **Compose-action planner** (`gpt-5.5`). When you `⌘↩` on a result to
  draft a message or calendar event, tvara sends your action intent
  plus the snippet you're acting on (capped at 800 characters). Nothing
  else.
- **Discord semantic rerank** (`text-embedding-3-small`). For some
  Discord queries, tvara embeds the planner's distilled search term
  (e.g. _"street address"_) so it can rank pre-computed message
  vectors. Never raw message content. *This is a placeholder.* We're
  training a small on-device embedding model to replace OpenAI on this
  path; once it ships, even this distilled phrase stops leaving your
  Mac.

Without an API key configured, none of these fire. Natural-language
planning silently falls back to literal keyword matching against your
local data. The cloud paths are an *opt-in upgrade*, not a requirement.

**Local models, eventually.** The plan is to swap the cloud planner for
an on-device LLM. Honest tradeoffs today:

- Local 3B models via Ollama work, but our benchmarks
  (`experiments/bench_local_planner.py`) put them at ~3s per query vs
  OpenAI's ~500ms-1.5s.
- Smaller models classify the source correctly ~80% of the time vs
  near-100% for OpenAI.
- Apple's `FoundationModels` framework is the cleanest path forward
  (on-device, free, ~30-80ms) but requires macOS 26.
- Performance varies meaningfully by system: Apple Silicon vs Intel,
  RAM headroom, which model you've pulled.

So today: OpenAI is the default with BYOK. Anthropic/Claude as another
BYOK option is on the list. Local-LLM swap will ship as an opt-in once
the latency story is good enough on enough machines.

**Telemetry.** None. tvara doesn't phone home, doesn't track usage,
doesn't ping for updates, doesn't ship analytics. The only outbound
network calls are the OpenAI ones above, and only when you've provided
a key.

## Status

Active development. Some sources (Notion, Linear, Spotify) require API
keys; others (Messages, Mail, WhatsApp, Discord, Notes, Clipboard,
Photos) work out of the box once macOS permission prompts are granted
on first launch. The architecture is set; the polish is in flight.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free for personal, hobby,
research, and non-commercial-organization use. Commercial use reserved.
Commercial licensing: aaryanshsahay7@gmail.com.
