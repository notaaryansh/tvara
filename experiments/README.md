# WhatsApp message-jump reverse engineering

Goal: figure out how to programmatically navigate macOS WhatsApp to a specific
message given (chat_jid, stanza_id, fromMe). The URL/intent/XPC surfaces are
exhausted; this is the runtime instrumentation path.

> **Read `INVESTIGATION.md` first.** It documents every approach we tried,
> every dead end with evidence, and where someone picking this back up
> should aim. The Python scripts here are stage 2 of that investigation —
> Frida-based runtime hooking — which is blocked behind SIP-disabled on the
> dev machine.

## Approach

1. `01_check.py` — verify Frida is installed, locate WhatsApp PID.
2. `02_hook.py` — attach to WhatsApp, hook `scrollToMessage:` and related
   selectors. User manually navigates to a known message. Capture the full
   call chain and arguments. This tells us **exactly** what selector tree
   gets invoked end-to-end.
3. `03_invoke.py` — once we know the dispatch chain, try to invoke the
   internal navigation directly from the hooked process (we already have
   code execution inside WhatsApp via Frida; the question is whether we can
   call `scrollToMessage:` with constructed arguments).

## Prerequisites

```bash
pip3 install frida-tools
```

WhatsApp is signed with hardened runtime. Frida may need:
- SIP disabled (`csrutil disable` from Recovery Mode), OR
- A non-hardened resigned copy of WhatsApp

The scripts detect this and report clearly. We try the easy path first.

## Status

Stage 1: scripts written
Stage 2: not yet run
Stage 3: not yet attempted
