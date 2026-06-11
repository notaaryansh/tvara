#!/usr/bin/env python3
"""
Benchmark text-embedding models on REAL Discord messages from tvara's index.

Source corpus AND queries both come from ~/Library/Application Support/tvara/discord_index.db.
We sample K messages out of the DB to use AS the queries; the remaining N
messages become the corpus. That way every model is asked "given this real
Discord message, what other real messages are most similar?" — apples-to-apples,
no synthetic prompts.

For each query message (real Discord text) we:
  1. Encode the corpus (N messages) once per model, time it.
  2. Encode the query message, cosine-rank against corpus, time it.
  3. Print the query's actual text + each model's top-K hits side by side
     so you can eyeball quality.
  4. Dump a JSON report next to this script for later diffing.

You can also force a fixed query set via --query-source json (uses
queries.json text_queries) — useful when you want deterministic queries
across runs.

Models compared:
  - openai:text-embedding-3-small   (current production; needs OPENAI_API_KEY)
  - openai:text-embedding-3-large   (cloud quality ceiling; optional)
  - st:BAAI/bge-small-en-v1.5       (local, 33M params, ~130MB, 384-dim, MIT)
  - st:sentence-transformers/all-MiniLM-L6-v2  (local, 22M, ~90MB, 384-dim, Apache 2.0)
  - st:mixedbread-ai/mxbai-embed-large-v1      (local, 335M, ~1.3GB, 1024-dim, Apache 2.0)

The `st:` (sentence-transformers) models require:
    pip install sentence-transformers

If sentence-transformers is missing, those models are skipped with a notice;
the OpenAI baseline still runs. This script is meant to be run by hand —
it's the dev path for picking which local model to convert to CoreML and
bundle in the app.

Usage:
    python3 scripts/embeddings/bench_text.py                          # 500 corpus, 10 real-message queries
    python3 scripts/embeddings/bench_text.py --limit 200 --num-queries 5
    python3 scripts/embeddings/bench_text.py --query-source json      # use queries.json instead
    python3 scripts/embeddings/bench_text.py --query-min-chars 80     # only sample meaty queries
    python3 scripts/embeddings/bench_text.py --seed 42                # reproducible sampling
    python3 scripts/embeddings/bench_text.py --models openai:text-embedding-3-small,st:BAAI/bge-small-en-v1.5
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
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
DISCORD_DB = Path.home() / "Library/Application Support/tvara/discord_index.db"
PROJECT_ENV = PROJECT_ROOT / ".env"

DEFAULT_MODELS = [
    "openai:text-embedding-3-small",
    "st:BAAI/bge-small-en-v1.5",
    "st:sentence-transformers/all-MiniLM-L6-v2",
]
MIN_CHARS = 20  # filter "k", "lol" — same threshold rationale as embed_messages.py


# --------------------------------------------------------------------------
# corpus + queries

def sample_corpus_and_queries(
    corpus_limit: int,
    num_queries: int,
    query_min_chars: int,
    seed: int | None,
) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """
    Pull (corpus_limit + num_queries) substantive messages from the DB.
    Pick num_queries of them as queries; the rest become the corpus.
    Both lists are (id, content). Query IDs are guaranteed not to appear in corpus.
    """
    if not DISCORD_DB.exists():
        sys.exit(f"discord_index.db missing at {DISCORD_DB}. Run tvara once to index, or point this script at a different source.")
    conn = sqlite3.connect(DISCORD_DB)
    # Pull a generous candidate pool so we have headroom after the query_min_chars filter.
    pool = conn.execute(
        "SELECT id, content FROM messages WHERE length(content) >= ? ORDER BY RANDOM() LIMIT ?",
        (MIN_CHARS, (corpus_limit + num_queries) * 3),
    ).fetchall()
    conn.close()

    rng = random.Random(seed)
    rng.shuffle(pool)
    query_pool = [(i, c) for i, c in pool if len(c) >= query_min_chars]
    if len(query_pool) < num_queries:
        sys.exit(
            f"only {len(query_pool)} messages meet query_min_chars={query_min_chars}; "
            f"lower --query-min-chars or raise --corpus-pool."
        )
    queries = query_pool[:num_queries]
    query_ids = {qid for qid, _ in queries}
    corpus = [(i, c) for i, c in pool if i not in query_ids][:corpus_limit]
    if len(corpus) < corpus_limit:
        # Top up — re-query without the limit constraint if needed.
        conn = sqlite3.connect(DISCORD_DB)
        extra_needed = corpus_limit - len(corpus)
        extra = conn.execute(
            f"SELECT id, content FROM messages "
            f"WHERE length(content) >= ? AND id NOT IN ({','.join('?' * len(query_ids))}) "
            f"ORDER BY RANDOM() LIMIT ?",
            (MIN_CHARS, *query_ids, extra_needed),
        ).fetchall()
        conn.close()
        corpus.extend(extra)
    return corpus, queries


def load_queries_from_json(path: Path) -> list[tuple[str, str]]:
    """Fallback path: synthetic queries from queries.json. Returns (synthetic_id, text) tuples."""
    data = json.loads(path.read_text())
    return [(f"json:{i}", q) for i, q in enumerate(data.get("text_queries", []))]


# --------------------------------------------------------------------------
# OpenAI client (stdlib only, matches embed_messages.py)

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


def openai_embed(texts: list[str], model: str, api_key: str) -> list[list[float]]:
    body = json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=60) as r:
        data = json.loads(r.read())
    return [d["embedding"] for d in data["data"]]


# --------------------------------------------------------------------------
# sentence-transformers wrapper

_ST_CACHE: dict[str, object] = {}


def st_load(model_id: str):
    if model_id in _ST_CACHE:
        return _ST_CACHE[model_id]
    try:
        from sentence_transformers import SentenceTransformer  # type: ignore
    except ImportError:
        return None
    m = SentenceTransformer(model_id)
    _ST_CACHE[model_id] = m
    return m


def st_embed(model_obj, texts: list[str], prompt_prefix: str = "") -> list[list[float]]:
    inputs = [prompt_prefix + t for t in texts] if prompt_prefix else texts
    vecs = model_obj.encode(inputs, normalize_embeddings=True, show_progress_bar=False)
    return vecs.tolist()


# BGE family wants a query prefix; corpus side gets no prefix.
BGE_QUERY_PREFIX = "Represent this sentence for searching relevant passages: "


# --------------------------------------------------------------------------
# cosine similarity (numpy if available, else pure-python fallback)

def _norm_dot(a: list[float], b: list[float]) -> float:
    s = na = nb = 0.0
    for x, y in zip(a, b):
        s += x * y
        na += x * x
        nb += y * y
    if na == 0 or nb == 0:
        return 0.0
    return s / ((na ** 0.5) * (nb ** 0.5))


def cosine_rank(query_vec: list[float], corpus_vecs: list[list[float]], top_k: int) -> list[tuple[int, float]]:
    try:
        import numpy as np  # type: ignore
        q = np.asarray(query_vec, dtype="float32")
        m = np.asarray(corpus_vecs, dtype="float32")
        qn = q / (np.linalg.norm(q) + 1e-12)
        mn = m / (np.linalg.norm(m, axis=1, keepdims=True) + 1e-12)
        sims = mn @ qn
        idx = sims.argsort()[::-1][:top_k]
        return [(int(i), float(sims[i])) for i in idx]
    except ImportError:
        scored = [(i, _norm_dot(query_vec, v)) for i, v in enumerate(corpus_vecs)]
        scored.sort(key=lambda x: x[1], reverse=True)
        return scored[:top_k]


# --------------------------------------------------------------------------
# bench runner

@dataclass
class ModelResult:
    model_id: str
    skipped: bool = False
    skip_reason: str = ""
    corpus_encode_seconds: float = 0.0
    avg_query_seconds: float = 0.0
    dim: int = 0
    per_query: dict[str, list[dict]] = field(default_factory=dict)  # query -> list of {rank, score, message_id, snippet}


def run_model(model_spec: str, corpus_rows: list[tuple[str, str]], queries: list[str], top_k: int) -> ModelResult:
    res = ModelResult(model_id=model_spec)
    texts = [c for _, c in corpus_rows]
    ids = [i for i, _ in corpus_rows]

    if model_spec.startswith("openai:"):
        model_name = model_spec.split(":", 1)[1]
        key = load_openai_key()
        if not key:
            res.skipped = True
            res.skip_reason = "OPENAI_API_KEY not set (env or .env)"
            return res
        t0 = time.time()
        corpus_vecs: list[list[float]] = []
        BATCH = 100
        for i in range(0, len(texts), BATCH):
            corpus_vecs.extend(openai_embed(texts[i : i + BATCH], model_name, key))
        res.corpus_encode_seconds = time.time() - t0
        res.dim = len(corpus_vecs[0]) if corpus_vecs else 0
        q_times = []
        for q in queries:
            qt0 = time.time()
            qv = openai_embed([q], model_name, key)[0]
            ranked = cosine_rank(qv, corpus_vecs, top_k)
            q_times.append(time.time() - qt0)
            res.per_query[q] = [
                {"rank": r + 1, "score": s, "message_id": ids[i], "snippet": texts[i][:120].replace("\n", " ")}
                for r, (i, s) in enumerate(ranked)
            ]
        res.avg_query_seconds = sum(q_times) / len(q_times) if q_times else 0.0
        return res

    if model_spec.startswith("st:"):
        model_name = model_spec.split(":", 1)[1]
        m = st_load(model_name)
        if m is None:
            res.skipped = True
            res.skip_reason = "sentence-transformers not installed (pip install sentence-transformers)"
            return res
        prefix = BGE_QUERY_PREFIX if "bge" in model_name.lower() else ""
        t0 = time.time()
        corpus_vecs = st_embed(m, texts, prompt_prefix="")
        res.corpus_encode_seconds = time.time() - t0
        res.dim = len(corpus_vecs[0]) if corpus_vecs else 0
        q_times = []
        for q in queries:
            qt0 = time.time()
            qv = st_embed(m, [q], prompt_prefix=prefix)[0]
            ranked = cosine_rank(qv, corpus_vecs, top_k)
            q_times.append(time.time() - qt0)
            res.per_query[q] = [
                {"rank": r + 1, "score": s, "message_id": ids[i], "snippet": texts[i][:120].replace("\n", " ")}
                for r, (i, s) in enumerate(ranked)
            ]
        res.avg_query_seconds = sum(q_times) / len(q_times) if q_times else 0.0
        return res

    res.skipped = True
    res.skip_reason = f"unknown model spec prefix: {model_spec}"
    return res


# --------------------------------------------------------------------------
# printing

def print_summary(results: list[ModelResult], corpus_size: int) -> None:
    print()
    print("=" * 78)
    print(f"SUMMARY  (corpus = {corpus_size} Discord messages)")
    print("=" * 78)
    print(f"{'model':<55} {'dim':>5} {'encode_s':>10} {'q_avg_ms':>10}")
    for r in results:
        if r.skipped:
            print(f"{r.model_id:<55} SKIPPED — {r.skip_reason}")
            continue
        print(f"{r.model_id:<55} {r.dim:>5} {r.corpus_encode_seconds:>10.2f} {r.avg_query_seconds*1000:>10.1f}")
    print()


def print_per_query(results: list[ModelResult], queries: list[str]) -> None:
    for q in queries:
        print()
        print("-" * 78)
        print(f"QUERY: {q}")
        print("-" * 78)
        for r in results:
            if r.skipped:
                continue
            print(f"\n  [{r.model_id}]")
            for hit in r.per_query.get(q, []):
                print(f"    {hit['rank']}. ({hit['score']:.3f})  {hit['snippet']}")


# --------------------------------------------------------------------------
# main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=500, help="number of Discord messages to embed")
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS),
                    help="comma-separated list, prefix openai: or st:")
    ap.add_argument("--queries-file", default=str(HERE / "queries.json"))
    ap.add_argument("--report", default=str(HERE / "last_text_run.json"),
                    help="where to write the JSON report")
    args = ap.parse_args()

    corpus = load_corpus(args.limit)
    queries = load_queries(Path(args.queries_file))
    models = [m.strip() for m in args.models.split(",") if m.strip()]

    print(f"corpus: {len(corpus)} messages from {DISCORD_DB.name}")
    print(f"queries: {len(queries)}  (from {args.queries_file})")
    print(f"models: {models}")
    print()

    results: list[ModelResult] = []
    for spec in models:
        print(f"running {spec} ...")
        try:
            results.append(run_model(spec, corpus, queries, args.topk))
        except Exception as e:
            results.append(ModelResult(model_id=spec, skipped=True, skip_reason=f"crashed: {e}"))
            print(f"  !! {spec} crashed: {e}")

    print_per_query(results, queries)
    print_summary(results, len(corpus))

    report = {
        "corpus_size": len(corpus),
        "queries": queries,
        "models": [
            {
                "model_id": r.model_id,
                "skipped": r.skipped,
                "skip_reason": r.skip_reason,
                "dim": r.dim,
                "corpus_encode_seconds": r.corpus_encode_seconds,
                "avg_query_seconds": r.avg_query_seconds,
                "per_query": r.per_query,
            }
            for r in results
        ],
    }
    Path(args.report).write_text(json.dumps(report, indent=2))
    print(f"wrote {args.report}")


if __name__ == "__main__":
    main()
