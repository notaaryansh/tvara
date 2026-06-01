#!/usr/bin/env python3
"""
url_probe2.py — extended catalog focused on combinations of the
              chat reference (phone / JID / LID) with the message
              reference (stanza / serialized) that url_probe.py did NOT cover.

Rationale for the new catalog (see INVESTIGATION.md §8 + §11.G):

- WADeepLinkRoot baseProperties include `lid`, `jid`, `phone`, `text`,
  `context`, `data`, `entryPoint`, `source`, `sourceId`, `trackingPayload`,
  `username`, `productId` — most never tried as query param names.
- The internal APN notification payload uses snake_case keys: `chat_jid`,
  `message_id`, `conversation_id`, `sender`, `category_id`,
  `notification_id`. These are the EXACT routing fields the URL parser
  is missing; worth trying them by name in case the parser accepts them.
- `id=` was tried on `send?` but never on `chat?`.
- Path + query combinations (`message/<stanza>?jid=…`) were never tried —
  prior runs were either pure path or pure query.

Usage identical to url_probe.py:
    python3 url_probe2.py             # interactive
    python3 url_probe2.py --auto      # fire all w/ delay (no observation)
    python3 url_probe2.py --only N    # fire one
    python3 url_probe2.py --list      # print without firing
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime

# ── shared constants (mirror url_probe.py) ──────────────────────────────
PHONE = "919325525029"
STANZA = "3A8D5E50D816940D7DC5"
MESSAGE_TEXT = "Stay in your pants"
LID = "198535031029815@lid"
JID_SNET = f"{PHONE}@s.whatsapp.net"
JID_CUS = f"{PHONE}@c.us"

SER_FALSE_SNET = f"false_{JID_SNET}_{STANZA}"
SER_FALSE_LID = f"false_{LID}_{STANZA}"

# ── NEW catalog: gaps not covered by url_probe.py ──────────────────────
URLS_TO_TEST = [
    # ─── Tier A: combine known chat-ref with notif-style msg keys ───
    ("chat-lid-msg",          f"whatsapp://chat?lid={LID}&msg={STANZA}",
        "LID + msg (LID never used as param)"),
    ("chat-lid-msgid",        f"whatsapp://chat?lid={LID}&message_id={STANZA}",
        "LID + snake_case message_id"),
    ("chat-lid-stanzaid",     f"whatsapp://chat?lid={LID}&stanzaId={STANZA}",
        "LID + stanzaId"),
    ("chat-lid-id",           f"whatsapp://chat?lid={LID}&id={STANZA}",
        "LID + bare id"),
    ("chat-jid-id",           f"whatsapp://chat?jid={JID_SNET}&id={STANZA}",
        "JID + bare id (id never tried on chat?)"),
    ("chat-jid-messageid-cc", f"whatsapp://chat?jid={JID_SNET}&messageId={STANZA}",
        "JID + camelCase messageId"),
    ("chat-jid-stanza",       f"whatsapp://chat?jid={JID_SNET}&stanza={STANZA}",
        "JID + bare 'stanza' param"),

    # ─── Tier B: mimic internal APN notification payload ───
    ("notif-mimic-snet",      f"whatsapp://chat?chat_jid={JID_SNET}&message_id={STANZA}",
        "notification mimic w/ chat_jid + message_id"),
    ("notif-mimic-lid",       f"whatsapp://chat?chat_jid={LID}&message_id={STANZA}",
        "notif mimic w/ LID"),
    ("notif-conv-snet",       f"whatsapp://chat?conversation_id={JID_SNET}&message_id={STANZA}",
        "conversation_id + message_id"),
    ("notif-convCamel",       f"whatsapp://chat?conversationId={JID_SNET}&messageId={STANZA}",
        "camelCase conversationId + messageId"),

    # ─── Tier C: cross-scheme params (jid on send?, phone on chat?) ───
    ("send-jid-msg",          f"whatsapp://send?jid={JID_SNET}&msg={STANZA}",
        "jid on send? scheme"),
    ("send-lid-msg",          f"whatsapp://send?lid={LID}&msg={STANZA}",
        "lid on send? scheme"),
    ("send-phone-jid-msg",    f"whatsapp://send?phone={PHONE}&jid={JID_SNET}&msg={STANZA}",
        "phone + jid + msg trio"),
    ("send-phone-stanzaId",   f"whatsapp://send?phone={PHONE}&stanzaId={STANZA}",
        "send + stanzaId (chat? param name on send?)"),
    ("send-phone-messageid",  f"whatsapp://send?phone={PHONE}&message_id={STANZA}",
        "send + message_id snake"),
    ("send-phone-conv",       f"whatsapp://send?phone={PHONE}&conversation_id={JID_SNET}&message_id={STANZA}",
        "send + full notif payload"),
    ("chat-phone-msg",        f"whatsapp://chat?phone={PHONE}&msg={STANZA}",
        "phone on chat? scheme"),

    # ─── Tier D: path + query combinations (never tried) ───
    ("msgpath-jid",           f"whatsapp://message/{STANZA}?jid={JID_SNET}",
        "message path + jid query"),
    ("msgpath-lid",           f"whatsapp://message/{STANZA}?lid={LID}",
        "message path + lid query"),
    ("msgpath-phone",         f"whatsapp://message/{STANZA}?phone={PHONE}",
        "message path + phone query"),
    ("chatpath-msg-jid",      f"whatsapp://chat/{JID_SNET}?msg={STANZA}",
        "chat path w/ JID + msg query"),
    ("chatpath-msg-lid",      f"whatsapp://chat/{LID}?msg={STANZA}",
        "chat path w/ LID + msg query"),
    ("chatpath-two-seg-snet", f"whatsapp://chat/{JID_SNET}/{STANZA}",
        "two-segment chat/<jid>/<stanza>"),
    ("chatpath-two-seg-lid",  f"whatsapp://chat/{LID}/{STANZA}",
        "two-segment chat/<LID>/<stanza>"),

    # ─── Tier E: send? path-form combined with msg query ───
    ("sendpath-msg",          f"whatsapp://send/{PHONE}?msg={STANZA}",
        "path-based send + msg query"),
    ("sendpath-id",           f"whatsapp://send/{PHONE}?id={STANZA}",
        "path-based send + id query"),
    ("sendpath-stanzaId",     f"whatsapp://send/{PHONE}?stanzaId={STANZA}",
        "path-based send + stanzaId query"),

    # ─── Tier F: serialized in a query slot ───
    ("send-msgkey-lid",       f"whatsapp://send?phone={PHONE}&msgKey={SER_FALSE_LID}",
        "send + msgKey w/ LID serialized"),
    ("chat-msgkey-lid",       f"whatsapp://chat?jid={LID}&msgKey={SER_FALSE_LID}",
        "chat + msgKey w/ LID serialized"),
    ("chat-key-snet",         f"whatsapp://chat?jid={JID_SNET}&key={SER_FALSE_SNET}",
        "chat + 'key' param"),
    ("chat-msgKey-snet-lid",  f"whatsapp://chat?jid={LID}&msgKey={SER_FALSE_SNET}",
        "LID chat + sNet serialized key"),

    # ─── Tier G: speculative schemes/bases ───
    ("msg-query-only",        f"whatsapp://message?id={STANZA}&jid={JID_SNET}",
        "message scheme as query-only"),
    ("msg-jid-query",         f"whatsapp://message?jid={JID_SNET}&id={STANZA}",
        "same as above reversed order"),
    ("msg-singular",          f"whatsapp://msg?jid={JID_SNET}&id={STANZA}",
        "msg (singular) scheme"),
    ("thread-jid-msg",        f"whatsapp://thread?jid={JID_SNET}&msg={STANZA}",
        "thread scheme"),
    ("search-text",           f"whatsapp://search?q={MESSAGE_TEXT.replace(' ', '%20')}",
        "search by text (trigger in-app search)"),

    # ─── Tier H: text param containing stanza ───
    ("send-phone-text-stanza",f"whatsapp://send?phone={PHONE}&text={STANZA}",
        "text=<stanza> on send"),
    ("chat-jid-text-stanza",  f"whatsapp://chat?jid={JID_SNET}&text={STANZA}",
        "text=<stanza> on chat"),
]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--auto", action="store_true", help="fire all URLs without pausing")
    parser.add_argument("--only", type=int, help="fire only URL number N (0-indexed)")
    parser.add_argument("--list", action="store_true", help="list the catalog and exit")
    parser.add_argument("--delay", type=float, default=2.0, help="seconds between URLs in --auto mode")
    args = parser.parse_args()

    if args.list:
        print(f"{len(URLS_TO_TEST)} URLs in catalog:\n")
        for i, (tag, url, note) in enumerate(URLS_TO_TEST):
            print(f"  [{i:2d}] {tag:28s}  {url}")
            print(f"       hypothesis: {note}")
        return

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(__file__).parent / "runs" / f"v2-{ts}"
    out_dir.mkdir(parents=True, exist_ok=True)
    results_file = out_dir / "results.txt"

    with open(results_file, "w") as f:
        f.write(f"# WhatsApp URL probe v2 run {ts}\n")
        f.write(f"# PHONE={PHONE}  STANZA={STANZA}  TEXT={MESSAGE_TEXT!r}\n#\n")

        urls = URLS_TO_TEST
        if args.only is not None:
            if 0 <= args.only < len(urls):
                urls = [urls[args.only]]
            else:
                print(f"Error: --only {args.only} out of range (0..{len(urls)-1})")
                sys.exit(1)

        for i, (tag, url, note) in enumerate(urls):
            real_i = URLS_TO_TEST.index((tag, url, note))
            print(f"\n[{real_i:2d}/{len(URLS_TO_TEST)}] {tag}")
            print(f"     URL: {url}")
            print(f"     hyp: {note}")

            try:
                subprocess.run(["/usr/bin/open", url], check=False,
                               capture_output=True, text=True, timeout=5)
                print(f"     → fired")
            except Exception as e:
                print(f"     → error firing: {e}")

            f.write(f"\n[{real_i:2d}] {tag}\n")
            f.write(f"  URL: {url}\n")
            f.write(f"  hyp: {note}\n")

            if args.auto:
                time.sleep(args.delay)
                f.write(f"  result: (auto mode — no observation captured)\n")
            else:
                print(f"     ──")
                print(f"     Observed in WhatsApp?")
                print(f"        n = nothing / no state change")
                print(f"        c = opened correct chat, NO highlight")
                print(f"        m = scrolled+highlighted '{MESSAGE_TEXT}' ✓ MAGIC")
                print(f"        p = empty 'OK' popup")
                print(f"        e = different error/popup (describe)")
                print(f"        b = opened browser")
                print(f"        s = skip   q = quit")
                ans = input("     observed: ").strip().lower()
                if ans == "q":
                    f.write(f"  result: (quit)\n")
                    print(f"\nResults saved to: {results_file}")
                    return
                if ans == "s":
                    f.write(f"  result: skip\n")
                    continue
                if ans.startswith("e"):
                    detail = input("     describe: ").strip()
                    f.write(f"  result: error — {detail}\n")
                else:
                    label = {"n": "nothing", "c": "chat-only",
                             "m": "MAGIC-highlighted-message",
                             "p": "empty-popup", "b": "browser"}.get(
                        ans, f"unknown({ans})")
                    f.write(f"  result: {label}\n")
                    if ans == "m":
                        print(f"\n     🎉 MAGIC HIT at [{real_i}] {tag}")
                        print(f"     URL: {url}")

    print(f"\nDone. Results saved to: {results_file}")


if __name__ == "__main__":
    main()
