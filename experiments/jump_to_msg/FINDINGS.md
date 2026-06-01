# Jump-to-message in WhatsApp — what works and what doesn't

Inputs we're solving for:

```
PHONE  = 919325525029
STANZA = 3A8D5E50D816940D7DC5
LID    = 198535031029815@lid
```

## The only API that performs the highlight/scroll

WhatsApp's chat view exposes one function that **scrolls to a specific message and
highlights it**. Internally it goes by several names:

| surface             | symbol                                                      |
|---------------------|-------------------------------------------------------------|
| WhatsApp Web JS     | `Store.Cmd.openChatAt({ chat, msgContext })`                |
| WhatsApp Mac (Obj‑C)| `setNeedsScrollToMessage:highlightAfterScroll:animated:`    |
| WhatsApp Mac (Swift)| `init(targetMessage: stanzaID:)` → `scrollToTargetWithAnimation` |
| WhatsApp Mac (VC)   | `openChatViewControllerFor:userContext:message:`            |
| Notifications       | `notificationWindow:openChatWithMessage:inputText:`         |

All five end up at the same place in the chat presenter. The question is which
surface we can reach from outside.

## URL deep-link surface (Mac/iOS): no jump-to-message

I disassembled **every** `WA*DeepLink` class in
`/Applications/WhatsApp.app/Contents/MacOS/WhatsApp` (113 in total) and dumped
the cfstring set each one's `parseURL:context:` actually reads. The only chat-
opening forms WhatsApp accepts are:

```
whatsapp://send?phone=<phone>[&text=...]
whatsapp://openchat/<JID>[?source=...&surface=...]      # WAOpenChatDeepLink
https://wa.me/<phone>
https://wa.me/message/<contact_code>                    # WAMessageDeepLink (marketing template)
```

`WAOpenChatDeepLink` has **one ivar**, `_chatJID`. Its `parseURL:` parses
`pathComponents[1]` as a JID and then calls `parseSourceSurfaceWithQueryItems:`,
which only reads `source` / `surface` / `entry_point`. **There is no parameter
slot for a message stanza.**

Sanity check: I looked up every cfstring whose C string equals `stanza`,
`stanzaID`, `stanza_id`, `message_id`, `messageId`, `msgid`, `msg_id`, `msgKey`
in the binary, then traced every adrp+add xref to each surviving cfstring. The
hits land in:

- the XMPP stanza encoder (`encodeWithCoder:`, `stringRepresentation`)
- the draft JSON serializer (`{chatJID, stanzaID, mentions, text}`)
- a CoreData fetch predicate for `messages NEEDING data items`

None of these are URL handlers. So: there is no "secret" query parameter on
`whatsapp://openchat` that triggers jump-to-message.

## What does work: WhatsApp Web JS

The path `whatsapp-web.js` uses for its `client.interface.openChatWindowAt`:

```js
const msg = Store.Msg.get(msgId)
         || (await Store.Msg.getMessagesById([msgId]))?.messages?.[0];
const chat = Store.Chat.get(msg.id.remote)
         ?? (await Store.Chat.find(msg.id.remote));
const ctx  = await Store.SearchContext.getSearchContext(chat, msg.id);
await Store.Cmd.openChatAt({ chat, msgContext: ctx });
```

The only ambiguous input is `msgId`. It's the `MsgKey._serialized` form:

```
<fromMe>_<remote>_<stanza>
```

With LID addressing rolling out, `<remote>` can be `<phone>@c.us`,
`<phone>@s.whatsapp.net`, OR `<lid>@lid`. We don't know which one WhatsApp Web
used when it indexed this conversation, so we generate all six combinations and
let `Store.Msg.getMessagesById` resolve whichever exists.

For `(PHONE=919325525029, STANZA=3A8D5E50D816940D7DC5, LID=198535031029815@lid)`:

```
false_919325525029@c.us_3A8D5E50D816940D7DC5
false_919325525029@s.whatsapp.net_3A8D5E50D816940D7DC5
false_198535031029815@lid_3A8D5E50D816940D7DC5
true_919325525029@c.us_3A8D5E50D816940D7DC5
true_919325525029@s.whatsapp.net_3A8D5E50D816940D7DC5
true_198535031029815@lid_3A8D5E50D816940D7DC5
```

## Files in this directory

| file                    | what it does                                                              |
|-------------------------|----------------------------------------------------------------------------|
| `msg_keys.py`           | prints the six MsgKey candidates (and chat-open URLs as a fallback)        |
| `jump_inject.js`        | defines `window.WAJump.jumpToMessage(phone, stanza, lid)`                  |
| `jump_via_puppeteer.js` | spins puppeteer on the existing `whatsapp_profile`, runs the jump, prints which key resolved |
| `probe_native_urls.sh`  | interactive `open <url>` probe so you can visually confirm the native app does NOT scroll on any URL form |
| `dump_cfstring.py`      | resolve any cfstring VM address inside the Mac binary                      |
| `index_disasm.py`       | one-shot index build over the 400MB disassembly so per-function reads are O(log n) |
| `map_deeplinks.py`      | per-class disassembly summary for every `WA*DeepLink.parseURL:`            |

## Recommendation for the Spotlight++ side

1. Run a single Puppeteer-managed WhatsApp Web tab (the same `whatsapp_profile`
   the `whatsapp-web.js` install already authenticated).
2. Expose an in-app handler that takes `(phone, stanza, lid)` and runs
   `window.WAJump.jumpToMessage(phone, stanza, lid)` via `page.evaluate`.
3. Cache the working `MsgKey._serialized` form per peer once you've resolved it
   the first time — after a chat is hydrated, the same form will work for every
   subsequent stanza in that chat.

If you specifically need a *URL* surface inside Spotlight++ (e.g. a clickable
link in a search-result row), register your own scheme (`spotlight://msg/...`)
and translate it to the puppeteer call inside your app — there's no shorter
path because WhatsApp itself doesn't accept a stanza in any URL.
