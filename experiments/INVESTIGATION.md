# WhatsApp Mac — message-jump reverse engineering

Handoff document for a fresh agent picking up this thread.
**Status as of writing: no working URL has been found that scrolls and
highlights a specific message in WhatsApp Mac.**

---

## 1. The goal

Open WhatsApp on macOS to a **specific message inside a chat**, with the same
visual effect a user gets when they tap a notification or click an in-chat
search result — the message scrolls into view and gets a yellow/colored
flash-highlight.

We start with this data, all readable from outside WhatsApp:
- `ZSTANZAID` — the XMPP message identifier
- `ZFROMJID` / chat session JID
- `ZISFROMME` flag (boolean)
- Message text

We have NOT achieved the highlight. We've **eliminated** essentially every
public and many private/undocumented entry points.

---

## 2. Constraints set by the user

These three paths are **off-limits** and should NOT be proposed:
- **Frida + SIP disabled** — security implications, user rejected
- **Accessibility scripting (AX UI automation)** — user finds this "silly"
- **Shortcuts.app bridge** — user wants no one-time-setup story

The user wants a pure programmatic URL or IPC mechanism that "just works"
when Spotlight++ invokes it.

Whether such a mechanism exists is the open question. After 30+ probes we
have strong evidence the answer is **no**, but the user wants more
investigation before accepting that conclusion. A fresh agent should look
for angles not yet tried.

---

## 3. Tools used and why

| Tool | Why we used it | Install |
|---|---|---|
| `otool -ov` (preinstalled) | Dump Obj-C class metadata — properties, methods, IMP addresses | `xcode-select --install` |
| `otool -tV` | Disassemble specific addresses (raw ARM64) | same |
| `otool -l` | List sections + their VAs & file offsets — needed to translate VA→file offset for selref following | same |
| `strings -a` | Hunt URL patterns, comparison constants, identifier formats | base macOS |
| `nm -mU` | Symbol table — but WhatsApp is stripped, returns almost nothing | base macOS |
| `mdfind` | Probe CoreSpotlight to see what WhatsApp publishes | base macOS |
| `log stream` | Capture `os_log` from WhatsApp during manual navigation | base macOS |
| `sample <pid>` | Sample call stacks of running WhatsApp (use `/usr/bin/sample` — Python's `sample` package shadows it in pip-installed envs) | base macOS |
| `sqlite3` | Read WhatsApp's local databases (`ChatStorage.sqlite` etc.) | base macOS |
| `radare2` (r2) | Class enumeration via `ic`, function disassembly via `pdf`/`pdr`, IMP discovery | `brew install radare2` |
| `Ghidra` 12.1.1 | Full-binary decompile to C-pseudo. Headless analyzer accessible via `analyzeHeadless` in `/opt/homebrew/Cellar/ghidra/12.1.1/libexec/support/`. **WhatsApp's universal binary is 334MB**; analysis takes 60–120 minutes; we killed our run before it finished. | `brew install ghidra` |
| Python with `struct` | Manually translate VAs to file offsets, read selrefs (8-byte pointers in `__DATA,__objc_selrefs`), follow to selector strings in `__TEXT,__objc_methname`, decode CFString constants (32-byte structs in `__DATA,__cfstring` containing `isa, flags, str_ptr, str_len`) | base macOS Python 3 |
| Swift one-liners (`swift -e` / `swift /tmp/file.swift`) | Run AVFoundation/Intents code to probe APIs not exposed to bash | comes with Xcode |
| Frida 17.9.11 | Tried to attach to running WhatsApp — **blocked by hardened runtime** (`task_for_pid` permission denied). Would need SIP disabled. | `pip3 install frida-tools` |
| `curl` | Follow `wa.me/...` redirect chains, capture HTTP responses | base macOS |
| `brew` | Package installs | preinstalled on user's machine |

### Universal binary file-offset translation

WhatsApp's binary is a Mach-O universal binary (arm64 + x86_64). All
function addresses we work with are arm64-slice VAs (Virtual Addresses).
To read raw bytes at a VA from the file, you need:

1. Parse the fat header (`>I` magic at offset 0, `>I` nfat at offset 4).
2. For each fat arch, parse `cputype, cpusubtype, file_offset, size, align`
   (32 bytes per arch for `0xcafebabf` magic, 20 bytes for `0xcafebabe`).
3. arm64 cputype is `0x100000c`.
4. Walk the load commands via `otool -l -arch arm64` and parse the
   `Section` entries — each has an `addr` (VA) and an `offset` (within the
   slice).
5. To read VA X: find the section containing X, then
   `file_offset = arm64_slice_start + section.offset + (X - section.addr)`.

This is implemented in `experiments/resolve_selrefs.py` and
`experiments/dump_lcbu.py` — reuse those for any new function inspection.

---

## 4. Data model

### WhatsApp's local SQLite databases (all readable from outside WhatsApp)

Located at `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/`.

Key file: `ChatStorage.sqlite`.

The `ZWAMESSAGE` table identifier columns:

| Column | What | Example |
|---|---|---|
| `Z_PK` | Core Data primary key (int) | `58046` |
| `ZSTANZAID` | XMPP stanza ID — the message's WhatsApp identifier | `3A120D0906595971D3BE` |
| `ZDOCID` | CoreSpotlight document ID (assigned but unused — see §6) | `50039` |
| `ZSORT` | Sort order within chat | `25419` |
| `ZSPOTLIGHTSTATUS` | Internal flag; NOT macOS CoreSpotlight | small int |
| `ZFROMJID` | Sender JID | `198535031029815@lid` |
| `ZISFROMME` | Boolean — did this device send it | 0 / 1 |
| `ZMESSAGEDATE` | Apple absolute date (seconds since 2001-01-01 UTC) | float |

Stanza ID format hints from `Message.js` in `whatsapp-web.js`:
- iOS-sent: starts `3A`, 20 chars total
- Android-sent: > 25 chars
- Web-sent: shorter

### JID formats

`<id>@<server>` where server is one of:
- `c.us` — legacy 1:1 chat (older format)
- `s.whatsapp.net` — XMPP server JID
- `g.us` — group chat
- **`lid`** — Linked ID; modern privacy-preserving identifier. The phone is
  no longer embedded. We saw these in `ZWACHATSESSION.ZCONTACTJID` for all
  contacts in the test database.

### `_serialized` format from `whatsapp-web.js`

The full message reference is `<fromMe>_<remote>_<id>`:
- `fromMe`: `true` or `false`
- `remote`: chat JID
- `id`: stanza ID

Example: `false_198535031029815@lid_3A120D0906595971D3BE`

For groups, a 4th part (`senderJid`) is appended. Verified by reading
`src/Client.js:1757` in wwebjs which does `messageId.split('_')` and
asserts `params.length === 3 || params.length === 4`.

---

## 5. Internal capability — IT EXISTS

Selectors confirmed present in the WhatsApp binary via `otool -ov` and
`r2 ic`:

```
WAChatViewController- scrollToMessage:fromMessage:pushingOnStack:
WAChatViewController- scrollToMessage:fromMessage:pushingOnStack:messagesToHighlightAfterScroll:animated:
WAChatViewController- scrollToMessageInMessagesController:animated:messagesToHighlightAfterScroll:
WAChatViewController- openChatViewControllerFor:userContext:message:    ← takes message:!
WAChatViewController- notificationWindow:openChatWithMessage:inputText:
WAChatViewController- openChatWithJIDString:prefilledMessage:
WAChatViewController- openChatWithChatJID:
```

There's also a protocol literally named `WAScrollingToMessageProtocol` that
WhatsApp's view controllers implement.

The capability is real and present at the binary level. The question is
just how to invoke it from outside WhatsApp's process.

---

## 6. How we decompiled, step by step

### Step A — Class enumeration

```bash
r2 -qc 'ic*' /Applications/WhatsApp.app/Contents/MacOS/WhatsApp | grep -i DeepLink
```

This revealed **97 DeepLink subclasses** all inheriting from `WADeepLinkRoot`.
We initially analyzed only `WAMessageDeepLink` and `WACTWAParsedDeepLink`,
which led to a false-negative conclusion that no parser handles messages.
A fresh agent should sweep the rest.

Promising-named ones we have NOT exhaustively analyzed:
- `WANavigationDeepLink` — generic navigation, has `shortApiUrlFor:`
- `WAOpenChatDeepLink` — own parser at 0x1013dac08
- `WAMessageYourselfDeepLink`
- `WAContactDeepLink` — has `contactCode` AND `shouldStartChat` AND `qrDetectedType`
- `WASendDeepLink` — 700-byte parseURL (the one handling `whatsapp://send?`)
  has BRANCH paths for `wa_isShortAPILink`, `wa_isSendLinkCustomURL`,
  `ctwa_wame_message_support` that we did NOT fully trace

### Step B — Function disassembly via radare2

For any function at address `0xVA`:

```bash
r2 -qc "s 0xVA; af; pdf" $WA       # linear disassembly
r2 -qc "s 0xVA; af; pdr" $WA       # recursive (for branchy functions)
```

If `pdf` complains "Linear size differs too much from bbsum", use `pdr`.

To enable relocs (better selref resolution):
```bash
r2 -qc 'e bin.relocs.apply=true; aa; pdf' $WA
```

### Step C — Resolving selrefs (Python)

`r2` doesn't always show selector names. We wrote
`experiments/resolve_selrefs.py` which:

1. Parses fat header, finds arm64 slice file offset
2. Parses load commands via `otool -l`, builds section → file-offset map
3. For a given selref VA (e.g. `0x1082be480`), translates to file offset,
   reads 8-byte pointer, follows it to the C string in `__TEXT,__objc_methname`

This is HOW we discovered that `WAMessageDeepLink.parseURL:context:` calls
exactly these 11 selectors in order:

```
wa_deepLinkPathComponentAtPosition:    ← gets path[0]
lowercaseString
isEqualToString:                       ← compared to "message" (CFString @ 0x1081f13b8)
wa_contactCode                         ← THE message identifier extractor
wa_source
wa_app
appFromEntryPointApp:
deepLinkLogger
enableSessionId
paramHandler
parseParamsIfNeededWithUrl:
```

### Step D — Resolving CFString constants (Python)

Same Python machinery but for `__DATA,__cfstring`. Each CFString constant
is a 32-byte struct: `(isa, flags, str_ptr, str_len)`. We follow `str_ptr`
to the actual UTF-8 bytes elsewhere.

That's how we proved the comparison string in `WAMessageDeepLink.parseURL:`
at VA `0x1081f13b8` is literally `"message"`.

`experiments/resolve_selrefs.py` reads selrefs; the same logic with
CFString unpacking is in the inline `read_cfstring.py` we wrote at /tmp
(re-copy from this doc if you need it again).

### Step E — Function-level call-graph dump

`experiments/dump_lcbu.py` walks ARM64 instructions linearly in a function
body, identifies `adrp+ldr+bl objc_msgSend` patterns, and dumps the
sequence of selector names called. Used to compare `parseURL:` across
multiple DeepLink subclasses side-by-side. Output is in `experiments/runs/`.

### Step F — Ghidra (incomplete)

We started a headless Ghidra analysis but killed it before completion.
The command was:

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
  /opt/homebrew/Cellar/ghidra/12.1.1/libexec/support/analyzeHeadless \
  /tmp/ghidra_proj wa_project \
  -import /Applications/WhatsApp.app/Contents/MacOS/WhatsApp \
  -postScript experiments/decompile_parseURL.py \
  -scriptPath experiments
```

Expect 60–120 minutes for the 334MB binary. Generates thousands of
"Unsupported Objective C type encoding: <" warnings — non-fatal, ignore.
The `decompile_parseURL.py` script (kept in `experiments/`) extracts
C-pseudo for the specific functions we care about once analysis finishes.

A fresh agent should consider running this to completion.

---

## 7c. MASTER DISPATCH REGISTRY (round 3 decomp, 2026-05-30)

`WADeepLinkParser::deepLinkClassTypesWithContext:` at `0x101969a24` (2154 bytes)
constructs the FULL ordered list of parsers tried for every URL. First match
wins. The decomp is in `decompile_output/round3_20260530-202300.txt`.

Order (most-specific first):
- WAStatusShareDeepLink (always first, index 0)
- [AB] WADefaultMessagingDeepLink (index 0 if flag set)
- [AB] WAProxyV2DeepLink (index 1 if user_proxy_v2)
- Then 82-item static array (literal source order — see round3 decomp lines
  14806–15043 for the full list of `local_2c8 = …` assignments)
- DeepLinkTypeRegistry.allDeepLinkTypes (Swift-dynamic — additional handlers
  still unexplored, defined via `FUN_10197a5f5(<enum_case>)`)
- WACustomURLDeepLink (last/catch-all — biz+consumer username URLs)
- [AB] WASharableEventDeepLink (if events_v2_link_version > 0)

Fallback when nothing matches: WAUnknownDeepLink (the "doesn't exist" popup).

Key positions in the static array:
- #10 WAOpenChatDeepLink (`openchat`)
- #13 WASendDeepLink (`send`)
- #19 WANewsletterDeepLink — handles `whatsapp://c/X` (channels)
- #22 WAContactDeepLink (`qr`)
- #23 WAMessageDeepLink (`message`)
- #30 WAChatListDeepLink (`chats`)
- #58 WAUsernameDeepLink

Round 3 also confirmed via `.cxx_destruct` that WANewsletterDeepLink stores:
- `parsedCode` — channel code
- `parsedUpdate` — specific channel-post anchor ← URLs CAN target a channel post
- `parsedDeeplinkComponents`, `newsletterPDFN`, `deeplinkParsers`

The body of WANewsletterDeepLink::parseURL is a 17-byte Swift stub (tail call
to FUN_1019bf8bf), so the exact host/path it accepts can't be read from
ObjC-level decomp. Would need Swift-aware disassembly.

---

## 7b. ARCHITECTURAL CEILING — binary-confirmed (2026-05-27)

After full decompile of all 12 `WA*DeepLink::parseURL:context:` implementations and
their `handleDeepLinkWithRootVC:` follow-ups, the verdict is binary-final:

**No public URL form reaches `[WAChatPresenter forMessage:searchTerms:style:]`.**

That selector — the one that produces the yellow search-highlight — is invoked from
exactly ONE place in the binary:

```
WAMessageNotificationCenter::notificationWindow:openChatWithMessage:inputText:
  → WAChatPresenter forMessage:<WAMessage*> searchTerms:nil style:2
  → [WAApplication.wa_delegate] openChatWithPresenter:presenter animated:NO ...
```

Every URL path-handler we traced — `openchat`, `send`, `message`, `chat`, `qr`,
`navigate`, `chatlist`, `messageyourself`, `externalmediashare`, `oauthcallback`,
`statusshare`, `sharewhatsappweb` — terminates in one of these two patterns:

1. **JID-only presenter** via `chatPresenterFactory.forJID:userContext:` →
   `openChatWithPresenter:animated:NO` (opens at bottom, no highlight).
   Used by `WAOpenChatDeepLink::openChatWithChatJID:` (the openchat URL).

2. **CTWA presenter** via `CTWAChatNavigationHelper.getChatPresenterWithJid:...` —
   server-validated JWT flow only. No message context.

The `pathComponents[2]` (second segment) we tested in
`whatsapp://openchat/<jid>/<serialized>` is **never read** by the parser — only
`pathComponents[1]` (the JID) is used. Any "flash" observed from a 2-segment URL
is the chat-already-foreground re-presentation, not a parser recognizing the
serialized format.

**Closing the URL door:** the only externally-reachable highlight path would require:
- Direct invocation of `notificationWindow:openChatWithMessage:` (in-process — Frida)
- Or constructing a `WAChatPresenter` with `forMessage:searchTerms:style:2` (in-process)
- Or NSE-style notification synthesis (entitlement-gated, can't be done externally)

All three were ruled out by the user's constraints (no Frida, no SIP-off, no
Shortcuts, no Accessibility).

**Spotlight++ implication:** open-to-chat via `whatsapp://openchat/<jid>` is the
ceiling for the native flow. Users land in the chat and use WhatsApp's own
in-chat search (⌘F) to reach the message. For true scroll-to-highlight, the
WhatsApp Web WKWebView fallback in §11.H is the only remaining path.

---

## 7a. NEW WORKING URL FORMS (discovered via Ghidra decompile, 2026-05-30)

**Confirmed working — `whatsapp://openchat/<JID>` (path-based, no query):**
```
whatsapp://openchat/919325525029@s.whatsapp.net   → opens drishtu's chat ✓
```

This is the **actual** format `WAOpenChatDeepLink.parseURL:` accepts (host == `openchat`,
JID at pathComponents[1]). Distinct from `whatsapp://chat?jid=X` which also works but
routes through a different DeepLink subclass.

We previously tested `whatsapp://open-chat?jid=X` (with hyphen, query-style) which
silently fell through. The hyphen is wrong — must be `openchat` (one word).

**Other forms revealed by decompile (need to retest individually):**
- `whatsapp://qr/<contactCode>?ref=invite` — WAContactDeepLink (QR contact code; same WAMO server-validation issue)
- `whatsapp://message/<X>?token=<Y>` — routes through WASendDeepLink's CTWA-WAME branch instead of WAMessageDeepLink, gated by `ctwa_wame_message_support` AB flag
- `whatsapp://send/<X>?token=<Y>` — same WASendDeepLink branch via the "send" host

The `?token=<X>` query parameter is a JWT token in the CTWA flow (Click-To-WhatsApp Ads). 
Server-signed tokens. Can't be forged externally, but we may be able to capture one from 
a legitimate ad-link interaction.

---

## 7. Key findings from decompile

### `WAMessageDeepLink.parseURL:context:` at `0x1013d9dd0`

Routes `whatsapp://message/<X>` URLs. The full logic:

```
1. path0 = url.wa_deepLinkPathComponentAtPosition(0)
2. if path0.lowercased() == "message":
3.   path1 = url.wa_deepLinkPathComponentAtPosition(1)
4.   if path1 == nil: return (give up)
5.   contactCode = url.wa_contactCode      ← SERVER-VALIDATED token
6.   [analytics: wa_source, wa_app, sessionId, etc.]
7.   resolve contactCode via xmppConnection (server lookup)
8. else: return (URL not a message deeplink)
```

### `WADeepLinksProvider.contactCodeForMessageDeepLinkWithUrl:context:` at `0x1013f6148`

Helper that extracts the contact code. Calls into Swift runtime.

### `WACTWADeepLinkValidator.linkCanBeUsedToOpenChat` at `0x101078e04`

Validates if a URL can open a chat. Calls `logCTWATokenVerificationState:failureReason:`
— so VERIFICATION of CTWA tokens is part of this. CTWA = Click-To-WhatsApp Ads.

### `WACTWADeepLinkValidator.sanitizedText:` at `0x101079074`

Used by `WASendDeepLink` to clean the prefilled message text.

### `WASendDeepLink.parseURL:context:` at `0x1013db804` (700 bytes — BIGGEST parser)

Selectors called:
```
wa_deepLinkPathComponentAtPosition:    ← supports PATH-based URLs (we mostly tested query-only)
lowercaseString
wa_queryItems
objectForKeyedSubscript:
ctwa_wame_message_support              ← AB property check — enables CTWA+WAME flow
initWithRawURL:userContext:
wa_isSendLinkCustomURL                 ← custom URL form
sanitizedText:
linkCanBeUsedToOpenChat
wa_isShortAPILink                      ← wa.me / api.whatsapp.com short form
```

**A fresh agent should trace ALL branches in this function**, not just the
`phone=` query path. The function is large enough to have multiple
different URL formats it accepts.

---

## 8. Externally-reachable methods (from `WADeepLinkRoot` baseProperties)

`WADeepLinkRoot` is the BASE class whose subclasses each implement
`parseURL:` differently. Its baseProperties define the URL parameter
vocabulary the base supports. Full list (47 properties):

```
unparsedURL, isSourceAccountCoveredByIndiaJurisdiction, hasIcebreakers,
hasWelcomeMessage, showKeyboard, allowedSignals, app, context, data,
dataFilterRequired, entryPoint, icebreaker, jid, landOnCatalog,
landOnWhatsappProfile, lid, phone, username, productId, source, sourceUrl,
text, trackingPayload, reliabilityActions, banner, alwaysShowAdAttribution,
flowCtaText, medium, useAutomatedGreetingMessage, exemptFrom1pdDisclosure,
contextDetails, automatedGreetingMessageCTAType,
automatedGreetingMessageCTAPayload, redirectDeepLink,
icebreakersOverrideToPrefill, website, agmThumbnailStrategy,
agmTitleStrategy, agmSubtitleStrategy, agmHeaderInteractionStrategy,
adPreviewUrl, useDraftForNewThread, useIcebreakerRedesign, sourceId,
flowAutoResponseText, flowAutoResponseCtaType, flowAutoResponseCtaUrl
```

**Caveat:** These are properties on the *base* class. SUBCLASSES may add
more. We have NOT confirmed each subclass's full property list.

---

## 9. Internal navigation methods — all take Message objects

Every internal "scroll to specific message" method takes a `Message *`
pointer, not a stanza ID string. Cannot be called from outside without
constructing a Message object inside WhatsApp's process.

| Method | Class | Takes |
|---|---|---|
| `notificationWindow:openChatWithMessage:inputText:` | `WAMessageNotificationCenter` | `Message*` |
| `notificationWindow:openChatWithMessage:inputText:` | `WAInAppNotificationWindowProxy` | `Message*` |
| `notificationWindow:openChatWithMessage:inputText:` | `WAStatusNotificationCenter` | `Message*` |
| `openChatViewControllerFor:userContext:message:` | `WAPaymentHelper` | `Message*` |
| `showMessage:` | `WAMediaBrowserViewController` | `Message*` |
| `scrollToMessage:...` | `WAChatViewController` | `Message*` |

The Message object construction requires looking up the local store
(`WAWebCollections.Msg.get` in JS, or `WAMessageStore` in native) — which
is in-process only.

---

## 10. Things we tried and how each was eliminated

In order of exploration:

### 10.1 URL query parameter variants

Tested every plausible parameter name with the raw stanza and full
serialized forms:

```
msg, msgId, msgKey, msgKeyId, messageKey, messageId, message_id,
id, key, ctx, q, search, query, text, stanzaId
```

Against URL paths:
```
whatsapp://send?phone=X&PARAM=Y
whatsapp://chat?jid=X&PARAM=Y
whatsapp://message/X
whatsapp://msg?id=X
whatsapp://chats?jid=X&PARAM=Y
```

All silently dropped or produced the same empty OK popup.

### 10.2 URL path-based variants

```
whatsapp://send/<phone>
whatsapp://send/<stanza>
whatsapp://send/<serialized>
whatsapp://send/<phone>/<stanza>
whatsapp://message/<stanza|serialized>
whatsapp://c/<stanza>
whatsapp://contact/<stanza>
whatsapp://chat/<jid>
whatsapp://open-chat?jid=X&msg=Y
whatsapp://navigate/message/<X>
whatsapp://goto/message/<X>
whatsapp://p/<X>
```

All either silently ignored, produced empty popup, or in one case produced
"The phone number +15550001111 isn't on WhatsApp" — but we could NOT
identify which URL specifically triggered that (it's a parser bug where
some path-based URL got mis-extracted as the placeholder fake number).

A fresh agent should rerun `experiments/url_probe.py --only N` for each
path-based send URL one at a time and isolate which produces the
+15550001111 popup. That tells us what the parser is mis-extracting and
gives us a hint at the correct format.

### 10.3 Other URL schemes

```
wa://send|chat|message — kLSApplicationNotFoundErr (not registered)
whatsapp-consumer://chats — opens app, no nav
whatsapp-smb://* — kLSApplicationNotFoundErr (not registered on consumer build)
https://wa.me/c/<X> — opens browser, server returns 404 for invalid contact codes
https://wa.me/message/<X> — opens browser, browser opens api.whatsapp.com/resolve which returns 404
```

### 10.4 SiriKit + NSUserActivity

Constructed `INSearchForMessagesIntent` via Obj-C runtime
(`NSClassFromString` since the class is marked API_UNAVAILABLE(macos) in
the public SDK but exists in the framework binary). Set `identifiers`,
`conversationIdentifiers`, `searchTerms` via KVC. Wrapped in
`NSUserActivity` with `targetContentIdentifier = "net.whatsapp.WhatsApp"`.
Called `becomeCurrent()` then `NSWorkspace.openApplication(at:configuration:)`.

WhatsApp launched but did NOT process the activity. macOS only delivers
user activities cross-app via Siri voice / Shortcuts / Spotlight click /
Handoff — none of which we control programmatically.

Code: `experiments/jump_probe2.swift` style probes (re-create from history
in `~/.bash_history` or rebuild from this doc).

### 10.5 XPC services

Probed 6 candidate Mach service names via `NSXPCConnection`:
```
net.whatsapp.WAAppKitBridge
net.whatsapp.WAAppKitBridgeService
net.whatsapp.WAAppKitBridgeServiceHost
net.whatsapp.MacPlugin
net.whatsapp.WhatsApp
net.whatsapp.WhatsApp.MacPlugin
```

All rejected. Confirmed via `launchctl list` that only Sparkle (auto-updater)
publishes user-visible Mach services.

### 10.6 CoreSpotlight

`mdfind 'kMDItemCFBundleIdentifier == "net.whatsapp.WhatsApp"'` returns only
the app bundle itself. WhatsApp does NOT publish chats/messages to macOS
CoreSpotlight. The `ZSPOTLIGHTSTATUS` column in `ZWAMESSAGE` is for
WhatsApp's internal FTS5 index at `fts/ChatSearchV5f.sqlite`, NOT macOS
CoreSpotlight.

### 10.7 NSDistributedNotificationCenter

`strings | grep -i DistributedNotif` returns zero matches in WhatsApp's
binary. WhatsApp does not observe cross-process notifications.

### 10.8 os_log capture during manual navigation

```bash
/usr/bin/log stream --predicate 'process == "WhatsApp"' --level debug
```

Capture during manual in-chat search → click. Got 52,627 lines but ZERO
app-specific subsystem entries. WhatsApp's release build emits no app
log entries during navigation. Only system framework noise.

### 10.9 `sample` of running process

`/usr/bin/sample <pid> 15` while user manually navigates to a specific
message. Binary is **symbol-stripped** — only exported symbol is
`XPluginsGetFuncPtr`. All WhatsApp frames show as offsets from that.
Useless for selector-level analysis without manually mapping offsets to
method names via `otool -ov`.

### 10.10 AppleScript dictionary

No `.sdef` file in `/Applications/WhatsApp.app/Contents/Resources/`.
No declared AppleScript commands. No raw Apple Event handlers found via
binary string search (`kAEOpenDocuments`, etc.).

### 10.11 Frida runtime hook

`pip3 install frida-tools`. Attempt to attach:
```python
frida.attach(43440)  # WhatsApp PID
```

Returns `unable to access process from the current user account`.
Hardened runtime + lack of `com.apple.security.get-task-allow` entitlement.
User declined SIP-disable workaround.

Frida scripts ready to use once SIP is off:
- `experiments/01_check.py` — verifies attach
- `experiments/02_hook.py` — hooks `scrollToMessage:`, `parseURL:`, etc.,
  and prints call args + backtrace
- `experiments/hooks/scroll_to_message.js` — the Frida JS

### 10.12 Systematic URL catalog probe

`experiments/url_probe.py` — 30 URL forms covering query+path variants
across `whatsapp://`, `whatsapp-consumer://`, `wa.me/`. Run all in auto
mode:

```bash
python3 url_probe.py --auto --delay 2.5
```

Or one specific URL by catalog index:

```bash
python3 url_probe.py --only 7  # whatsapp://send/<stanza>
```

Results saved to `experiments/runs/<timestamp>/results.txt`. None produced
the highlight on a fresh state.

---

## 11. Where a fresh agent could still look

### A. Branches inside `WASendDeepLink.parseURL:` at `0x1013db804`

This is the BIGGEST parseURL (700 bytes) and we only proved one branch
(`phone=` query). The selector list reveals at least 3 other branches:

- `wa_isShortAPILink` — wa.me / api.whatsapp.com forms
- `wa_isSendLinkCustomURL` — "custom URL" form (unknown what this means)
- `ctwa_wame_message_support` — CTWA + WAME branch (gated by AB flag)

Find the IMPLEMENTATION of these three NSURL category methods (search for
`wa_isShortAPILink` IMP in `r2 ic` output). Read what URL patterns each
returns true for. Test those patterns.

### B. Other DeepLink subclasses' `parseURL:`

97 subclasses, we deeply analyzed maybe 6. Names worth disassembling:
- `WANavigationDeepLink` (`0x1014255e0`)
- `WAOpenChatDeepLink` (`0x1013dac08`)
- `WAContactDeepLink` (`0x1013d43ec`)
- `WAMessageYourselfDeepLink` (`0x1013fbb4c`)
- `WAChatListDeepLink` (`0x1013d3d04`)
- `WAExternalMediaShareDeepLink`
- `WAShareWhatsAppWebDeepLink`
- `WAOAuthCallbackDeepLink`
- `WAStatusShareDeepLink`

### C. The `+15550001111` mystery

One of the path-based send URLs (catalog index 6–9 in `url_probe.py`)
caused WhatsApp to show "The phone number +15550001111 isn't on WhatsApp."
This is a real popup with a real (mis-extracted) phone number. We need to:

1. Run each path-based send URL individually (`--only 6`, `--only 7`, etc.)
2. Identify which produces that popup
3. The URL that produces it is being PARSED by `WASendDeepLink` and the
   parser is treating part of our path as a phone number — but extracting
   it wrong
4. Understanding the (wrong) extraction tells us the (correct) format

### D. Ghidra full decompile

Run to completion (~90 min). Then use the
`experiments/decompile_parseURL.py` script to extract C-pseudo for every
`*DeepLink.parseURL:context:`. Diffing the parsers will reveal
under-explored URL patterns much faster than manual disassembly.

### E. The CTWA / WAME message support flow

The AB flag `ctwa_wame_message_support` is checked inside
`WASendDeepLink.parseURL:`. When TRUE, an alternative code path runs. We
do not know what URL FORMS that path accepts. CTWA = Click-To-WhatsApp Ads
(Meta's ad → WhatsApp routing flow). WAME = WhatsApp Marketing Encoded.

There's a class `WACTWAParsedDeepLink` (identical 47-property surface to
`WADeepLinkRoot`) that may have its own subclasses with message routing.

### F. `XWAExternalCTXAuthoriseWAChatHandler`

String `Invalid JWT token format:` exists in the binary. The handler
class is `XWAExternalCTXAuthoriseWAChatHandler` (in `WACTWA` module).
GraphQL request classes around it:

```
XWAExternalCTXAuthoriseWAChatGraphQLRequest
XWAExternalCTXAuthoriseWAChatGraphQLResponse
XWAExternalCtxAuthoriseWAChatRequest
```

This is an EXTERNAL handler that takes a JWT token to authorize chat
access. JWT tokens are server-issued and signed. Can't be forged. But —
if we could find a way to get a valid CTWA JWT for one of OUR chats,
this might be a working path.

The JWT-with-query-param flow is gated by `ctwa_enable_jwt_token_with_query_param`.
That AB flag's default state is unknown.

### G. Notification payload synthesis

The internal notification handler dispatches to `scrollToMessage:` when
WhatsApp processes an APN notification. The payload keys are:
`message_id`, `chat_jid`, `conversation_id`, `sender`, `notification_id`,
`category_id`. These are the EXACT routing fields the URL parser is missing.

APN delivery is gated by Meta's APN cert (can't synthesize from outside).
BUT — if there's a way to deliver a notification with these fields via:
- Notification Service Extension impersonating WhatsApp (entitlement-gated)
- Local notification with cross-app routing (no public API on macOS)
- Distributed notification observer that some internal class watches —
  worth searching for one more time

This is the path most likely to bear fruit if any does. The internal
selector signatures are:
- `userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:`
- `messageNotificationTappedWithAccountUUID:notificationID:`
- `logNotificationTappedToOpenWithMessageID:userInfo:isFromNSE:`

### H. WhatsApp Web embedded WebView (different architecture)

`whatsapp-web.js`'s `InterfaceController.openChatWindowAt(serialized_msg_id)`
WORKS on WhatsApp Web. It uses internal JS modules:
- `window.require('WAWebCollections').Msg.get(msgId)`
- `window.require('WAWebChatMessageSearch').getSearchContext(chat, msg.id)`
- `window.require('WAWebCmd').Cmd.openChatAt({ chat, msgContext })`

If we embed a WKWebView with `web.whatsapp.com` in Spotlight++,
authenticate once via QR, and inject those JS calls — we get real
message-jump capability. But the user wants the native app to navigate,
not a WebView. This is a fallback that should be raised again if all
native paths are exhausted.

---

## 12. Files in this directory

```
experiments/
├── INVESTIGATION.md          ← this file
├── README.md                 ← short overview, points here
├── 01_check.py               ← Frida attach test (blocked, ready when SIP off)
├── 02_hook.py                ← Frida runtime hook (blocked)
├── hooks/scroll_to_message.js← Frida JS for hooking scrollToMessage:
├── decompile_parseURL.py     ← Ghidra script (run with `analyzeHeadless`)
├── resolve_selrefs.py        ← VA → file offset → selector name resolver
├── url_probe.py              ← Systematic URL catalog tester (30 URLs)
└── runs/<timestamp>/         ← Output from url_probe runs
    └── results.txt
```

Reusable Python utilities for binary inspection embedded inline in this
doc (see §3 universal-binary translation, §6 step C selref resolution, §6
step D CFString unpacking). Copy out as needed.

---

## 13. Concrete next steps for a fresh agent

In rough priority order:

1. **Isolate the +15550001111 URL.** Run `url_probe.py --only N` for N in
   6..9 (the path-based send URLs). The one producing that popup is the
   key to understanding WASendDeepLink's path parser.

2. **Disassemble `WANavigationDeepLink.parseURL:` at 0x1014255e0** the same
   way we did `WAMessageDeepLink` — get the selectors called, find the
   compared CFString constants, deduce the URL form.

3. **Find IMPs for `wa_isShortAPILink` and `wa_isSendLinkCustomURL`** —
   these are NSURL category methods. Search `r2 -qc 'ic NSURL' $WA` and
   `r2 -qc 'is~wa_is' $WA`. Disassemble each. They tell us EXACTLY which
   URL forms enter the alternate branches of WASendDeepLink.

4. **Run Ghidra full decompile** in the background while doing other work.
   When it finishes, the `decompile_parseURL.py` script gives C-pseudo
   for the 5–10 parser functions and we can read them in 30 min instead
   of 30 hours.

5. **If steps 1–4 yield nothing new**: the architectural verdict
   (no native message-jump from external URL) is binary-confirmed. Move
   to the WhatsApp Web WebView fallback (§11.H) which is a real working
   path, or to the inline-preview product approach.

Good luck. The capability genuinely exists internally — we just haven't
found the entry point. Almost everything has been ruled out; the gap is
narrow but real.
