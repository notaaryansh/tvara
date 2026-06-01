#!/usr/bin/env python3
"""Derive every plausible WhatsApp Web MsgKey._serialized form from (phone, stanza, lid).

WhatsApp Web's `Store.MsgKey` serializes as:
    "<fromMe>_<remote>_<id>[_<participant>]"

where:
- fromMe   ∈ {"true", "false"}  (outgoing / incoming)
- remote   = peer JID. For DM this is usually `<phone>@c.us` (legacy) or `<phone>@s.whatsapp.net`,
             and when the chat uses LID addressing, it's `<lid>@lid`.
- id       = the stanza ID (hex, e.g. "3A8D5E50D816940D7DC5")
- participant (optional) = for group messages; for DMs it's omitted in standard form.

WhatsApp's `WidToJid` maps `<phone>@c.us` ↔ `<phone>@s.whatsapp.net`. Different builds
serialize one or the other. With the LID addressing mode rolling out, `@lid` is the
chat's canonical addressing in many DMs now.

Given the user's data we generate the full cartesian product so the caller can pass
the list straight to `getMessagesById([...])` — only the form that actually exists in
the Msg store will resolve.
"""
import sys
from itertools import product
from urllib.parse import quote


def all_candidates(phone: str, stanza: str, lid: str):
    """Return every plausible MsgKey._serialized string."""
    phone = phone.lstrip("+").replace(" ", "").replace("-", "")
    lid = lid.split("@")[0]  # strip suffix if user passed "...@lid"
    remotes = [
        f"{phone}@c.us",
        f"{phone}@s.whatsapp.net",
        f"{lid}@lid",
    ]
    candidates = []
    for from_me, remote in product(("false", "true"), remotes):
        candidates.append(f"{from_me}_{remote}_{stanza}")
    return candidates


def web_whatsapp_urls(phone: str, lid: str):
    """URL forms that *open the chat* (not jump-to-message), useful as a fallback."""
    phone = phone.lstrip("+").replace(" ", "").replace("-", "")
    lid = lid.split("@")[0]
    return [
        f"https://wa.me/{phone}",
        f"https://api.whatsapp.com/send?phone={phone}",
        f"whatsapp://send?phone={phone}",
        f"whatsapp://openchat/{phone}@s.whatsapp.net",
        f"whatsapp://openchat/{lid}@lid",
        # web.whatsapp.com is an SPA — no documented msg deeplink, but the in-page
        # router does take ?phone=… for opening a chat with that number:
        f"https://web.whatsapp.com/send?phone={phone}",
    ]


if __name__ == "__main__":
    PHONE = "919325525029"
    STANZA = "3A8D5E50D816940D7DC5"
    LID = "198535031029815@lid"
    print("# MsgKey._serialized candidates")
    for c in all_candidates(PHONE, STANZA, LID):
        print(c)
    print()
    print("# Chat-open URLs (no message scroll)")
    for u in web_whatsapp_urls(PHONE, LID):
        print(u)
