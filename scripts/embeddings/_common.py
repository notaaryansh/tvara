"""
Shared helpers for scripts/embeddings/. Pure stdlib (+ certifi if installed).

Used by:
  - build_eval.py      (orchestrator)
  - review_cli.py      (interactive review)
  - bench_text.py      (future evolution to read eval_dataset.json)
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import ssl
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
PROJECT_ENV = PROJECT_ROOT / ".env"
DISCORD_DB = Path.home() / "Library/Application Support/tvara/discord_index.db"


# --------------------------------------------------------------------------
# .env / env key loading

def _load_env_key(name: str) -> str | None:
    if v := os.environ.get(name):
        return v.strip()
    if PROJECT_ENV.exists():
        for line in PROJECT_ENV.read_text().splitlines():
            m = re.match(rf'(?:export\s+)?{re.escape(name)}\s*=\s*"?([^"\n]+)"?', line)
            if m:
                return m.group(1).strip()
    return None


def load_openai_key(required: bool = True) -> str | None:
    k = _load_env_key("OPENAI_API_KEY")
    if k is None and required:
        sys.exit("OPENAI_API_KEY not found in env or .env")
    return k


# --------------------------------------------------------------------------
# TLS context (macOS framework Python often has empty trust store; certifi fixes)

def ssl_ctx() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


# --------------------------------------------------------------------------
# Discord DB

def discord_connect() -> sqlite3.Connection:
    if not DISCORD_DB.exists():
        sys.exit(f"discord_index.db missing at {DISCORD_DB}")
    return sqlite3.connect(DISCORD_DB)


# --------------------------------------------------------------------------
# Tokenization + n-gram overlap (used by the validator)

_STOP = {
    "the", "a", "an", "and", "or", "but", "if", "of", "to", "in", "on", "at",
    "for", "with", "by", "from", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "i", "you", "he", "she", "it", "we",
    "they", "this", "that", "these", "those", "as", "so", "than", "too", "just",
    "my", "your", "our", "their", "me", "us", "him", "her", "them", "its",
    "what", "when", "where", "why", "how", "can", "could", "would", "should",
    "will", "shall", "may", "might", "must", "not", "no", "yes",
}


def tokenize_for_overlap(text: str) -> list[str]:
    """Lowercase, strip punctuation, drop stopwords, light stem (trailing -s/-ing/-ed)."""
    text = text.lower()
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"<@!?\d+>", " ", text)
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    toks = [t for t in text.split() if t and t not in _STOP and len(t) > 1]
    stemmed: list[str] = []
    for t in toks:
        if t.endswith("ing") and len(t) > 5:
            t = t[:-3]
        elif t.endswith("ed") and len(t) > 4:
            t = t[:-2]
        elif t.endswith("s") and len(t) > 3 and not t.endswith("ss"):
            t = t[:-1]
        stemmed.append(t)
    return stemmed


def ngrams(tokens: list[str], n: int) -> set[tuple[str, ...]]:
    if len(tokens) < n:
        return set()
    return {tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1)}


def ngram_overlap(query: str, target: str, n: int = 3) -> float:
    """Jaccard overlap of n-grams between query and target after stemming."""
    qt = tokenize_for_overlap(query)
    tt = tokenize_for_overlap(target)
    qg = ngrams(qt, n)
    tg = ngrams(tt, n)
    if not qg or not tg:
        return 0.0
    inter = qg & tg
    union = qg | tg
    return len(inter) / len(union) if union else 0.0


def unigram_overlap(query: str, target: str) -> float:
    """Jaccard overlap of unigrams — broader signal than 3-grams when one side is short."""
    qt = set(tokenize_for_overlap(query))
    tt = set(tokenize_for_overlap(target))
    if not qt or not tt:
        return 0.0
    return len(qt & tt) / len(qt | tt)


# --------------------------------------------------------------------------
# Atomic JSON write (used by review_cli to survive Ctrl-C)

def atomic_write_json(path: Path, data) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(path)
