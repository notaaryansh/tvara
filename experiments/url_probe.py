#!/usr/bin/env python3
"""
Systematic URL probe rig for WhatsApp Mac message-jump investigation.

USAGE
=====
    python3 url_probe.py             # interactive: pause after each URL, ask what happened
    python3 url_probe.py --auto      # fire all URLs with delay, no pause
    python3 url_probe.py --only N    # fire ONLY url number N from the catalog
    python3 url_probe.py --list      # print the catalog without firing anything

The catalog of URLs is in URLS_TO_TEST below — edit/extend freely. Constants
(stanza, jid, phone) are hardcoded at the top.

Output is captured to runs/<timestamp>/results.txt — we can grep it later.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime

# ============================================================
# HARDCODED CONSTANTS — change these for different test runs
# ============================================================
PHONE = "919325525029"                              # drishtu's phone
STANZA = "3A8D5E50D816940D7DC5"                     # "Stay in your pants" stanza
MESSAGE_TEXT = "Stay in your pants"                 # the actual message text (for reference)
LID = "198535031029815@lid"                         # drishtu's LID
JID_SNET = f"{PHONE}@s.whatsapp.net"
JID_CUS = f"{PHONE}@c.us"

# Build the canonical "serialized" message id forms — all four variants
SER_FALSE_SNET = f"false_{JID_SNET}_{STANZA}"
SER_TRUE_SNET = f"true_{JID_SNET}_{STANZA}"
SER_FALSE_CUS = f"false_{JID_CUS}_{STANZA}"
SER_FALSE_LID = f"false_{LID}_{STANZA}"

# ============================================================
# URL CATALOG — every URL form worth trying
# Tag column = our hypothesis about what each URL might trigger
# ============================================================
URLS_TO_TEST = [
    # --- baselines (we know these behaviors) ---
    ("send-phone-baseline", f"whatsapp://send?phone={PHONE}", "known: opens new-chat composer"),
    ("chat-jid-baseline-lid", f"whatsapp://chat?jid={LID}", "known: opens drishtu chat"),

    # --- WAMessageDeepLink path forms (we got empty-popup before) ---
    ("msg-stanza-raw", f"whatsapp://message/{STANZA}", "WAMessageDeepLink with raw stanza"),
    ("msg-ser-snet", f"whatsapp://message/{SER_FALSE_SNET}", "with @s.whatsapp.net serialized"),
    ("msg-ser-cus", f"whatsapp://message/{SER_FALSE_CUS}", "with @c.us serialized"),
    ("msg-ser-lid", f"whatsapp://message/{SER_FALSE_LID}", "with @lid serialized"),

    # --- WASendDeepLink path forms (new! — we only ever did query params) ---
    ("send-path-phone", f"whatsapp://send/{PHONE}", "path-based send w/ phone"),
    ("send-path-stanza", f"whatsapp://send/{STANZA}", "path-based send w/ stanza"),
    ("send-path-ser", f"whatsapp://send/{SER_FALSE_SNET}", "path-based send w/ serialized"),
    ("send-path-phone-stanza", f"whatsapp://send/{PHONE}/{STANZA}", "two-segment path"),
    ("send-query-msg", f"whatsapp://send?phone={PHONE}&msg={STANZA}", "send query + msg"),
    ("send-query-msgkey", f"whatsapp://send?phone={PHONE}&msgKey={SER_FALSE_SNET}", "send query + msgKey"),
    ("send-query-id", f"whatsapp://send?phone={PHONE}&id={STANZA}", "send query + id"),

    # --- WAContactDeepLink (was WA never tested as URL scheme) ---
    ("c-path", f"whatsapp://c/{STANZA}", "WAContactDeepLink c path"),
    ("contact-path", f"whatsapp://contact/{STANZA}", "contact path"),
    ("c-path-ser", f"whatsapp://c/{SER_FALSE_SNET}", "c path + serialized"),

    # --- Mixed: chat?jid combined with various message params ---
    ("chat-msg-snet", f"whatsapp://chat?jid={JID_SNET}&msg={STANZA}", "@s.whatsapp.net jid + msg"),
    ("chat-msgkey-snet", f"whatsapp://chat?jid={JID_SNET}&msgKey={SER_FALSE_SNET}", "msgKey"),
    ("chat-msgKeyId-snet", f"whatsapp://chat?jid={JID_SNET}&msgKeyId={STANZA}", "msgKeyId"),
    ("chat-stanzaId-snet", f"whatsapp://chat?jid={JID_SNET}&stanzaId={STANZA}", "stanzaId"),
    ("chat-message_id-snet", f"whatsapp://chat?jid={JID_SNET}&message_id={STANZA}", "message_id (snake case)"),

    # --- Universal links (wa.me) ---
    ("wame-c-stanza", f"https://wa.me/c/{STANZA}", "wa.me/c/ contact"),
    ("wame-message-stanza", f"https://wa.me/message/{STANZA}", "wa.me/message/"),
    ("wame-message-ser", f"https://wa.me/message/{SER_FALSE_SNET}", "wa.me/message/ serialized"),
    ("wame-phone-msg", f"https://wa.me/{PHONE}?msg={STANZA}", "wa.me phone + msg query"),

    # --- Speculative: less-explored paths ---
    ("openchat-jid", f"whatsapp://open-chat?jid={JID_SNET}&msg={STANZA}", "open-chat path"),
    ("chats-jid-msg", f"whatsapp://chats?jid={JID_SNET}&msg={STANZA}", "chats path"),
    ("navigate-msg", f"whatsapp://navigate/message/{STANZA}", "navigate path"),
    ("goto-msg", f"whatsapp://goto/message/{STANZA}", "goto path"),
    ("p-stanza", f"whatsapp://p/{STANZA}", "p path (product?)"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--auto", action="store_true", help="fire all URLs without pausing")
    parser.add_argument("--only", type=int, help="fire only URL number N (0-indexed)")
    parser.add_argument("--list", action="store_true", help="list the catalog and exit")
    parser.add_argument("--delay", type=float, default=2.0, help="seconds between URLs in --auto mode")
    args = parser.parse_args()

    if args.list:
        print(f"{len(URLS_TO_TEST)} URLs in catalog:\n")
        for i, (tag, url, note) in enumerate(URLS_TO_TEST):
            print(f"  [{i:2d}] {tag:32s}  {url}")
            print(f"       hypothesis: {note}")
        return

    # Set up output dir
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(__file__).parent / "runs" / ts
    out_dir.mkdir(parents=True, exist_ok=True)
    results_file = out_dir / "results.txt"

    with open(results_file, "w") as f:
        f.write(f"# WhatsApp URL probe run {ts}\n")
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

            # Fire the URL
            try:
                subprocess.run(["/usr/bin/open", url], check=False, capture_output=True, text=True, timeout=5)
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
                # Interactive: ask what happened
                print(f"     ──")
                print(f"     What happened in WhatsApp? Options:")
                print(f"        n = nothing (just opens WhatsApp / no state change)")
                print(f"        c = opened the correct chat (drishtu) but no message highlight")
                print(f"        m = scrolled/highlighted the '{MESSAGE_TEXT}' message ✓ MAGIC")
                print(f"        p = showed an empty 'OK' popup")
                print(f"        e = showed an error or different popup (describe)")
                print(f"        b = opened browser/Chrome instead")
                print(f"        s = skip (move to next)")
                print(f"        q = quit")
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
                    label = {"n": "nothing", "c": "chat-only", "m": "MAGIC-highlighted-message",
                             "p": "empty-popup", "b": "browser"}.get(ans, f"unknown({ans})")
                    f.write(f"  result: {label}\n")
                    if ans == "m":
                        print(f"\n     🎉 MAGIC HIT at [{real_i}] {tag}")
                        print(f"     URL: {url}")

    print(f"\nDone. Results saved to: {results_file}")


if __name__ == "__main__":
    main()
