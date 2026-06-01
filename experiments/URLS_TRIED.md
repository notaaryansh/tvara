# WhatsApp Mac URL catalog — every form tried

Hand-test these manually. Constants used in examples (replace as needed):

```
PHONE   = 919325525029
JID     = 919325525029@s.whatsapp.net
LID     = 198535031029815@lid
STANZA  = 3A8D5E50D816940D7DC5
SER     = false_919325525029@s.whatsapp.net_3A8D5E50D816940D7DC5
```

Fire with `/usr/bin/open '<url>'` or paste into Safari address bar.

Legend for observed:
- **opens chat** = lands in drishtu's existing conversation, no highlight
- **flash** = chat view briefly flashes/blinks then settles (no highlight)
- **starting popup** = "Starting chat" loading popup briefly visible
- **empty popup** = generic "OK" popup with no text
- **composer** = new-chat composer with prefilled text
- **error popup** = explicit error message
- **just opens WA** = WhatsApp foregrounds but no chat-state change
- **silent** = nothing observable
- **not tested** = we haven't actually fired this yet

---

## 1. openchat host — confirmed working chat-open

| URL | Observed |
|---|---|
| `whatsapp://openchat/919325525029@s.whatsapp.net` | opens chat ✓ |
| `whatsapp://openchat/198535031029815@lid` | opens chat ✓ |
| `whatsapp://openchat/919325525029` (phone only, no @) | server lookup error popup |
| `whatsapp://openchat/3A8D5E50D816940D7DC5@s.whatsapp.net` | error: "phone +3A8D... isn't on WhatsApp" |
| `whatsapp://openchat/3A8D5E50D816940D7DC5@c.us` | not tested individually |
| `whatsapp://openchat/3A8D5E50D816940D7DC5` (raw stanza) | not tested individually |
| `whatsapp://openchat/<SER>` (serialized) | not tested individually |

### 1a. openchat + 2nd path component

| URL | Observed |
|---|---|
| `whatsapp://openchat/<JID>/<STANZA>` | just opens WA (no flash) |
| `whatsapp://openchat/<JID>/<SER>` | **flash** ← repeatable signal |
| `whatsapp://openchat/<JID>/<LID-serialized>` | **flash** |
| `whatsapp://openchat/<JID>/somejunkrandompath` | not tested individually |

### 1b. openchat + query params

| URL | Observed |
|---|---|
| `whatsapp://openchat/<JID>?msg=<STANZA>` | flash (likely re-presentation, not parse) |
| `whatsapp://openchat/<JID>?stanza=<STANZA>` | flash |
| `whatsapp://openchat/<JID>?messageId=<STANZA>` | flash |
| `whatsapp://openchat/<JID>?msgKey=<SER>` | flash |
| `whatsapp://openchat/<JID>?aaa=bbb` (garbage control) | **not tested** — fire this to compare |

> Critical control test: fire a bare `whatsapp://openchat/<JID>` while the chat is NOT foregrounded, then a `?aaa=bbb` form. If both behave identically, the "flash" from msg/stanza queries is pure re-presentation. If the garbage param doesn't flash but `?msg=` does, that's a real parser signal.

---

## 2. message host — server contact code only (WAMO)

| URL | Observed |
|---|---|
| `whatsapp://message/3A8D5E50D816940D7DC5` (raw stanza) | empty popup |
| `whatsapp://message/<SER>` | empty popup |
| `whatsapp://message/false_919325525029@c.us_<STANZA>` | empty popup |
| `whatsapp://message/false_198535031029815@lid_<STANZA>` | empty popup |
| `whatsapp://message/<contactCode>?token=<JWT>` (CTWA-WAME branch) | needs real JWT — not testable externally |

> WAMessageDeepLink requires a server-validated WAMO contact code (alphanumeric short string issued by WhatsApp's backend). Cannot be forged.

---

## 3. send host — composer / CTWA

| URL | Observed |
|---|---|
| `whatsapp://send?phone=919325525029` | new-chat composer ✓ |
| `whatsapp://send?phone=919325525029&text=hello` | composer prefilled |
| `whatsapp://send?phone=919325525029&msg=<STANZA>` | composer (msg ignored) |
| `whatsapp://send?phone=919325525029&msgKey=<SER>` | composer (key ignored) |
| `whatsapp://send?phone=919325525029&id=<STANZA>` | composer (id ignored) |
| `whatsapp://send/919325525029` (path form) | not tested individually |
| `whatsapp://send/<STANZA>` | not tested individually |
| `whatsapp://send/<SER>` | not tested individually |
| `whatsapp://send/919325525029/<STANZA>` (2-segment) | not tested individually |

### 3a. send + partnertoken (CTWA External CTX) — REAL FLOW TRIGGERED

| URL | Observed |
|---|---|
| `whatsapp://send?phone=919325525029&partnertoken=<fakeJWT>` | **"Starting chat" popup → dismissed** (JWT validation failed) |
| `whatsapp://send?phone=919325525029&text=hello&partnertoken=<fakeJWT>` | **"Starting chat" popup → composer prefilled** |
| `whatsapp://send?phone=919325525029&partnertoken=<realJWT>` | **not tested — need real Meta-signed JWT** |

> The "Starting chat" popup is the External CTX flow doing GraphQL JWT validation. With a real JWT, this should open the existing chat WITHOUT the composer + show "via X" partner banner. Token query param name confirmed: `partnertoken` (lowercase).
>
> Real CTWA JWTs are issued when a user clicks a Facebook/Instagram WhatsApp Business ad. To capture one: tap a real CTWA ad on phone, share the WhatsApp link before opening it.

---

## 4. chat host (legacy) — query-style

| URL | Observed |
|---|---|
| `whatsapp://chat?jid=198535031029815@lid` | opens chat ✓ |
| `whatsapp://chat?jid=919325525029@s.whatsapp.net&msg=<STANZA>` | not tested individually |
| `whatsapp://chat?jid=<JID>&msgKey=<SER>` | not tested individually |
| `whatsapp://chat?jid=<JID>&msgKeyId=<STANZA>` | not tested individually |
| `whatsapp://chat?jid=<JID>&stanzaId=<STANZA>` | not tested individually |
| `whatsapp://chat?jid=<JID>&message_id=<STANZA>` | not tested individually |

---

## 5. c host — channels (WANewsletterDeepLink)

| URL | Observed |
|---|---|
| `whatsapp://c/<STANZA>` | triggered "channel activity" — confirmed parser hit |
| `whatsapp://c/<channelCode>` | not tested with a real channel code |
| `whatsapp://c/<channelCode>/<updateId>` | **untested — likely real format** |
| `https://whatsapp.com/channel/<channelCode>` | not tested |
| `https://whatsapp.com/channel/<channelCode>/<updateId>` | not tested |

> WANewsletterDeepLink has ivars `parsedCode` AND `parsedUpdate` — strongly suggesting channel-post anchored URLs work. To find the real format: follow any public channel in WhatsApp Mac, right-click a post → "Copy link" or share-sheet. That share URL should reveal the canonical form.

---

## 6. qr host — contact share

| URL | Observed |
|---|---|
| `whatsapp://qr/<contactCode>` | not tested |
| `whatsapp://qr/<contactCode>?ref=invite` | not tested |
| `https://wa.me/qr/<contactCode>` | not tested |

---

## 7. wa.me universal links (https://wa.me/…)

| URL | Observed |
|---|---|
| `https://wa.me/919325525029` | not tested individually (auto mode) |
| `https://wa.me/919325525029?text=hello` | not tested individually |
| `https://wa.me/c/<STANZA>` | not tested individually |
| `https://wa.me/message/<STANZA>` | not tested individually |
| `https://wa.me/message/<SER>` | not tested individually |
| `https://wa.me/919325525029?msg=<STANZA>` | not tested individually |
| `https://wa.me/channel/<channelCode>/<updateId>` | not tested |

---

## 8. Other host forms — fully untested

| URL | What it should hit |
|---|---|
| `whatsapp://chats?jid=<JID>` | WAChatListDeepLink (just opens chat list) |
| `whatsapp://chats?jid=<JID>&msg=<STANZA>` | speculative |
| `whatsapp://status?text=hello` | WAStatusShareDeepLink (story share composer) |
| `whatsapp://status?photo=<url>` | story share with photo |
| `whatsapp://u/<username>` | WAUsernameDeepLink (2026 usernames) — speculative form |
| `whatsapp://navigate/message/<STANZA>` | WANavigationDeepLink → WAPhoenixDeepLink (Bloks) |
| `whatsapp://goto/message/<STANZA>` | speculative |
| `whatsapp://p/<X>` | speculative (product?) |
| `whatsapp://open-chat?jid=<JID>` (hyphen) | falls through to WAUnknownDeepLink |
| `whatsapp://contact/<X>` | not tested |
| `whatsapp://contacts/<X>` | not tested |

---

## 9. Speculative single-word hosts (all fired in one batch, none did anything)

| URL | Observed |
|---|---|
| `whatsapp://openmessage/<STANZA>` | silent |
| `whatsapp://openmsgkey/<STANZA>` | silent |
| `whatsapp://openmsg/<STANZA>` | silent |
| `whatsapp://gotomessage/<STANZA>` | silent |
| `whatsapp://jumpmessage/<STANZA>` | silent |
| `whatsapp://showmessage/<STANZA>` | silent |
| `whatsapp://focusmessage/<STANZA>` | silent |
| `whatsapp://viewmessage/<STANZA>` | silent |

---

## 10. URL fragment (#) experiments — fully untested

The XWAExternalCTXAuthoriseWAChatHandler logs literally say `"URL fragment: '..."` so it reads fragments somewhere. Fragments NOT followed by /usr/bin/open are sent to the receiving app verbatim.

| URL | Observed |
|---|---|
| `whatsapp://openchat/<JID>#partnertoken=<fakeJWT>` | just opens WA (same as A/B) |
| `whatsapp://openchat/<JID>#msg=<STANZA>` | not tested |
| `whatsapp://openchat/<JID>#stanza=<STANZA>` | not tested |
| `whatsapp://send?phone=...#partnertoken=<JWT>` | not tested |
| `whatsapp://message/<X>#msg=<Y>` | not tested |

---

## 11. wa:// scheme (different from whatsapp://)

| URL | Observed |
|---|---|
| `wa://send?phone=919325525029` | "No application knows how to open URL" |
| `wa://openchat/<JID>` | likely same error |

> `wa://` is registered in the binary as a URL scheme but appears unhandled at the app level. May be ad-network internal.

---

## 12. The handlers that take real WAMessage* (in-process only — for reference)

These are the gold-standard scroll-and-highlight paths. They CANNOT be invoked externally — they take a live Core Data managed object pointer.

```objc
// From WAMessageNotificationCenter (notification tap path):
- (void)notificationWindow:(WANotificationWindowController *)win 
        openChatWithMessage:(WAMessage *)msg     ← WAMessage*, not string
                  inputText:(NSString *)text;

// From WAChatPresenter (the highlight constructor):
+ (instancetype)forMessage:(WAMessage *)msg      ← WAMessage*, not string
              searchTerms:(NSArray *)terms
                    style:(NSInteger)style;       ← style=2 produces highlight

// Then:
[application openChatWithPresenter:presenter animated:NO ...];
```

`-messageToScrollTo` is a read-only ivar — no public setter. Init-time only.

---

## 13. URL query keys the binary actually reads (across ALL parsers)

If a key is NOT in this list, it gets silently ignored by every ObjC parser:

| Key | Read by | Purpose |
|---|---|---|
| `phone` | WASendDeepLink | recipient phone |
| `text` | WASendDeepLink, WAStatusShareDeepLink, WAGroupInviteDeepLink | prefill composer / share |
| `token` | WASendDeepLink (CTWA branch) | JWT for ads |
| `partnertoken` | WADeepLinkRoot (every parser) | JWT for partner attribution |
| `ref` | WAContactDeepLink | invite source |
| `ig_redirect` | WAStatusShareDeepLink | Instagram redirect |
| `photo` | WAStatusShareDeepLink | story photo URL |
| `ar` | WAStatusShareDeepLink | AR filter |
| `gallery` | WAStatusShareDeepLink | gallery picker |
| `fb_storyshare_bcf_redirect` | WAStatusShareDeepLink | FB story redirect |

**Crucially absent from all parsers:** `msg`, `msgKey`, `stanza`, `stanzaId`, `messageId`, `message_id`, `msg_id`, `id` — none of these are read by ANY parser in the binary.

---

## 14. Path-component reads (via wa_deepLinkPathComponentAtPosition:)

| Parser | Position 0 (host) | Position 1 | Position 2+ |
|---|---|---|---|
| WAOpenChatDeepLink | `openchat` | JID (passed to `[WAChatJID withStringRepresentation:]`) | **IGNORED** |
| WAMessageDeepLink | `message` | contact code (passed to `wa_contactCode`) | **IGNORED** |
| WASendDeepLink | `send` or `message` | varies by flow | **IGNORED** |
| WAContactDeepLink | `qr` | contact code | **IGNORED** |
| WANewsletterDeepLink | (Swift-only — likely `c` or `channel`) | `parsedCode` (channel code) | possibly `parsedUpdate` |

> **Path component 2 is unread by every visible parser.** The flash from 2-segment openchat URLs is chat re-presentation, not parsing.

---

## 15. The catch-all / fallback

| URL | Handler |
|---|---|
| ANYTHING that doesn't match a registered parser | WAUnknownDeepLink → shows the "X isn't on WhatsApp" or generic error popup |

---

## Recommendation for manual investigation

1. **Pin down the "flash"** — fire `whatsapp://openchat/<JID>?aaa=bbb` (garbage param) while chat is NOT foregrounded. If it flashes too, the flash is re-presentation, not parsing. If it doesn't flash but `?msg=` does, we've found a real signal.

2. **Try fragments with various keys** — `whatsapp://openchat/<JID>#msg=<STANZA>`, etc. The binary logs "URL fragment" so fragments ARE read somewhere; we just haven't found the parser.

3. **Get a real channel link** — follow any public channel, copy a post link via right-click. That reveals the exact `parsedUpdate` format and proves channels DO support post anchors.

4. **Capture a real CTWA JWT** — click any FB/IG WhatsApp Business ad, intercept the link. That'd let us test if a valid `partnertoken=` URL opens the existing chat (vs new-chat composer) — distinguishing it from current behavior.

5. **Try wa.me forms** — universal links go through a different entry point (NSUserActivity, not URL scheme). May route differently inside the app.

6. **Iterate path-3 component on openchat** — `whatsapp://openchat/<JID>/X/Y/Z` with various Y/Z combinations. Decomp shows only path[1] is read but Swift sub-parsers may read deeper.
