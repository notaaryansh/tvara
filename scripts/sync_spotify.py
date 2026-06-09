#!/usr/bin/env python3
"""
Sync Spotify library (playlists / albums / artists) from the desktop app's
local LevelDB cache into tvara's spotify_index.db.

Reads:
    ~/Library/Application Support/Spotify/PersistentCache/Users/<user>-user/primary.ldb

Writes:
    ~/Library/Application Support/tvara/spotify_index.db

Schema:
    items(kind TEXT, id TEXT, name TEXT, art_hash TEXT, indexed_at INT,
          PRIMARY KEY(kind, id))

Approach:
    Spotify's records use protobuf-ish length-prefixed strings. Albums and
    artists store the human name AFTER the URI; playlists store it BEFORE.
    We scan in both directions and pick the most plausible printable
    string for each URI occurrence.

    Artwork: Spotify image hashes are 40-hex strings. Each item record
    typically embeds at least one image hash for the cover art near the
    URI. We grab the nearest hash within 200 bytes.

Requirements:
    pip install dfindexeddb python-snappy zstd
    (homebrew: snappy + zstd dynamic libs already installed if dfindexeddb works)
"""
from __future__ import annotations
import argparse, re, shutil, sqlite3, ssl, sys, tempfile, time
from collections import Counter, defaultdict
from pathlib import Path

try:
    from dfindexeddb.leveldb import record
except ImportError:
    sys.exit(
        "missing dependency 'dfindexeddb'.\n"
        "install via: pip install dfindexeddb"
    )

SUPPORT_DIR = Path.home() / "Library/Application Support/tvara"
TARGET_DB   = SUPPORT_DIR / "spotify_index.db"
OVERRIDES   = SUPPORT_DIR / "spotify_playlists.txt"

USER_LDB_CANDIDATES = sorted(Path.home().glob(
    "Library/Application Support/Spotify/PersistentCache/Users/*-user/primary.ldb"
))

URI_RE      = re.compile(rb'spotify:(playlist|album|artist):([A-Za-z0-9]{22})')
HASH_RE     = re.compile(rb'[a-f0-9]{40}')

# Words obviously NOT user-facing names — they're metadata keys, JSON
# literals, or other noise that the extractor occasionally captures.
METADATA_WORDS = {
    "status", "header_image_url_desktop", "header_image_url_default",
    "header_image_url", "is_video_first", "type", "name", "uri", "id",
    "owner", "collaborative", "playlist", "album", "artist", "track",
    "decision_id", "spotify", "proprietary_id", "external_url", "metadata",
    "image", "icon", "user", "creator", "description", "added_at",
    "added_by", "is_local", "explicit", "duration_ms", "preview_url",
    "popularity", "available_markets", "uri_canonical", "artist-mix-reader",
    "editorial", "format-shows-shuffle", "autoplay",
    # JSON literals + grammar fragments captured from cached query responses
    "true", "false", "null", "none", "undefined", "default", "this",
    "that", "what", "where", "when", "title", "value", "items",
}

def is_clean_name(s: str) -> bool:
    s = s.strip()
    if len(s) < 3 or len(s) > 80: return False
    if s.startswith("spotify:") or s.startswith("http") or s.startswith("$"):
        return False
    if "<a href" in s.lower() or "</a" in s.lower(): return False
    if ">" in s and "spotify" in s.lower(): return False
    if "/" in s and "spotify" in s.lower(): return False
    # All-hex / all-caps-ids
    if re.match(r"^[a-f0-9-]{16,}$", s.lower()): return False
    if re.match(r"^[A-Z0-9_-]{8,}$", s): return False
    if s.lower() in METADATA_WORDS: return False
    if sum(1 for c in s if c.isalpha()) < 2: return False
    return True


def find_length_prefixed_names(window: bytes, max_results: int = 5):
    """Return [(offset_in_window, name)] for printable length-prefixed strings."""
    results = []
    i = 0
    while i < len(window):
        length = window[i]
        if 3 <= length <= 80 and i + 1 + length <= len(window):
            cand = window[i+1 : i+1+length]
            try:
                s = cand.decode("utf-8")
            except UnicodeDecodeError:
                i += 1; continue
            if all(c.isprintable() for c in s) and is_clean_name(s):
                results.append((i, s))
                if len(results) >= max_results:
                    return results
        i += 1
    return results


def find_nearest_art_hash(window_before: bytes, window_after: bytes) -> str | None:
    """Find an art-hash (40 hex chars) nearest to position 0 (the URI)."""
    # The hash typically appears AFTER the URI for album/artist records,
    # BEFORE the URI for playlist records.
    after = HASH_RE.search(window_after)
    if after:
        return after.group().decode()
    # Search backwards in before-window (last hash = nearest to URI)
    before_hits = HASH_RE.findall(window_before)
    if before_hits:
        return before_hits[-1].decode()
    return None


BARE_ID_RE = re.compile(rb'[A-Za-z0-9]{22}')


def looks_like_spotify_id(sid: str) -> bool:
    """Spotify base62 IDs are case-sensitive and reliably contain MULTIPLE
    upper- and lower-case letters distributed throughout the 22 chars.

    Things we reject:
      - Art-CDN hashes (`ab67706...` / `ab67616...`): all-lowercase hex
      - "X + 21 chars of hex" patterns where my window happens to capture
        the byte before a 40-hex art hash and the hash's first 21 chars
      - Anything where all chars beyond the first are lowercase hex
    """
    if len(sid) != 22: return False
    if sid.startswith("ab67706"): return False
    if sid.startswith("ab67616"): return False
    # Reject IDs where everything after the first char is lowercase hex —
    # these are art-hash prefixes captured with a single leading byte.
    tail = sid[1:]
    if all(c in "0123456789abcdef" for c in tail):
        return False
    # Require at least TWO uppercase AND TWO lowercase letters distributed
    # throughout — real Spotify IDs reliably have this mix.
    n_upper = sum(1 for c in sid if c.isupper())
    n_lower = sum(1 for c in sid if c.islower())
    return n_upper >= 2 and n_lower >= 2

def extract_pairs(value: bytes):
    """Yield (kind, id, name, art_hash) tuples for each spotify:* URI in
    this dfindexeddb record value. Handles albums, artists, and algorithmic
    playlists (anything that stores its URI + name in the same record).

    User-created playlists are handled separately by
    `extract_user_playlists_from_raw` because their name and ID live in
    separate LevelDB records that are only adjacent in the raw file bytes.
    """
    L = len(value)
    for m in URI_RE.finditer(value):
        kind = m.group(1).decode()
        sid  = m.group(2).decode()
        start, end = m.start(), m.end()

        after_win  = value[end : min(end + 256, L)]
        before_win = value[max(0, start - 256) : start]

        after_names  = find_length_prefixed_names(after_win)
        before_names = find_length_prefixed_names(before_win)

        if kind in ("album", "artist"):
            name = after_names[0][1] if after_names else (
                before_names[-1][1] if before_names else None
            )
        else:  # playlist
            name = before_names[-1][1] if before_names else (
                after_names[0][1] if after_names else None
            )
        if not name:
            continue
        art_hash = find_nearest_art_hash(before_win, after_win)
        yield (kind, sid, name, art_hash)


def extract_user_playlists_from_raw(file_bytes: bytes):
    """Scan raw .ldb file bytes for the user's playlists.

    Canonical layout (confirmed via byte-level inspection across multiple
    primary.ldb files):
        [length_byte=N] [N bytes of UTF-8 name] 0x22 [22-char base62 id] 0x23

    The `0x22` and `0x23` framing bytes are stable across user playlists
    AND user-saved Spotify-curated playlists (the `37i9dQZF1...` prefix
    ones). No window-guessing — match the exact pattern.
    """
    L = len(file_bytes)
    seen: set[str] = set()
    # Pattern: 0x22 + exactly 22 base62 chars + 0x23
    FRAMED_ID_RE = re.compile(rb'\x22([A-Za-z0-9]{22})\x23')

    i = 0
    while i < L:
        length = file_bytes[i]
        if 3 <= length <= 80 and i + 1 + length + 24 <= L:
            cand = file_bytes[i+1 : i+1+length]
            try:
                s = cand.decode("utf-8")
            except UnicodeDecodeError:
                i += 1; continue
            if not (all(c.isprintable() for c in s) and is_clean_name(s)):
                i += 1; continue
            # The framed ID must start at exactly byte i+1+length
            framed_start = i + 1 + length
            m = FRAMED_ID_RE.match(file_bytes, framed_start)
            if m is None:
                i += 1; continue
            sid = m.group(1).decode()
            if sid in seen:
                i += 1; continue
            seen.add(sid)
            art_hash = find_nearest_art_hash(
                file_bytes[max(0, i-200):i],
                file_bytes[m.end() : min(m.end()+300, L)]
            )
            yield ("playlist", sid, s.strip(), art_hash)
        i += 1


def fetch_oembed_art_hash(kind: str, sid: str, name: str) -> str | None:
    """Hit Spotify's public oEmbed endpoint to (a) validate that this URI
    exists and (b) get the official thumbnail URL. Extract the i.scdn.co
    image hash from that URL and return it. Returns None on any failure
    — caller falls back to a placeholder badge.

    The endpoint:
        https://open.spotify.com/oembed?url=https://open.spotify.com/<kind>/<id>

    No auth required, ~150ms per call. We hit it once per override at
    sync time and cache the result via the spotify_index.db.
    """
    import urllib.request, urllib.parse, json
    web_url = f"https://open.spotify.com/{kind}/{sid}"
    api = "https://open.spotify.com/oembed?" + urllib.parse.urlencode({"url": web_url})
    try:
        req = urllib.request.Request(api, headers={
            "User-Agent": "tvara/0.1 (sync_spotify.py)"
        })
        with urllib.request.urlopen(req, timeout=6, context=ssl_ctx()) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"  ! override {name!r}: URI {kind}:{sid} not found on Spotify")
        else:
            print(f"  ! oEmbed HTTP {e.code} for {name!r}")
        return None
    except Exception as e:
        print(f"  ! oEmbed failed for {name!r}: {e}")
        return None

    thumb = data.get("thumbnail_url", "")
    # Extract the 40-hex art hash from a URL like
    # https://i.scdn.co/image/ab67706c0000da84...
    m = re.search(r"/image/([a-f0-9]{32,})", thumb)
    if m:
        print(f"  ✓ oEmbed art for {name!r}: {m.group(1)[:16]}…")
        return m.group(1)
    return None


def ssl_ctx() -> ssl.SSLContext:
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def load_overrides() -> list[tuple[str, str]]:
    """Parse spotify_playlists.txt. Each non-comment line is `name = URI`.
    Returns [(name, uri)]. URI accepted as bare spotify:* or web URL."""
    if not OVERRIDES.exists():
        return []
    out = []
    for raw in OVERRIDES.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        name, _, uri = line.partition("=")
        name = name.strip()
        uri  = uri.strip()
        if name and uri:
            out.append((name, uri))
    return out


def parse_uri(uri: str) -> tuple[str | None, str]:
    """Return (kind, id) for a spotify: URI or open.spotify.com URL.
    Returns (None, '') for anything we can't parse."""
    if uri.startswith("spotify:"):
        parts = uri.split(":")
        if len(parts) >= 3 and parts[1] in ("playlist", "album", "artist"):
            return (parts[1], parts[2])
    # Web URL: https://open.spotify.com/<kind>/<id>?si=...
    for kind in ("playlist", "album", "artist"):
        marker = f"open.spotify.com/{kind}/"
        if marker in uri:
            tail = uri.split(marker, 1)[1]
            sid  = tail.split("?", 1)[0].split("/", 1)[0]
            if sid:
                return (kind, sid)
    return (None, "")


def open_db() -> sqlite3.Connection:
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(TARGET_DB)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS items (
            kind        TEXT NOT NULL,
            id          TEXT NOT NULL,
            name        TEXT NOT NULL,
            art_hash    TEXT,
            indexed_at  INTEGER NOT NULL,
            PRIMARY KEY (kind, id)
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_items_name "
        "ON items(name COLLATE NOCASE)"
    )
    conn.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY, value TEXT
        )
    """)
    conn.commit()
    return conn


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not USER_LDB_CANDIDATES:
        sys.exit("no Spotify per-user primary.ldb found — is Spotify installed/signed-in?")
    src = USER_LDB_CANDIDATES[0]
    print(f"reading {src}")

    # Copy to /tmp because Spotify holds the original
    with tempfile.TemporaryDirectory() as tmp:
        dst = Path(tmp) / "ldb"
        shutil.copytree(src, dst)
        if (dst / "LOCK").exists():
            (dst / "LOCK").unlink()

        # (kind, id) -> Counter of (name, art_hash) -> votes
        votes: dict[tuple, Counter] = defaultdict(Counter)

        # Pass 1: dfindexeddb per-record values for albums / artists /
        # algorithmic playlists.
        reader = record.FolderReader(dst)
        n_records = 0
        for outer in reader.GetRecords():
            v = getattr(outer.record, "value", None)
            if v is None: continue
            n_records += 1
            for kind, sid, name, art in extract_pairs(v):
                votes[(kind, sid)][(name, art)] += 1

        # Pass 2: raw-file byte scan for user-created playlists. Their
        # name/id/art_hash straddle LevelDB record boundaries so the
        # per-record walk misses them.
        for ldb_file in sorted(dst.glob("*.ldb")) + sorted(dst.glob("*.log")):
            try:
                file_bytes = ldb_file.read_bytes()
            except OSError:
                continue
            for kind, sid, name, art in extract_user_playlists_from_raw(file_bytes):
                votes[(kind, sid)][(name, art)] += 1

        # Pick most-voted (name, art) per id; if art is None in winner but
        # other entries have one, fall back to the most common non-None art.
        finals: list[tuple[str, str, str, str | None]] = []
        for (kind, sid), counter in votes.items():
            (best_name, best_art), _ = counter.most_common(1)[0]
            if best_art is None:
                # find best art across all entries
                for (n, a), _ in counter.most_common():
                    if a:
                        best_art = a
                        break
            finals.append((kind, sid, best_name, best_art))

        print(f"records walked: {n_records}, distinct items: {len(finals)}")

    # Merge manual overrides from spotify_playlists.txt — they override
    # any auto-extracted entry with the same lowercased name. Art is
    # preserved across the swap: if the override's (kind, id) already
    # exists in auto-extracted finals (e.g. it's an algorithmic-prefix
    # playlist that Pass 1 picked up), we reuse that entry's art_hash.
    overrides = load_overrides()
    if overrides:
        art_by_id   = {(k, i): a for (k, i, _n, a) in finals if a}
        art_by_name = {n.lower(): a for (_k, _i, n, a) in finals if a}
        for (name, uri) in overrides:
            kind, sid = parse_uri(uri)
            if not kind:
                print(f"  ! skipping override {name!r}: unparseable URI {uri!r}")
                continue
            # Try art lookup by id first (most precise), then by name
            # (works when the auto-extracted entry had the right name but
            # the wrong id). If neither hits, fall back to Spotify's
            # oEmbed endpoint — that also validates the URI exists.
            art = (
                art_by_id.get((kind, sid))
                or art_by_name.get(name.lower())
                or fetch_oembed_art_hash(kind, sid, name)
            )
            # Drop any auto entry with same lowercased name or same id
            finals = [
                (k, i, n, a) for (k, i, n, a) in finals
                if n.lower() != name.lower() and (k, i) != (kind, sid)
            ]
            finals.append((kind, sid, name, art))
        print(f"applied {len(overrides)} override(s) from spotify_playlists.txt")

    # Write to spotify_index.db (open AFTER extraction so we don't hold
    # the lock while doing the slow walk).
    conn = open_db()
    now = int(time.time())
    conn.execute("DELETE FROM items")
    # INSERT OR REPLACE so duplicate (kind, id) from override+auto don't
    # crash the import — overrides come last in `finals` so they win.
    conn.executemany(
        "INSERT OR REPLACE INTO items(kind, id, name, art_hash, indexed_at) "
        "VALUES (?,?,?,?,?)",
        [(k, i, n, a, now) for (k, i, n, a) in finals],
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata(key, value) VALUES ('last_sync', ?)",
        (str(now),),
    )
    conn.commit()

    by_kind = Counter(k for k, _, _, _ in finals)
    for kind, n in sorted(by_kind.items()):
        with_art = sum(1 for k, _, _, a in finals if k == kind and a)
        print(f"  {kind}: {n} ({with_art} with artwork)")
    print(f"done → {TARGET_DB}")
    conn.close()


if __name__ == "__main__":
    main()
