#!/usr/bin/env python3
"""
Build a ground-truth (query, target_message_id) dataset from REAL Discord
messages in ~/Library/Application Support/tvara/discord_index.db.

Why this exists
---------------
The Discord DB has no reply_to / thread_id columns, so we cannot derive
query-target pairs from the schema alone. We need synthetic-but-grounded
pairs where:

  - the TARGET is a real Discord message you actually have
  - the QUERY is a natural-language phrase that should retrieve that target

Then bench_text.py can ask each embedding model: "for this query, at what
rank did you return the actual target?" — the only metric that matters for
"can you find the thing I care about in messy data."

Two generation methods are supported.

Method 1 — paraphrase  (default, recommended)
  Sample N substantive messages. For each, ask an LLM to write a short
  natural query a real user might type to find that message. Pros: highest
  signal, mimics actual search behaviour. Cons: needs an API key and the
  LLM "knows" the answer so queries are slightly easier than wild ones —
  standard caveat in retrieval eval (BEIR, MTEB).

Method 2 — temporal
  Find pairs of messages in the same channel within 60s of each other (real
  back-and-forth conversation). Use the earlier message as the "query" and
  the later one as the target. Pros: no API needed, real human signal. Cons:
  noisier — sometimes the two messages are unrelated.

Output
------
scripts/embeddings/ground_truth.json with shape:

  {
    "method": "paraphrase" | "temporal",
    "generated_at": <unix ts>,
    "generator_model": "gpt-5.5-mini" | null,
    "pairs": [
      {
        "query":         "how do i install gstreamer on android",
        "target_id":     "1304165722481623040",
        "target_text":   "!sudo apt-get install -y libgstreamer1.0 ...",
        "channel_id":    "...",
        "notes":         "paraphrase of target"   // free-form
      },
      ...
    ]
  }

Usage:
    python3 scripts/embeddings/generate_ground_truth.py                       # 30 pairs, paraphrase
    python3 scripts/embeddings/generate_ground_truth.py --method temporal --n 50
    python3 scripts/embeddings/generate_ground_truth.py --n 100 --min-chars 120 --seed 1
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sqlite3
import ssl
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
DISCORD_DB = Path.home() / "Library/Application Support/tvara/discord_index.db"
PROJECT_ENV = PROJECT_ROOT / ".env"
OUT_FILE = HERE / "ground_truth.json"

DEFAULT_PARAPHRASE_MODEL = "gpt-5.5-mini"
TEMPORAL_WINDOW_SECONDS = 60


# --------------------------------------------------------------------------
# OpenAI helpers (stdlib only)

def load_openai_key() -> str | None:
    if k := os.environ.get("OPENAI_API_KEY"):
        return k.strip()
    if PROJECT_ENV.exists():
        for line in PROJECT_ENV.read_text().splitlines():
            m = re.match(r'(?:export\s+)?OPENAI_API_KEY\s*=\s*"?([^"\n]+)"?', line)
            if m:
                return m.group(1).strip()
    return None


def _ssl_ctx() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SYS_PROMPT = (
    "You write realistic search queries. Given a Discord message, output a single "
    "short natural-language query (3-12 words) that a real user might type into a "
    "launcher to FIND that exact message later. Do NOT quote the message text. "
    "Do NOT mention 'Discord'. Use plain lowercase, no punctuation at the end. "
    "If the message is gibberish or has no findable content, respond with the "
    "single word: SKIP"
)


def paraphrase_query(message_text: str, model: str, api_key: str) -> str | None:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYS_PROMPT},
            {"role": "user", "content": message_text[:2000]},
        ],
        "temperature": 0.3,
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=30) as r:
            data = json.loads(r.read())
    except Exception as e:
        print(f"  paraphrase failed: {e}")
        return None
    q = data["choices"][0]["message"]["content"].strip().lower()
    q = q.strip('"').strip("'").rstrip(".!?")
    if q == "skip" or len(q) < 3:
        return None
    return q


# --------------------------------------------------------------------------
# samplers

def sample_paraphrase_targets(n: int, min_chars: int, seed: int | None) -> list[tuple[str, str, str]]:
    """Return list of (id, channel_id, content) for messages substantive enough to paraphrase."""
    if not DISCORD_DB.exists():
        sys.exit(f"discord_index.db missing at {DISCORD_DB}")
    conn = sqlite3.connect(DISCORD_DB)
    pool = conn.execute(
        "SELECT id, channel_id, content FROM messages "
        "WHERE length(content) >= ? "
        "ORDER BY RANDOM() LIMIT ?",
        (min_chars, n * 4),
    ).fetchall()
    conn.close()
    if seed is not None:
        random.Random(seed).shuffle(pool)
    return pool


def sample_temporal_pairs(n: int, min_chars: int, seed: int | None) -> list[tuple[str, str, str, str]]:
    """
    Find (query_msg, target_msg) pairs where both are in the same channel within
    TEMPORAL_WINDOW_SECONDS of each other and both meet min_chars. Returns
    list of (query_id, query_text, target_id, target_text).
    """
    if not DISCORD_DB.exists():
        sys.exit(f"discord_index.db missing at {DISCORD_DB}")
    conn = sqlite3.connect(DISCORD_DB)
    # Self-join messages within the time window in the same channel.
    rows = conn.execute(
        """
        SELECT a.id, a.content, b.id, b.content
        FROM messages a
        JOIN messages b
          ON b.channel_id = a.channel_id
         AND b.timestamp  > a.timestamp
         AND b.timestamp  - a.timestamp <= ?
         AND b.id != a.id
        WHERE length(a.content) >= ?
          AND length(b.content) >= ?
        ORDER BY RANDOM()
        LIMIT ?
        """,
        (TEMPORAL_WINDOW_SECONDS, min_chars, min_chars, n * 3),
    ).fetchall()
    conn.close()
    if seed is not None:
        random.Random(seed).shuffle(rows)
    return rows


# --------------------------------------------------------------------------
# main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", choices=["paraphrase", "temporal"], default="paraphrase")
    ap.add_argument("--n", type=int, default=30, help="number of (query, target) pairs to produce")
    ap.add_argument("--min-chars", type=int, default=80,
                    help="minimum message length to be considered (filters 'lol', 'k', etc.)")
    ap.add_argument("--model", default=DEFAULT_PARAPHRASE_MODEL,
                    help="OpenAI chat model for paraphrase mode")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", default=str(OUT_FILE))
    args = ap.parse_args()

    pairs: list[dict] = []

    if args.method == "paraphrase":
        api_key = load_openai_key()
        if not api_key:
            sys.exit("OPENAI_API_KEY required for paraphrase mode (use --method temporal for an offline alternative)")
        targets = sample_paraphrase_targets(args.n, args.min_chars, args.seed)
        print(f"sampled {len(targets)} candidate messages; generating queries with {args.model} ...")
        for mid, cid, content in targets:
            if len(pairs) >= args.n:
                break
            q = paraphrase_query(content, args.model, api_key)
            if q is None:
                continue
            pairs.append({
                "query": q,
                "target_id": mid,
                "target_text": content,
                "channel_id": cid,
                "notes": "paraphrase of target",
            })
            print(f"  [{len(pairs):>3}/{args.n}]  q: {q[:60]}")
        method_meta = {"generator_model": args.model}

    else:  # temporal
        candidates = sample_temporal_pairs(args.n, args.min_chars, args.seed)
        print(f"found {len(candidates)} temporal pair candidates within {TEMPORAL_WINDOW_SECONDS}s windows")
        for qid, qtext, tid, ttext in candidates:
            if len(pairs) >= args.n:
                break
            pairs.append({
                "query": qtext.strip().splitlines()[0][:200],
                "target_id": tid,
                "target_text": ttext,
                "query_message_id": qid,
                "notes": f"temporal pair, same channel within {TEMPORAL_WINDOW_SECONDS}s",
            })
        method_meta = {"generator_model": None}

    if not pairs:
        sys.exit("no pairs produced — try a lower --min-chars or larger --n")

    out = {
        "method": args.method,
        "generated_at": int(time.time()),
        "source_db": str(DISCORD_DB),
        **method_meta,
        "pairs": pairs,
    }
    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"\nwrote {len(pairs)} pairs to {args.out}")


if __name__ == "__main__":
    main()
