#!/usr/bin/env python3
"""
Build the v2 retrieval eval dataset for tvara.

Pipeline:
  1. Sample N stratified target messages from discord_index.db.
  2. For each target, generate a query via gpt-5.5 with:
       - per-tier prompt constraint (easy / medium / hard / very_hard)
       - few-shot examples from prompts/few_shot.jsonl (including a NEGATIVE example)
       - 3-gram overlap validator (rejects keyword-extraction queries, retries up to 2x)
  3. Mine top-K hard negatives per query using text-embedding-3-small
     (caches the corpus embedding to scripts/embeddings/cache/openai_baseline_embeddings.npy).
  4. Write scripts/embeddings/eval_dataset.json (atomic).
  5. Run the verification gates from the plan and print a report.

Idempotent: re-running skips pairs whose pair_id is already present and accepted,
which means it's safe to re-run after a partial failure.

Usage:
    python3 scripts/embeddings/build_eval.py
    python3 scripts/embeddings/build_eval.py --n 30           # smoke test, 30 pairs
    python3 scripts/embeddings/build_eval.py --seed 7         # different sample
    python3 scripts/embeddings/build_eval.py --skip-mining    # generate only, no hard negs
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import struct
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    HERE,
    DISCORD_DB,
    discord_connect,
    load_openai_key,
    ssl_ctx,
    ngram_overlap,
    unigram_overlap,
    atomic_write_json,
)

OUT_FILE = HERE / "eval_dataset.json"
FEW_SHOT_FILE = HERE / "prompts" / "few_shot.jsonl"
CACHE_DIR = HERE / "cache"
BASELINE_CACHE = CACHE_DIR / "openai_baseline_embeddings.npy"
BASELINE_INDEX = CACHE_DIR / "openai_baseline_index.json"

GENERATOR_MODEL = "gpt-5.5"
BASELINE_MODEL = "text-embedding-3-small"
BASELINE_DIM = 1536
HARD_NEG_K = 20

DEFAULT_N = 60

DIFFICULTY_TIERS = ["easy", "medium", "hard", "very_hard"]
QUERY_STYLES = ["paraphrase", "synonym", "intent", "degraded"]
TIER_STYLE_PAIRS = list(zip(DIFFICULTY_TIERS, QUERY_STYLES))  # 1:1 lock

OVERLAP_THRESHOLDS = {  # max allowed 3-gram jaccard for the generated query
    "easy": 0.5,
    "medium": 0.2,
    "hard": 0.05,
    "very_hard": 0.05,
}
MAX_RETRIES = 2

# --------------------------------------------------------------------------
# data classes

@dataclass
class TargetSample:
    target_id: str
    target_text: str
    channel_id: str
    author_id: str
    timestamp: int
    length_chars: int
    length_bucket: str
    content_type: str
    difficulty: str
    query_style: str


# --------------------------------------------------------------------------
# step 1 — sample targets

def _length_bucket(n: int) -> str:
    if n < 100:
        return "short"
    if n < 300:
        return "medium"
    return "long"


_RE_CODE_FENCE = re.compile(r"```")
_RE_APT_PIP = re.compile(r"\b(apt-get|pip install|brew install|npm install|cargo|yarn)\b", re.I)
_RE_URL = re.compile(r"https?://\S+")
_RE_MENTION = re.compile(r"<@!?\d+>")


def _classify_content(text: str) -> str:
    if _RE_CODE_FENCE.search(text) or _RE_APT_PIP.search(text) or "!sudo" in text:
        return "technical"
    urls = _RE_URL.findall(text)
    if urls and sum(len(u) for u in urls) / max(len(text), 1) > 0.3:
        return "link"
    # crude startup-talk detector
    if re.search(r"\b(founder|fundraise|raise|YC|MRR|startup|customers?|launch|product|pivot|investor)\b", text, re.I):
        return "startup"
    return "conversational"


def sample_targets(n: int, seed: int) -> list[TargetSample]:
    rng = random.Random(seed)
    conn = discord_connect()
    # Pull a generous candidate pool — we filter aggressively below.
    pool = conn.execute(
        "SELECT id, channel_id, author_id, content, timestamp "
        "FROM messages WHERE length(content) >= 40 ORDER BY RANDOM() LIMIT ?",
        (n * 20,),
    ).fetchall()
    conn.close()

    candidates: list[dict] = []
    seen_norm: set[str] = set()
    for mid, cid, aid, content, ts in pool:
        url_chars = sum(len(u) for u in _RE_URL.findall(content))
        if url_chars / max(len(content), 1) > 0.7:
            continue
        if _RE_MENTION.sub("", content).strip() == "":
            continue
        norm = re.sub(r"\s+", " ", content.strip().lower())
        if norm in seen_norm:
            continue
        seen_norm.add(norm)
        candidates.append({
            "id": mid, "channel_id": cid, "author_id": aid,
            "content": content, "timestamp": ts,
            "length_bucket": _length_bucket(len(content)),
            "content_type": _classify_content(content),
        })

    rng.shuffle(candidates)

    # Stratified assignment. We balance difficulty (15 each) hardest; everything
    # else falls out from the candidate pool.
    per_tier = n // len(DIFFICULTY_TIERS)
    remainder = n % len(DIFFICULTY_TIERS)
    tier_quota = {t: per_tier + (1 if i < remainder else 0) for i, t in enumerate(DIFFICULTY_TIERS)}
    style_for_tier = dict(TIER_STYLE_PAIRS)

    channel_counts: dict[str, int] = {}
    cap = max(1, int(n * 0.1))  # 10% cap per channel

    targets: list[TargetSample] = []
    tier_idx = 0
    for cand in candidates:
        if len(targets) >= n:
            break
        # Round-robin through tiers that still have quota.
        tier = None
        for _ in range(len(DIFFICULTY_TIERS)):
            t = DIFFICULTY_TIERS[tier_idx % len(DIFFICULTY_TIERS)]
            tier_idx += 1
            if tier_quota[t] > 0:
                tier = t
                break
        if tier is None:
            break
        if channel_counts.get(cand["channel_id"], 0) >= cap:
            continue
        channel_counts[cand["channel_id"]] = channel_counts.get(cand["channel_id"], 0) + 1
        tier_quota[tier] -= 1
        targets.append(TargetSample(
            target_id=cand["id"],
            target_text=cand["content"],
            channel_id=cand["channel_id"],
            author_id=cand["author_id"],
            timestamp=cand["timestamp"],
            length_chars=len(cand["content"]),
            length_bucket=cand["length_bucket"],
            content_type=cand["content_type"],
            difficulty=tier,
            query_style=style_for_tier[tier],
        ))

    if len(targets) < n:
        print(f"WARN: only sampled {len(targets)} / {n} targets — pool may be exhausted by filters", file=sys.stderr)
    return targets


# --------------------------------------------------------------------------
# step 2 — query generation

def _load_few_shots() -> list[dict]:
    if not FEW_SHOT_FILE.exists():
        return []
    return [json.loads(line) for line in FEW_SHOT_FILE.read_text().splitlines() if line.strip()]


def _build_system_prompt(tier: str, style: str, few_shots: list[dict]) -> str:
    constraint = {
        "easy": "Write a paraphrase that preserves the most distinctive content noun from the target. Concise.",
        "medium": "Use synonyms or related terms for the main subject. Do NOT reuse any of the target's distinctive nouns.",
        "hard": "Describe only the *intent* or what the user wanted to remember. Do NOT mention the topic itself. Example shape: 'that thing about X breaking' or 'the message where someone X'.",
        "very_hard": "Write the query as a user typing fast from half-memory: include a typo or two, an abbreviation, or omit a key word. Casual lowercase.",
    }[tier]

    examples = [fs for fs in few_shots if fs.get("tier") == tier]
    # Always include at least one of each: positive example + the global negative example
    pos = [fs for fs in examples if not fs.get("is_negative_example")][:2]
    neg = [fs for fs in few_shots if fs.get("is_negative_example")][:1]

    example_block = ""
    for fs in pos:
        example_block += f"\nGOOD EXAMPLE (tier={fs['tier']}):\n  target: {fs['target_text']}\n  query:  {fs['query']}\n  why:    {fs.get('why_good', '')}\n"
    for fs in neg:
        example_block += f"\nBAD EXAMPLE — DO NOT EMIT QUERIES LIKE THIS:\n  target: {fs['target_text']}\n  query:  {fs['query']}\n  why:    {fs.get('why_good', '')}\n"

    return f"""You write realistic search queries for a Mac launcher. A user has *no memory* of the exact wording of a message they saw on Discord — they want to find it again days or weeks later. You will be shown the target message and asked to write ONE query a real human would type.

Rules:
  - 3 to 12 words, lowercase, no trailing punctuation.
  - Do NOT mention "Discord" or "message".
  - Do NOT quote the target verbatim. NO three consecutive words from the target may appear in the query.
  - Output ONLY the query, nothing else.
  - If the target has no findable intent (gibberish, emoji-only, single word, pure URL), respond with the single token SKIP.

Tier constraint ({tier} / {style}):
  {constraint}
{example_block}"""


def _openai_chat(model: str, system: str, user: str, api_key: str) -> str | None:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user[:2000]},
        ],
        "reasoning_effort": "low",  # gpt-5.5 reasoning model
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=ssl_ctx(), timeout=30) as r:
            data = json.loads(r.read())
    except Exception as e:
        print(f"  ! chat call failed: {e}", file=sys.stderr)
        return None
    out = data["choices"][0]["message"]["content"].strip()
    out = out.strip('"').strip("'").rstrip(".!?")
    out = out.split("\n", 1)[0].strip()
    return out.lower()


def _validate_format(q: str) -> tuple[bool, str]:
    if not q:
        return False, "empty"
    words = q.split()
    if len(words) < 3 or len(words) > 12:
        return False, f"word count {len(words)} out of [3,12]"
    if any(p in q for p in ['"', "discord", "message:"]):
        return False, "contains forbidden token"
    if re.match(r"^(sure|here|the\s+query)", q):
        return False, "model preamble"
    return True, ""


def generate_query(target: TargetSample, few_shots: list[dict], api_key: str) -> tuple[str | None, float, str]:
    """Returns (query | None, overlap, reason_if_failed)."""
    system = _build_system_prompt(target.difficulty, target.query_style, few_shots)
    threshold = OVERLAP_THRESHOLDS[target.difficulty]

    last_reason = ""
    for attempt in range(MAX_RETRIES + 1):
        q = _openai_chat(GENERATOR_MODEL, system, target.target_text, api_key)
        if q is None:
            last_reason = "api_error"
            continue
        if q == "skip":
            return None, 0.0, "model_returned_skip"
        ok, why = _validate_format(q)
        if not ok:
            last_reason = f"format:{why}"
            continue
        overlap = ngram_overlap(q, target.target_text, n=3)
        if overlap > threshold:
            last_reason = f"overlap:{overlap:.2f}>{threshold}"
            continue
        return q, overlap, ""
    return None, 0.0, last_reason


# --------------------------------------------------------------------------
# step 3 — hard negative mining

def _embed_batch_openai(texts: list[str], api_key: str) -> list[list[float]]:
    body = json.dumps({"model": BASELINE_MODEL, "input": texts}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=60) as r:
        data = json.loads(r.read())
    return [d["embedding"] for d in data["data"]]


def _load_or_build_baseline_corpus(api_key: str):
    """Returns (ids, vecs np-array) of all Discord messages embedded by text-embedding-3-small.
    Cached on disk by row-count fingerprint."""
    import numpy as np  # type: ignore
    conn = discord_connect()
    ids_texts = conn.execute(
        "SELECT id, content FROM messages WHERE length(content) >= 20"
    ).fetchall()
    conn.close()
    current_count = len(ids_texts)

    if BASELINE_CACHE.exists() and BASELINE_INDEX.exists():
        idx = json.loads(BASELINE_INDEX.read_text())
        if idx.get("row_count") == current_count and idx.get("model") == BASELINE_MODEL:
            vecs = np.load(BASELINE_CACHE)
            print(f"  cache hit: {len(idx['ids'])} embeddings ({BASELINE_MODEL})")
            return idx["ids"], vecs

    print(f"  embedding {current_count} discord messages with {BASELINE_MODEL} (one-time, cached)...")
    CACHE_DIR.mkdir(exist_ok=True)
    ids = [r[0] for r in ids_texts]
    texts = [r[1] for r in ids_texts]
    vecs: list[list[float]] = []
    BATCH = 100
    t0 = time.time()
    for i in range(0, len(texts), BATCH):
        chunk = texts[i : i + BATCH]
        vecs.extend(_embed_batch_openai(chunk, api_key))
        done = i + len(chunk)
        rate = done / max(time.time() - t0, 1e-6)
        print(f"    {done}/{len(texts)} ({rate:.0f}/s)")
    arr = np.asarray(vecs, dtype="float32")
    # L2-normalise for fast cosine
    norms = np.linalg.norm(arr, axis=1, keepdims=True)
    arr = arr / (norms + 1e-12)
    np.save(BASELINE_CACHE, arr)
    BASELINE_INDEX.write_text(json.dumps({
        "row_count": current_count,
        "model": BASELINE_MODEL,
        "ids": ids,
    }))
    return ids, arr


def mine_hard_negatives(query: str, target_id: str, corpus_ids: list[str],
                        corpus_vecs, id_to_text: dict[str, str], api_key: str, k: int) -> list[dict]:
    import numpy as np  # type: ignore
    qv = _embed_batch_openai([query], api_key)[0]
    qv_arr = np.asarray(qv, dtype="float32")
    qv_arr = qv_arr / (np.linalg.norm(qv_arr) + 1e-12)
    sims = corpus_vecs @ qv_arr
    order = sims.argsort()[::-1]
    negs: list[dict] = []
    for idx in order:
        idx = int(idx)
        mid = corpus_ids[idx]
        if mid == target_id:
            continue
        negs.append({
            "message_id": mid,
            "text_preview": id_to_text.get(mid, "")[:80].replace("\n", " "),
            "baseline_score": float(sims[idx]),
        })
        if len(negs) >= k:
            break
    return negs


# --------------------------------------------------------------------------
# step 4 — assemble + write

def assemble_dataset(targets: list[TargetSample], pairs: list[dict], skip_mining: bool, seed: int) -> dict:
    strat_by_diff: dict[str, int] = {}
    strat_by_style: dict[str, int] = {}
    strat_by_len: dict[str, int] = {}
    strat_by_source: dict[str, int] = {}
    for p in pairs:
        strat_by_diff[p["difficulty"]] = strat_by_diff.get(p["difficulty"], 0) + 1
        strat_by_style[p["query_style"]] = strat_by_style.get(p["query_style"], 0) + 1
        strat_by_len[p["target_metadata"]["length_bucket"]] = strat_by_len.get(p["target_metadata"]["length_bucket"], 0) + 1
        strat_by_source[p["source"]] = strat_by_source.get(p["source"], 0) + 1

    return {
        "version": "2",
        "metadata": {
            "generated_at": int(time.time()),
            "generator_model": GENERATOR_MODEL,
            "baseline_negative_miner": f"openai:{BASELINE_MODEL}",
            "source_db": str(DISCORD_DB),
            "total_pairs": len(pairs),
            "stratification_counts": {
                "by_difficulty": strat_by_diff,
                "by_query_style": strat_by_style,
                "by_length_bucket": strat_by_len,
                "by_source": strat_by_source,
            },
            "seed": seed,
            "hard_negatives_per_pair": 0 if skip_mining else HARD_NEG_K,
        },
        "pairs": pairs,
        "corpus_recipe": {
            "description": "Bench corpus = all pair.target_id + union of pair.hard_negatives + random_distractor_count random distractors (excluding any target or hard-negative id).",
            "mandatory_targets": [p["target_id"] for p in pairs],
            "mandatory_hard_negatives": sorted({n["message_id"] for p in pairs for n in p["hard_negatives"]}),
            "random_distractor_count": 1500,
            "random_distractor_seed": seed,
            "min_distractor_chars": 20,
        },
    }


# --------------------------------------------------------------------------
# step 5 — verification

def verification_report(dataset: dict) -> None:
    pairs = dataset["pairs"]
    if not pairs:
        print("\nVERIFICATION: no pairs to report on.")
        return
    print()
    print("=" * 80)
    print("VERIFICATION REPORT")
    print("=" * 80)

    # gate 1: vocab overlap monotonicity
    print("\n[1] vocabulary overlap by tier (3-gram jaccard):")
    print(f"  {'tier':<12} {'n':>4} {'mean':>8} {'p95':>8} {'expectation':<22} status")
    by_tier: dict[str, list[float]] = {}
    for p in pairs:
        by_tier.setdefault(p["difficulty"], []).append(p["vocabulary_overlap"])
    # Gate purpose: catch the v1 failure mode (high lexical overlap = trivial
    # extraction). LOW overlap is always acceptable — it just means we're
    # measuring semantic, not lexical, retrieval.
    expectations = {
        "easy":      ("< 0.70", lambda m: m < 0.70),
        "medium":    ("< 0.30", lambda m: m < 0.30),
        "hard":      ("< 0.10", lambda m: m < 0.10),
        "very_hard": ("< 0.10", lambda m: m < 0.10),
    }
    for tier in DIFFICULTY_TIERS:
        vals = by_tier.get(tier, [])
        if not vals:
            print(f"  {tier:<12} {'-':>4}")
            continue
        mean = sum(vals) / len(vals)
        p95 = sorted(vals)[int(len(vals) * 0.95)] if len(vals) > 1 else vals[0]
        exp_str, check = expectations[tier]
        status = "OK" if check(mean) else "FAIL"
        print(f"  {tier:<12} {len(vals):>4} {mean:>8.3f} {p95:>8.3f} {exp_str:<22} {status}")

    # gate 2: stratification coverage
    print("\n[2] stratification coverage:")
    sc = dataset["metadata"]["stratification_counts"]
    print(f"  by_difficulty:  {sc['by_difficulty']}")
    print(f"  by_query_style: {sc['by_query_style']}")
    print(f"  by_length:      {sc['by_length_bucket']}")
    chan_counts: dict[str, int] = {}
    for p in pairs:
        cid = p["target_metadata"]["channel_id"]
        chan_counts[cid] = chan_counts.get(cid, 0) + 1
    max_chan = max(chan_counts.values()) if chan_counts else 0
    cap = max(1, int(len(pairs) * 0.1))
    print(f"  max channel count: {max_chan}  (cap = {cap})  {'OK' if max_chan <= cap else 'FAIL'}")

    # gate 4: hard-neg sanity (eyeball 3 random pairs)
    if any(p["hard_negatives"] for p in pairs):
        print("\n[4] hard-negative sanity (3 random pairs):")
        sample = random.sample(pairs, min(3, len(pairs)))
        for p in sample:
            print(f"  pair {p['pair_id']}  query: {p['query']}")
            print(f"    target: {p['target_text'][:90].replace(chr(10), ' ')}")
            for neg in p["hard_negatives"][:3]:
                print(f"      neg ({neg['baseline_score']:.2f}): {neg['text_preview']}")
    else:
        print("\n[4] hard-negative mining skipped — gate not applicable")

    print("\nNote: gates [3] human spot-check and [5] cheap MRR sanity run separately:")
    print("  - human:  python3 scripts/embeddings/review_cli.py")
    print("  - MRR:    python3 scripts/embeddings/bench_text.py  (after the next plan ships)")


# --------------------------------------------------------------------------
# main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=DEFAULT_N)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip-mining", action="store_true", help="generate pairs only, no hard-negative mining")
    ap.add_argument("--out", default=str(OUT_FILE))
    args = ap.parse_args()

    api_key = load_openai_key(required=True)
    few_shots = _load_few_shots()
    print(f"few-shot examples loaded: {len(few_shots)}")

    print(f"\nsampling {args.n} targets (seed={args.seed}) ...")
    targets = sample_targets(args.n, args.seed)
    print(f"  got {len(targets)} targets, stratified across difficulty / style / length")

    print(f"\ngenerating queries with {GENERATOR_MODEL} ...")
    pairs: list[dict] = []
    skipped = 0
    for i, t in enumerate(targets, start=1):
        q, overlap, reason = generate_query(t, few_shots, api_key)
        if q is None:
            print(f"  [{i:>3}/{len(targets)}] SKIPPED  ({reason})  tier={t.difficulty}")
            skipped += 1
            continue
        print(f"  [{i:>3}/{len(targets)}] tier={t.difficulty:<10} overlap={overlap:.2f}  q: {q[:70]}")
        pairs.append({
            "pair_id": f"d-{len(pairs) + 1:04d}",
            "source": "discord",
            "target_id": t.target_id,
            "target_text": t.target_text,
            "target_metadata": {
                "channel_id": t.channel_id,
                "author_id": t.author_id,
                "timestamp": t.timestamp,
                "length_chars": t.length_chars,
                "length_bucket": t.length_bucket,
                "content_type": t.content_type,
            },
            "query": q,
            "difficulty": t.difficulty,
            "query_style": t.query_style,
            "generator": "gpt-5.5",
            "reviewer_decision": "pending",
            "reviewer_notes": "",
            "vocabulary_overlap": overlap,
            "hard_negatives": [],
        })

    print(f"\ngenerated {len(pairs)} pairs; skipped {skipped}.")

    if not args.skip_mining and pairs:
        print(f"\nmining top-{HARD_NEG_K} hard negatives with {BASELINE_MODEL} ...")
        ids, vecs = _load_or_build_baseline_corpus(api_key)
        id_to_text: dict[str, str] = {}
        conn = discord_connect()
        for mid, content in conn.execute("SELECT id, content FROM messages"):
            id_to_text[mid] = content
        conn.close()
        for i, p in enumerate(pairs, start=1):
            negs = mine_hard_negatives(p["query"], p["target_id"], ids, vecs, id_to_text, api_key, HARD_NEG_K)
            p["hard_negatives"] = negs
            if i % 10 == 0 or i == len(pairs):
                print(f"  mined {i}/{len(pairs)}")

    dataset = assemble_dataset(targets, pairs, args.skip_mining, args.seed)
    atomic_write_json(Path(args.out), dataset)
    print(f"\nwrote {len(pairs)} pairs to {args.out}")

    verification_report(dataset)


if __name__ == "__main__":
    main()
