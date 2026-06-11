#!/usr/bin/env python3
"""
Benchmark text-embedding models against the v2 eval dataset.

Reads:  scripts/embeddings/eval_dataset.json  (built by build_eval.py, reviewed
                                               via review_cli.py)
The question this answers, per pair:
    "Given the query, at what rank did each model return the actual target
     message?" — i.e. can the model FIND THE THING in messy data.

We measure:
  - rank of the ground-truth target per pair
  - Mean Reciprocal Rank (MRR) — single-number quality score
  - Recall@1 / Recall@5 / Recall@10
  - Per-difficulty-tier MRR / Recall — the WHOLE POINT of the stratified
    eval set: easy / medium / hard / very_hard each get their own row

Corpus construction follows the `corpus_recipe` contract in eval_dataset.json:
    corpus = all pair.target_id
           + union of pair.hard_negatives  (forced, adversarial)
           + random_distractor_count random distractors (excluding the above)

Hard negatives are NOT optional. They were mined by text-embedding-3-small
itself to be confusable with the query, so an "easy random corpus" cannot
artificially help any model.

Reviewer-decision filter (default): include `accepted`, `edited`, and
`pending` pairs. Always exclude `rejected`. Pass `--strict` to require
human acceptance (excludes pending).

Models
------
  - openai:text-embedding-3-small            current production baseline
  - openai:text-embedding-3-large            cloud ceiling, optional
  - st:BAAI/bge-small-en-v1.5                 local, ~130MB, 384-dim
  - st:sentence-transformers/all-MiniLM-L6-v2 local, ~90MB, 384-dim
  - st:mixedbread-ai/mxbai-embed-large-v1     local, ~1.3GB, 1024-dim

`st:` models require: pip install sentence-transformers

Usage:
    python3 scripts/embeddings/bench_text.py
    python3 scripts/embeddings/bench_text.py --strict          # accepted/edited only
    python3 scripts/embeddings/bench_text.py --models openai:text-embedding-3-small,st:BAAI/bge-small-en-v1.5
    python3 scripts/embeddings/bench_text.py --distractors 3000
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    HERE,
    discord_connect,
    load_openai_key,
    ssl_ctx,
)

import json as _json  # noqa: E402

EVAL_FILE = HERE / "eval_dataset.json"
DEFAULT_MODELS = [
    "openai:text-embedding-3-small",
    "st:BAAI/bge-small-en-v1.5",
    "st:sentence-transformers/all-MiniLM-L6-v2",
]
DEFAULT_DISTRACTORS_OVERRIDE: int | None = None  # None means use corpus_recipe
MIN_DISTRACTOR_CHARS = 20
BGE_QUERY_PREFIX = "Represent this sentence for searching relevant passages: "


# --------------------------------------------------------------------------
# load eval dataset + build corpus per corpus_recipe

def load_eval(path: Path, strict: bool) -> tuple[dict, list[dict]]:
    if not path.exists():
        sys.exit(
            f"missing {path}\n"
            f"run first:  python3 scripts/embeddings/build_eval.py"
        )
    data = _json.loads(path.read_text())
    if data.get("version") != "2":
        sys.exit(f"unexpected eval_dataset version: {data.get('version')}")
    if strict:
        allowed = {"accepted", "edited"}
    else:
        allowed = {"accepted", "edited", "pending"}
    pairs = [p for p in data["pairs"] if p["reviewer_decision"] in allowed]
    if not pairs:
        sys.exit(
            f"no pairs match reviewer_decision filter {sorted(allowed)} — "
            f"either review some pairs or drop --strict"
        )
    return data, pairs


def build_corpus(eval_data: dict, pairs: list[dict], distractor_override: int | None) -> tuple[list[str], list[str]]:
    """
    Returns (ids, texts) for the bench corpus, in a consistent order:
        [all target_ids] + [hard negatives unique] + [random distractors]

    Random distractors exclude every target_id and hard_negative id, sampled
    from discord_index.db. The random sampling seed comes from corpus_recipe.
    """
    recipe = eval_data["corpus_recipe"]
    distractor_count = distractor_override if distractor_override is not None else recipe["random_distractor_count"]
    seed = recipe["random_distractor_seed"]
    min_chars = recipe["min_distractor_chars"]

    target_ids = [p["target_id"] for p in pairs]
    target_texts = [p["target_text"] for p in pairs]

    # collect mandatory hard negs across the (filtered) pair set
    hard_neg_ids: list[str] = []
    seen: set[str] = set(target_ids)
    for p in pairs:
        for neg in p["hard_negatives"]:
            mid = neg["message_id"]
            if mid in seen:
                continue
            seen.add(mid)
            hard_neg_ids.append(mid)

    # fetch hard-neg + random distractor texts from the DB
    conn = discord_connect()

    hard_neg_texts: list[str] = []
    if hard_neg_ids:
        placeholders = ",".join("?" * len(hard_neg_ids))
        rows = conn.execute(
            f"SELECT id, content FROM messages WHERE id IN ({placeholders})",
            hard_neg_ids,
        ).fetchall()
        text_by_id = {mid: c for mid, c in rows}
        # preserve hard_neg_ids order, drop any that the DB couldn't find
        filtered_neg_ids: list[str] = []
        for mid in hard_neg_ids:
            if mid in text_by_id:
                filtered_neg_ids.append(mid)
                hard_neg_texts.append(text_by_id[mid])
        hard_neg_ids = filtered_neg_ids

    # exclusion set for the random distractor sample
    excluded = set(target_ids) | set(hard_neg_ids)
    rng = random.Random(seed)

    # Pull a generous pool and shuffle deterministically — keeps the run
    # reproducible across reruns with the same seed.
    pool_rows = conn.execute(
        "SELECT id, content FROM messages WHERE length(content) >= ?",
        (min_chars,),
    ).fetchall()
    conn.close()

    # filter excluded, shuffle, slice
    eligible = [(mid, txt) for mid, txt in pool_rows if mid not in excluded]
    rng.shuffle(eligible)
    distractors = eligible[:distractor_count]
    distractor_ids = [mid for mid, _ in distractors]
    distractor_texts = [txt for _, txt in distractors]

    ids = target_ids + hard_neg_ids + distractor_ids
    texts = target_texts + hard_neg_texts + distractor_texts
    return ids, texts


# --------------------------------------------------------------------------
# OpenAI

def openai_embed(texts: list[str], model: str, api_key: str) -> list[list[float]]:
    body = _json.dumps({"model": model, "input": texts}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=60) as r:
        data = _json.loads(r.read())
    return [d["embedding"] for d in data["data"]]


# --------------------------------------------------------------------------
# sentence-transformers

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


# --------------------------------------------------------------------------
# ranking

def rank_corpus(query_vec, corpus_vecs):
    import numpy as np  # type: ignore
    q = np.asarray(query_vec, dtype="float32")
    m = np.asarray(corpus_vecs, dtype="float32")
    qn = q / (np.linalg.norm(q) + 1e-12)
    mn = m / (np.linalg.norm(m, axis=1, keepdims=True) + 1e-12)
    sims = mn @ qn
    order = sims.argsort()[::-1]
    return [(int(i), float(sims[i])) for i in order]


# --------------------------------------------------------------------------
# runner

@dataclass
class PerPair:
    pair_id: str
    query: str
    target_id: str
    target_text: str
    difficulty: str
    query_style: str
    target_rank: int          # 1-indexed; 0 = not in corpus
    target_score: float
    top1_id: str
    top1_text: str
    top1_score: float


@dataclass
class ModelResult:
    model_id: str
    skipped: bool = False
    skip_reason: str = ""
    corpus_encode_seconds: float = 0.0
    avg_query_seconds: float = 0.0
    dim: int = 0
    per_pair: list[PerPair] = field(default_factory=list)
    mrr: float = 0.0
    recall_at_1: float = 0.0
    recall_at_5: float = 0.0
    recall_at_10: float = 0.0


def run_model(spec: str, corpus_ids: list[str], corpus_texts: list[str], pairs: list[dict]) -> ModelResult:
    res = ModelResult(model_id=spec)

    if spec.startswith("openai:"):
        model_name = spec.split(":", 1)[1]
        key = load_openai_key(required=False)
        if not key:
            res.skipped = True
            res.skip_reason = "OPENAI_API_KEY not set"
            return res
        t0 = time.time()
        vecs: list[list[float]] = []
        BATCH = 100
        for i in range(0, len(corpus_texts), BATCH):
            vecs.extend(openai_embed(corpus_texts[i : i + BATCH], model_name, key))
        res.corpus_encode_seconds = time.time() - t0
        res.dim = len(vecs[0]) if vecs else 0

        def encode_query(q: str) -> list[float]:
            return openai_embed([q], model_name, key)[0]

    elif spec.startswith("st:"):
        model_name = spec.split(":", 1)[1]
        m = st_load(model_name)
        if m is None:
            res.skipped = True
            res.skip_reason = "pip install sentence-transformers"
            return res
        t0 = time.time()
        vecs = st_embed(m, corpus_texts)
        res.corpus_encode_seconds = time.time() - t0
        res.dim = len(vecs[0]) if vecs else 0
        prefix = BGE_QUERY_PREFIX if "bge" in model_name.lower() else ""

        def encode_query(q: str) -> list[float]:
            return st_embed(m, [q], prompt_prefix=prefix)[0]

    else:
        res.skipped = True
        res.skip_reason = f"unknown spec: {spec}"
        return res

    id_to_idx = {mid: i for i, mid in enumerate(corpus_ids)}
    q_times: list[float] = []
    for p in pairs:
        qt0 = time.time()
        qv = encode_query(p["query"])
        ranking = rank_corpus(qv, vecs)
        q_times.append(time.time() - qt0)

        target_idx = id_to_idx.get(p["target_id"], -1)
        target_rank = 0
        target_score = 0.0
        if target_idx >= 0:
            for r, (idx, score) in enumerate(ranking, start=1):
                if idx == target_idx:
                    target_rank = r
                    target_score = score
                    break

        top1_idx, top1_score = ranking[0]
        res.per_pair.append(PerPair(
            pair_id=p["pair_id"],
            query=p["query"],
            target_id=p["target_id"],
            target_text=p["target_text"],
            difficulty=p["difficulty"],
            query_style=p["query_style"],
            target_rank=target_rank,
            target_score=target_score,
            top1_id=corpus_ids[top1_idx],
            top1_text=corpus_texts[top1_idx],
            top1_score=top1_score,
        ))

    res.avg_query_seconds = sum(q_times) / len(q_times) if q_times else 0.0

    # aggregate
    ranks = [pp.target_rank for pp in res.per_pair if pp.target_rank > 0]
    n = len(res.per_pair)
    if ranks:
        res.mrr = sum(1.0 / r for r in ranks) / n
        res.recall_at_1 = sum(1 for r in ranks if r <= 1) / n
        res.recall_at_5 = sum(1 for r in ranks if r <= 5) / n
        res.recall_at_10 = sum(1 for r in ranks if r <= 10) / n
    return res


# --------------------------------------------------------------------------
# printing

def _snippet(s: str, n: int = 80) -> str:
    return s.replace("\n", " ").replace("\r", " ")[:n]


def print_per_pair(results: list[ModelResult], pairs: list[dict]) -> None:
    live = [r for r in results if not r.skipped]
    if not live:
        return
    n_pairs = len(live[0].per_pair)
    for i in range(n_pairs):
        any_pp = live[0].per_pair[i]
        print()
        print("=" * 92)
        print(f"{any_pp.pair_id}  [{any_pp.difficulty}/{any_pp.query_style}]  q: {any_pp.query}")
        print(f"target: {_snippet(any_pp.target_text, 110)}")
        print("-" * 92)
        for r in live:
            pp = r.per_pair[i]
            rank_disp = f"#{pp.target_rank}" if pp.target_rank > 0 else "MISS"
            print(f"  {r.model_id:<48} rank={rank_disp:<6} score={pp.target_score:.3f}")
            if pp.target_rank != 1:
                print(f"    rank-1 instead: {_snippet(pp.top1_text, 78)}  ({pp.top1_score:.3f})")


def _per_tier_summary(r: ModelResult) -> dict[str, dict[str, float]]:
    by_tier: dict[str, list[PerPair]] = {}
    for pp in r.per_pair:
        by_tier.setdefault(pp.difficulty, []).append(pp)
    out: dict[str, dict[str, float]] = {}
    for tier, pps in by_tier.items():
        ranks = [pp.target_rank for pp in pps if pp.target_rank > 0]
        n = len(pps)
        out[tier] = {
            "n": n,
            "mrr": sum(1.0 / r for r in ranks) / n if n else 0.0,
            "r@1": sum(1 for r in ranks if r <= 1) / n if n else 0.0,
            "r@5": sum(1 for r in ranks if r <= 5) / n if n else 0.0,
            "r@10": sum(1 for r in ranks if r <= 10) / n if n else 0.0,
        }
    return out


def print_summary(results: list[ModelResult], corpus_size: int, n_pairs: int) -> None:
    print()
    print("=" * 92)
    print(f"OVERALL  (corpus = {corpus_size} messages, queries = {n_pairs})")
    print("=" * 92)
    header = f"{'model':<48} {'dim':>4} {'MRR':>6} {'R@1':>6} {'R@5':>6} {'R@10':>6} {'enc_s':>7} {'q_ms':>7}"
    print(header)
    print("-" * len(header))
    for r in results:
        if r.skipped:
            print(f"{r.model_id:<48} SKIPPED  {r.skip_reason}")
            continue
        print(
            f"{r.model_id:<48} {r.dim:>4} "
            f"{r.mrr:>6.3f} {r.recall_at_1:>6.2f} {r.recall_at_5:>6.2f} "
            f"{r.recall_at_10:>6.2f} {r.corpus_encode_seconds:>7.2f} "
            f"{r.avg_query_seconds * 1000:>7.1f}"
        )

    # per-tier breakdown — the real story
    print()
    print("=" * 92)
    print("PER-TIER MRR / Recall@K")
    print("=" * 92)
    tiers = ["easy", "medium", "hard", "very_hard"]
    for r in results:
        if r.skipped:
            continue
        per_tier = _per_tier_summary(r)
        print(f"\n  {r.model_id}")
        print(f"    {'tier':<12} {'n':>4} {'MRR':>6} {'R@1':>6} {'R@5':>6} {'R@10':>6}")
        for t in tiers:
            row = per_tier.get(t)
            if not row:
                print(f"    {t:<12} {'-':>4}")
                continue
            print(f"    {t:<12} {row['n']:>4} {row['mrr']:>6.3f} {row['r@1']:>6.2f} {row['r@5']:>6.2f} {row['r@10']:>6.2f}")

    print()
    print("MRR  = mean 1/rank; perfect = 1.0; rank 10 → 0.1")
    print("R@K  = fraction of queries where target landed in top K")


# --------------------------------------------------------------------------
# main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-file", default=str(EVAL_FILE))
    ap.add_argument("--strict", action="store_true",
                    help="require human-accepted/edited pairs (excludes pending)")
    ap.add_argument("--distractors", type=int, default=None,
                    help="override corpus_recipe.random_distractor_count")
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS))
    ap.add_argument("--report", default=str(HERE / "last_text_run.json"))
    args = ap.parse_args()

    eval_data, pairs = load_eval(Path(args.eval_file), args.strict)
    ids, texts = build_corpus(eval_data, pairs, args.distractors)

    n_targets = len(pairs)
    n_hardneg = len(set(n["message_id"] for p in pairs for n in p["hard_negatives"]) - {p["target_id"] for p in pairs})
    print(f"eval pairs (after filter):   {len(pairs)}")
    print(f"corpus size:                 {len(ids)}  ({n_targets} targets + {n_hardneg} hard negs + {len(ids) - n_targets - n_hardneg} random)")
    print(f"models:                      {args.models}")
    print()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    results: list[ModelResult] = []
    for spec in models:
        print(f"--- running {spec} ---")
        try:
            r = run_model(spec, ids, texts, pairs)
            results.append(r)
            if r.skipped:
                print(f"  skipped: {r.skip_reason}")
            else:
                print(f"  encoded {len(ids)} in {r.corpus_encode_seconds:.2f}s, MRR={r.mrr:.3f}")
        except Exception as e:
            results.append(ModelResult(model_id=spec, skipped=True, skip_reason=f"crashed: {e}"))
            print(f"  CRASHED: {e}")
        print()

    print_per_pair(results, pairs)
    print_summary(results, len(ids), len(pairs))

    report = {
        "eval_dataset_version": eval_data.get("version"),
        "corpus_size": len(ids),
        "n_targets": n_targets,
        "n_hard_negatives": n_hardneg,
        "n_pairs": len(pairs),
        "strict_filter": args.strict,
        "models": [
            {
                "model_id": r.model_id,
                "skipped": r.skipped,
                "skip_reason": r.skip_reason,
                "dim": r.dim,
                "corpus_encode_seconds": r.corpus_encode_seconds,
                "avg_query_seconds": r.avg_query_seconds,
                "mrr": r.mrr,
                "recall_at_1": r.recall_at_1,
                "recall_at_5": r.recall_at_5,
                "recall_at_10": r.recall_at_10,
                "per_tier": _per_tier_summary(r) if not r.skipped else {},
                "per_pair": [
                    {
                        "pair_id": pp.pair_id,
                        "query": pp.query,
                        "target_id": pp.target_id,
                        "target_text": pp.target_text,
                        "difficulty": pp.difficulty,
                        "query_style": pp.query_style,
                        "target_rank": pp.target_rank,
                        "target_score": pp.target_score,
                        "top1_id": pp.top1_id,
                        "top1_text": pp.top1_text,
                        "top1_score": pp.top1_score,
                    }
                    for pp in r.per_pair
                ],
            }
            for r in results
        ],
    }
    Path(args.report).write_text(_json.dumps(report, indent=2))
    print(f"\nwrote {args.report}")


if __name__ == "__main__":
    main()
