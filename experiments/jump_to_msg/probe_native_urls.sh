#!/bin/bash
# probe_native_urls.sh — open each candidate URL via the macOS Launch Services
# router so we can SEE which one WhatsApp.app actually handles, and how.
#
# All candidates below were derived from the WhatsApp.app/Contents/MacOS/WhatsApp
# binary by decompiling -[WAOpenChatDeepLink parseURL:context:] and the wider
# WADeepLinkRoot.parseURL:context: surface.  None of the documented forms accept
# a message stanza ID, so we also try undocumented param names (stanza, msgid,
# message_id, key, msg, target) on top of the openchat host.  Run interactively
# and watch WhatsApp's behaviour.

set -u
PHONE="919325525029"
STANZA="3A8D5E50D816940D7DC5"
LID="198535031029815@lid"
JID_PN="${PHONE}@s.whatsapp.net"
JID_CUS="${PHONE}@c.us"
JID_LID="${LID}"

URLS=(
  # ── Documented openers (no scroll) ─────────────────────────────────────
  "whatsapp://send?phone=${PHONE}"
  "https://wa.me/${PHONE}"
  "whatsapp://openchat/${JID_PN}"
  "whatsapp://openchat/${JID_CUS}"
  "whatsapp://openchat/${JID_LID}"

  # ── Undocumented query parameters bolted onto openchat ────────────────
  "whatsapp://openchat/${JID_PN}?stanza=${STANZA}"
  "whatsapp://openchat/${JID_PN}?stanzaID=${STANZA}"
  "whatsapp://openchat/${JID_PN}?msgid=${STANZA}"
  "whatsapp://openchat/${JID_PN}?msg=${STANZA}"
  "whatsapp://openchat/${JID_PN}?message_id=${STANZA}"
  "whatsapp://openchat/${JID_PN}?messageId=${STANZA}"
  "whatsapp://openchat/${JID_PN}?key=false_${JID_PN}_${STANZA}"
  "whatsapp://openchat/${JID_PN}?target=${STANZA}"
  "whatsapp://openchat/${JID_LID}?stanza=${STANZA}"
  "whatsapp://openchat/${JID_LID}?stanzaID=${STANZA}"

  # ── Path-style stanza appended (mimics how reaction/poll deep links work) ─
  "whatsapp://openchat/${JID_PN}/${STANZA}"
  "whatsapp://openchat/${JID_LID}/${STANZA}"

  # ── Other hosts that might smuggle a msgid (saw `wa.action.OpenUrlV3`)
  "whatsapp://message/${STANZA}?phone=${PHONE}"
)

for u in "${URLS[@]}"; do
  printf '\n=== %s ===\n' "$u"
  read -rp 'press enter to launch (or s to skip): ' a
  [[ "$a" == "s" ]] && continue
  open "$u"
  read -rp 'did it scroll/highlight the message? [y/n/note]: ' r
  printf '  → %s\n' "$r" >> probe_results.log
  printf '  url: %s\n' "$u" >> probe_results.log
done
