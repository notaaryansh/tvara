# Discord IPC Integration — Plan

> **Status:** Not implemented. This document captures the design we agreed
> on so a future session can pick it up. The current Discord integration
> relies entirely on parsing Discord's HTTP cache and Local Storage, which
> caps coverage at ~44% of messages (channels Discord cached metadata for)
> and 87 guild names (out of ~110 guilds the user is in). The remaining
> coverage requires a fundamentally different data source — and Discord's
> IPC socket is the realistic path.

## What Discord IPC Is

Discord, while running, listens on a Unix domain socket at
`/tmp/discord-ipc-0` (it tries slots `0` through `9` for fallback). Any
local process can connect and exchange framed JSON-RPC messages with
Discord. The protocol is officially documented under Discord's RPC docs.

This is the same channel game integrations, voice overlays, OBS plugins,
and Streamdeck use. It is **not** the same thing as bot-account scraping
or self-botting via the user's auth token — those are TOS violations.
IPC is a sanctioned read-only extension API gated by an explicit user
authorization step.

## Why We Need It

Cache-only extraction hits a ceiling because Discord's REST endpoints
that would give us full guild/channel metadata (`/api/v9/users/@me/guilds`,
`/api/v9/guilds/<id>/channels`) are served with `Cache-Control: no-store`
and never get persisted. The data only ever lives in Discord's in-memory
Redux store, which is unreachable from another process.

Things IPC unlocks that the cache cannot:

- **All ~110 guild names**, not just the 87 we can scrape from incidental
  embeds.
- **Every channel in every guild**, with type + position info, not just
  the 171 we can infer via propagation.
- **Direct message channels** for every user, not just the ones we've
  recently opened.
- **Stays fresh** — IPC always reflects the current state, not stale
  cache.

Practically: pushes resolved messages from ~44% → near 100%.

## Setup Requirements

This is a one-time setup the user does, not us:

1. Go to https://discord.com/developers/applications, click
   **New Application**, name it `spotlight++`, copy the **Application ID**
   (also called Client ID).
2. We embed that Client ID as a constant in `DiscordIPCService.swift`.
3. On first launch after the integration ships, Discord pops a dialog
   inside its own window: *"spotlight++ wants to read your servers and
   channels — Allow?"* The user clicks Allow once. Discord remembers
   forever.

There is no recurring cost: no token to rotate, no OAuth refresh, no
account to keep healthy. The Client ID is public; it identifies the app,
not the user.

## What the User Gets

Same UI as today. Internally:

- Discord tab counts go up (more channels with metadata → more messages
  resolve to a server).
- Message rows show **real server + channel names** instead of falling
  through to the sender-name title.
- Server icons populate for the ~25 guilds whose icons aren't in cache.
- Cold-start coverage no longer depends on which channels the user has
  recently opened.

## Implementation Outline

### Architecture

```
DiscordIPCService (actor)
  ↓ uses
UnixSocketTransport          ← raw IO over /tmp/discord-ipc-{0..9}
  ↓ uses
IPCFraming                   ← 4-byte opcode + 4-byte length + JSON body
```

`DiscordIPCService` runs alongside the existing `DiscordService` cache
parser. On launch:

1. IPC service connects to the socket, authenticates, fetches
   `GET_GUILDS` → `GET_CHANNELS` for each guild, writes results into the
   **same SQLite tables** (`guilds`, `channels`, `users`) used by the
   cache parser.
2. The cache parser keeps running for messages (IPC doesn't give us
   message content — that's a restricted scope only verified apps get).
3. Search SQL is unchanged. It already JOINs against `guilds` and
   `channels`; we just have richer data in those tables.

### Wire Protocol

Each frame:

```
+--------+--------+----------+
| op (4) | len(4) | json[len]|
+--------+--------+----------+
```

Both fields are little-endian uint32. Op codes:

| Op | Direction | Meaning |
|----|-----------|---------|
| 0  | →         | HANDSHAKE (initial) |
| 1  | ↔         | FRAME (request/response) |
| 2  | ←         | CLOSE |
| 3  | →         | PING |
| 4  | ←         | PONG |

### Handshake

```json
{
  "v": 1,
  "client_id": "<our app id>"
}
```

Discord responds with a READY frame on op 1. If the user has not yet
authorized our app, the next request triggers the consent UI inside
Discord; on Allow, all subsequent requests succeed.

### Useful Commands (op = 1)

#### List user's guilds
```json
{
  "cmd": "GET_GUILDS",
  "nonce": "<uuid>",
  "args": {}
}
```
Response includes `data.guilds: [{id, name, icon_url}, ...]`.

#### List channels in a guild
```json
{
  "cmd": "GET_CHANNELS",
  "nonce": "<uuid>",
  "args": { "guild_id": "<id>" }
}
```
Response: `data.channels: [{id, name, type, position}, ...]`.

#### Get a single channel
```json
{
  "cmd": "GET_CHANNEL",
  "nonce": "<uuid>",
  "args": { "channel_id": "<id>" }
}
```

### Sync Strategy

- On Discord IPC ready: enumerate guilds → enumerate channels per guild
  → bulk UPSERT into our SQLite (the existing conditional upsert handles
  merging with cache-derived rows safely).
- Re-sync triggered when: (a) spotlight++ launches, (b) Discord launches
  while spotlight++ is open (detect via `NSWorkspace`
  `didLaunchApplicationNotification`), (c) every 5 minutes while Discord
  is running.
- If IPC isn't available (Discord not running, socket missing), silently
  fall back to cache-only behavior — never a hard failure.

## What IPC Does NOT Give Us

Worth flagging so we don't over-promise:

- **No message history.** The `READ_MESSAGE_HISTORY` scope is gated to
  verified app types. Our message search keeps coming from cache parsing
  for the foreseeable future.
- **No avatars beyond what we already have.** IPC returns `icon_url`s
  for guild icons; we'd still download separately or keep using cache.
- **No realtime message events.** IPC supports subscribing to events
  like `MESSAGE_CREATE`, but again only for verified apps.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Discord renames IPC commands in a future build | Wrap each command call in a feature-detect: if command fails with "unknown", log and fall back |
| User denies authorization | Cache-only mode keeps working; we surface a "Re-authorize Discord access" item in settings |
| `/tmp/discord-ipc-*` paths change on macOS | Try all 10 socket numbers; if none open, mark IPC unavailable; we never crash |
| User has multiple Discord installs (stable + canary + ptb) | Each registers on a different socket index; we just connect to the first that responds to handshake with our client_id |

## Estimated Effort

- `UnixSocketTransport` (raw socket + framing): ~80 lines
- `DiscordIPCService` (handshake, command queue, response correlation): ~120 lines
- Integration into `DiscordService` (bulk upsert): ~30 lines
- Error paths, retries, watchdog: ~20 lines
- **Total: ~250 lines of Swift**, no external dependencies

One-time user setup (Discord app registration): ~30 seconds.

## When to Build This

Build it when either of these is true:

1. Discord coverage <44% becomes painful enough that the user explicitly
   notices missing context on common queries.
2. We want to ship spotlight++ to other users — at that point the
   per-machine cache-fill-up variation makes Discord coverage feel
   unreliable, and IPC normalizes the experience.

Until then, the cache-only approach with the propagation harvester is
"good enough" for most queries and ships without any external setup.
