#!/usr/bin/env python3
"""
Pick N random Discord messages, look at each one, and craft a natural search
query that SHOULD retrieve that exact message. This gives us ground-truth
(query, target_message_id) pairs we can use to score embedding models.

Why we need this
----------------
discord_index.db has no reply_to or thread columns, so there's no built-in
"these two messages belong together" signal. We need labelled pairs to
answer the question "did the model put the right message at the top?"

We use an LLM (OpenAI by default) only at GENERATION time. The bench itself
runs offline. Queries can be inspected and hand-edited in ground_truth.json
before benching.

Output: scripts/embeddings/ground_truth.json
  {
    "generated_at": <ts>,
    "generator_model": "gpt-5.5-mini",
    "source_db": "...",
    "pairs": [
      {
        "query":        "how do i install gstreamer on ubuntu",
        "target_id":    "1304165722481623040",
        "target_text":  "!sudo apt-get install -y libgstreamer1.0 ...",
        "channel_id":   "..."
      },
      ...
    ]
  }

Usage:
    python3 scripts/embeddings/generate_ground_truth.py            # 7 pairs, default model
    python3 scripts/embeddings/generate_ground_truth.py --n 10
    python3 scripts/embeddings/generate_ground_truth.py --min-chars 120 --seed 42
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

DEFAULT_MODEL = "gpt-5.5"  # matches SmartSearchService — reasoning model, no temperature
DEFAULT_N = 7
DEFAULT_MIN_CHARS = 80


SYS_PROMPT = (
    "You write realistic search queries. Given a Discord message, output a "
    "single short natural-language query (3-12 words, lowercase, no quotes, no "
    "trailing punctuation) that a real user might type into a launcher to FIND "
    "that exact message later. Do NOT quote the message verbatim. Do NOT "
    "mention Discord. Capture the TOPIC, not the exact words. If the message "
    "is gibberish, code-only with no recognisable intent, or has no findable "
    "content, respond with the single word: SKIP"
)


def load_openai_key() -> str:
    if k := os.environ.get("OPENAI_API_KEY"):
        return k.strip()
    if PROJECT_ENV.exists():
        for line in PROJECT_ENV.read_text().splitlines():
            m = re.match(r'(?:export\s+)?OPENAI_API_KEY\s*=\s*"?([^"\n]+)"?', line)
            if m:
                return m.group(1).strip()
    sys.exit("OPENAI_API_KEY required (env or .env). The bench itself runs offline; only generation needs an API.")


def _ssl_ctx() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def craft_query(message_text: str, model: str, api_key: str) -> str | None:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYS_PROMPT},
            {"role": "user", "content": message_text[:2000]},
        ],
        "reasoning_effort": "low",  # gpt-5.5 family — see SmartSearchService.swift
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=30) as r:
            data = json.loads(r.read())
    except Exception as e:
        print(f"  ! query generation failed: {e}")
        return None
    q = data["choices"][0]["message"]["content"].strip().lower()
    q = q.strip('"').strip("'").rstrip(".!?")
    if q == "skip" or len(q) < 3:
        return None
    return q


def sample_targets(n: int, min_chars: int, seed: int | None) -> list[tuple[str, str, str]]:
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=DEFAULT_N, help="number of (query, target) pairs to produce")
    ap.add_argument("--min-chars", type=int, default=DEFAULT_MIN_CHARS,
                    help="minimum target message length (filters 'lol', 'k', etc.)")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="OpenAI chat model for query generation")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", default=str(OUT_FILE))
    args = ap.parse_args()

    api_key = load_openai_key()
    candidates = sample_targets(args.n, args.min_chars, args.seed)
    print(f"sampled {len(candidates)} candidate messages (min_chars={args.min_chars})")
    print(f"generating queries with {args.model} ...\n")

    pairs: list[dict] = []
    for mid, cid, content in candidates:
        if len(pairs) >= args.n:
            break
        preview = content.replace("\n", " ")[:90]
        print(f"target {len(pairs) + 1:>2}: {preview}")
        q = craft_query(content, args.model, api_key)
        if q is None:
            print("           SKIPPED\n")
            continue
        print(f"   query: {q}\n")
        pairs.append({
            "query": q,
            "target_id": mid,
            "target_text": content,
            "channel_id": cid,
        })

    if not pairs:
        sys.exit("no pairs produced — try a lower --min-chars or larger --n pool")

    out = {
        "generated_at": int(time.time()),
        "generator_model": args.model,
        "source_db": str(DISCORD_DB),
        "pairs": pairs,
    }
    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"wrote {len(pairs)} pairs to {args.out}")
    print(f"inspect / hand-edit, then run: python3 scripts/embeddings/bench_text.py")


if __name__ == "__main__":
    main()
