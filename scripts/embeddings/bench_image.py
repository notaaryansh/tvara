#!/usr/bin/env python3
"""
Benchmark text-to-image search on REAL indexed photos using tvara's existing
MobileCLIP-S2 embeddings (already L2-normalised float32 in images.db).

Source corpus: ~/Library/Application Support/tvara/images.db (images.embedding)
Queries:       scripts/embeddings/queries.json (image_queries)

For each query we:
  1. Embed the query text with MobileCLIP-S2's text encoder.
  2. Cosine-rank against all stored image embeddings.
  3. Print the top-K image paths.
  4. Dump a JSON report.

MobileCLIP-S2 is the right call for image search — it's already local, the
image and text encoders share an embedding space, and Apple ships them as
CoreML. The question this bench answers is "how good is the current model
on real-world queries against my actual screenshots/photos?" — i.e. a
quality sanity check, not a model shootout.

If you ever want to compare against another vision-language model (SigLIP,
OpenCLIP variants, Apple's newer models): the corpus needs re-embedding with
that model's image encoder. This script ranks against whatever vectors are
already in images.db; swapping models means rebuilding the index.

The text encoder is invoked via the existing imagesearch/clip_search binary
(which knows how to tokenize + run the CoreML text model). Build it once:

    cd imagesearch
    swiftc -O clip_search.swift -o clip_search

If clip_search isn't built or the model files are missing, the script falls
back to running the text encoder through python+coremltools, but that path
needs a separate `pip install coremltools transformers torch`.

Usage:
    python3 scripts/embeddings/bench_image.py
    python3 scripts/embeddings/bench_image.py --limit 1000 --topk 5
    python3 scripts/embeddings/bench_image.py --queries-file my_image_queries.json
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
IMAGES_DB = Path.home() / "Library/Application Support/tvara/images.db"
IMAGESEARCH_DIR = PROJECT_ROOT / "imagesearch"
CLIP_SEARCH_BIN = IMAGESEARCH_DIR / "clip_search"
CLIP_TOKENIZE_PY = IMAGESEARCH_DIR / "clip_tokenize.py"
TEXT_MODEL_DIR = IMAGESEARCH_DIR / "models" / "mobileclip_s2_text.mlmodelc"
EMBED_DIM = 512  # MobileCLIP-S2 output is 512-d


# --------------------------------------------------------------------------
# corpus load

def load_image_corpus(limit: int | None) -> list[tuple[str, list[float]]]:
    if not IMAGES_DB.exists():
        sys.exit(f"images.db missing at {IMAGES_DB}. Run tvara's image indexer first.")
    conn = sqlite3.connect(IMAGES_DB)
    sql = "SELECT path, embedding FROM images WHERE embedding IS NOT NULL"
    if limit:
        sql += f" LIMIT {int(limit)}"
    rows = []
    for path, blob in conn.execute(sql):
        if not blob or len(blob) != EMBED_DIM * 4:
            continue
        vec = list(struct.unpack(f"{EMBED_DIM}f", blob))
        rows.append((path, vec))
    conn.close()
    return rows


def load_queries(path: Path) -> list[str]:
    data = json.loads(path.read_text())
    return data.get("image_queries", [])


# --------------------------------------------------------------------------
# text encoding — try the swift binary first, fall back to python+coreml

def encode_query_via_swift(query: str) -> list[float] | None:
    """Use the existing clip_search binary if available. Returns 512-d unit vector."""
    if not CLIP_SEARCH_BIN.exists():
        return None
    # The current clip_search prints ranked results, not raw vectors. We don't
    # want results — we want the embedding. Easiest portable path: spawn a tiny
    # helper that imports the same CoreML model. Skip swift route for now.
    return None


def encode_query_via_python(query: str):
    """Tokenize via the existing clip_tokenize.py, then run the CoreML text model."""
    if not TEXT_MODEL_DIR.exists():
        sys.exit(f"text model missing at {TEXT_MODEL_DIR} — run scripts/fetch-clip-models.sh first.")
    try:
        import coremltools as ct  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        sys.exit("pip install coremltools numpy  (or use the swift path once supported)")

    tok_out = subprocess.run(
        [sys.executable, str(CLIP_TOKENIZE_PY), query],
        capture_output=True, text=True, check=True,
    )
    token_ids = json.loads(tok_out.stdout)
    token_array = np.asarray([token_ids], dtype="int32")

    model = ct.models.MLModel(str(TEXT_MODEL_DIR))
    # Input name varies per export; introspect spec
    spec = model.get_spec()
    input_name = spec.description.input[0].name
    output_name = spec.description.output[0].name
    out = model.predict({input_name: token_array})
    vec = np.asarray(out[output_name]).flatten().astype("float32")
    vec /= (np.linalg.norm(vec) + 1e-12)
    return vec.tolist()


def encode_query(query: str) -> list[float]:
    v = encode_query_via_swift(query)
    if v is not None:
        return v
    return encode_query_via_python(query)


# --------------------------------------------------------------------------
# cosine rank

def cosine_rank(query_vec, corpus_vecs, top_k):
    try:
        import numpy as np  # type: ignore
        q = np.asarray(query_vec, dtype="float32")
        m = np.asarray(corpus_vecs, dtype="float32")
        sims = m @ (q / (np.linalg.norm(q) + 1e-12))
        idx = sims.argsort()[::-1][:top_k]
        return [(int(i), float(sims[i])) for i in idx]
    except ImportError:
        scored = []
        for i, v in enumerate(corpus_vecs):
            s = sum(a * b for a, b in zip(query_vec, v))
            scored.append((i, s))
        scored.sort(key=lambda x: x[1], reverse=True)
        return scored[:top_k]


# --------------------------------------------------------------------------
# main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None, help="cap corpus size")
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--queries-file", default=str(HERE / "queries.json"))
    ap.add_argument("--report", default=str(HERE / "last_image_run.json"))
    args = ap.parse_args()

    print(f"loading image corpus from {IMAGES_DB.name} ...")
    t0 = time.time()
    corpus = load_image_corpus(args.limit)
    print(f"  {len(corpus)} images loaded in {time.time() - t0:.2f}s")
    paths = [p for p, _ in corpus]
    vecs = [v for _, v in corpus]

    queries = load_queries(Path(args.queries_file))
    print(f"queries: {len(queries)}")
    print()

    per_query: dict[str, list[dict]] = {}
    q_times: list[float] = []
    for q in queries:
        print("-" * 78)
        print(f"QUERY: {q}")
        qt0 = time.time()
        qv = encode_query(q)
        ranked = cosine_rank(qv, vecs, args.topk)
        q_times.append(time.time() - qt0)
        hits = []
        for r, (i, s) in enumerate(ranked):
            print(f"  {r + 1}. ({s:.3f})  {paths[i]}")
            hits.append({"rank": r + 1, "score": s, "path": paths[i]})
        per_query[q] = hits
        print()

    avg_ms = (sum(q_times) / len(q_times) * 1000) if q_times else 0.0
    print("=" * 78)
    print(f"corpus={len(corpus)}  queries={len(queries)}  avg_query_ms={avg_ms:.1f}")
    print("=" * 78)

    Path(args.report).write_text(json.dumps({
        "model": "MobileCLIP-S2 (CoreML, local)",
        "corpus_size": len(corpus),
        "queries": queries,
        "avg_query_seconds": (sum(q_times) / len(q_times)) if q_times else 0.0,
        "per_query": per_query,
    }, indent=2))
    print(f"wrote {args.report}")


if __name__ == "__main__":
    main()
