#!/usr/bin/env python3
"""
Bulk-embed Discord messages from spotlight++'s discord_index.db.

Reads:  ~/Library/Application Support/spotlight++/discord_index.db (messages table)
Writes: ~/Library/Application Support/spotlight++/embeddings.db

For the demo we embed Discord only. Other sources can be added by extending
SOURCES below. Rows already embedded with the same model are skipped, so
re-running is safe and incremental — the Python script *is* the bulk path;
in production this work lives behind a queued embedding service.

The vector is stored as raw float32 bytes (4 bytes per dim → 6144 bytes per
row for text-embedding-3-small). Swift reads it via Data → [Float] cast.

Usage:
    python3 scripts/embed_messages.py
    python3 scripts/embed_messages.py --model text-embedding-3-large
    python3 scripts/embed_messages.py --limit 500   # smoke test
"""
import argparse
import json
import os
import re
import sqlite3
import struct
import sys
import time
import urllib.request
import ssl
from pathlib import Path

SUPPORT_DIR = Path.home() / "Library/Application Support/spotlight++"
SOURCE_DB   = SUPPORT_DIR / "discord_index.db"
TARGET_DB   = SUPPORT_DIR / "embeddings.db"
PROJECT_ENV = Path(__file__).resolve().parent.parent / ".env"

DEFAULT_MODEL = "text-embedding-3-small"
BATCH_SIZE    = 100   # OpenAI accepts up to 2048; 100 keeps requests snappy
MIN_CHARS     = 4     # skip "k", "lol", "ok" — embedding noise wastes tokens

SOURCES = {
    "discord": {
        "db": SOURCE_DB,
        "query": "SELECT id, content FROM messages WHERE length(content) >= ?",
    },
}


def load_api_key() -> str:
    if k := os.environ.get("OPENAI_API_KEY"):
        return k.strip()
    if PROJECT_ENV.exists():
        with PROJECT_ENV.open() as f:
            for line in f:
                m = re.match(r'(?:export\s+)?OPENAI_API_KEY\s*=\s*"?([^"\n]+)"?', line)
                if m:
                    return m.group(1).strip()
    sys.exit("OPENAI_API_KEY not found in env or .env")


def open_embeddings_db() -> sqlite3.Connection:
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(TARGET_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS embeddings (
            message_id  TEXT NOT NULL,
            source      TEXT NOT NULL,
            model       TEXT NOT NULL,
            dim         INTEGER NOT NULL,
            embedding   BLOB NOT NULL,
            embedded_at INTEGER NOT NULL,
            PRIMARY KEY (message_id, source, model)
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_embeddings_source_model "
        "ON embeddings(source, model)"
    )
    conn.commit()
    return conn


def load_pending(source: str, model: str, limit: int | None) -> list[tuple[str, str]]:
    """Return rows from `source` that don't yet have an embedding for `model`."""
    cfg = SOURCES[source]
    src = sqlite3.connect(cfg["db"])
    src.execute(f"ATTACH DATABASE '{TARGET_DB}' AS emb")
    sql = f"""
        SELECT m.id, m.content
        FROM messages m
        LEFT JOIN emb.embeddings e
          ON e.message_id = m.id
         AND e.source = '{source}'
         AND e.model = ?
        WHERE length(m.content) >= ?
          AND e.message_id IS NULL
    """
    if limit:
        sql += f" LIMIT {int(limit)}"
    rows = src.execute(sql, (model, MIN_CHARS)).fetchall()
    src.close()
    return rows


def _ssl_ctx() -> ssl.SSLContext:
    """Verify TLS using certifi's CA bundle when available, else system store.
    macOS' framework Python often lacks a populated default trust store, so
    `pip install certifi` is the canonical fix — never disable verification
    while sending API keys."""
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def embed_batch(texts: list[str], model: str, api_key: str) -> list[list[float]]:
    body = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=60) as r:
        data = json.loads(r.read())
    return [d["embedding"] for d in data["data"]]


def pack(vec: list[float]) -> bytes:
    return struct.pack(f"{len(vec)}f", *vec)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model",  default=DEFAULT_MODEL)
    ap.add_argument("--source", default="discord", choices=list(SOURCES))
    ap.add_argument("--limit",  type=int, default=None,
                    help="cap rows for a smoke test")
    args = ap.parse_args()

    api_key = load_api_key()
    if not SOURCES[args.source]["db"].exists():
        sys.exit(f"source db missing: {SOURCES[args.source]['db']}")

    # Create the target db / table first so the ATTACH inside load_pending
    # can see the embeddings table even on a clean run.
    target = open_embeddings_db()

    rows = load_pending(args.source, args.model, args.limit)
    print(f"{len(rows)} rows pending for source={args.source} model={args.model}")
    if not rows:
        return
    insert_sql = """
        INSERT OR REPLACE INTO embeddings
            (message_id, source, model, dim, embedding, embedded_at)
        VALUES (?, ?, ?, ?, ?, ?)
    """

    done = 0
    t0 = time.time()
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        ids  = [r[0] for r in batch]
        txts = [r[1] for r in batch]
        try:
            vecs = embed_batch(txts, args.model, api_key)
        except Exception as e:
            print(f"batch {i // BATCH_SIZE} failed: {e}; skipping")
            time.sleep(2)
            continue

        now = int(time.time())
        rows_to_write = [
            (mid, args.source, args.model, len(v), pack(v), now)
            for mid, v in zip(ids, vecs)
        ]
        target.executemany(insert_sql, rows_to_write)
        target.commit()
        done += len(batch)
        elapsed = time.time() - t0
        rate = done / elapsed if elapsed > 0 else 0
        print(f"  {done}/{len(rows)}  ({rate:.0f} rows/s)")

    print(f"done. wrote {done} embeddings to {TARGET_DB}")


if __name__ == "__main__":
    main()
