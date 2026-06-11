# Embedding model benchmark

A retrieval benchmark for picking what replaces OpenAI `text-embedding-3-small`
in tvara's semantic search path.

The question we are answering is **not** "does this embedding capture nice
semantic information?" but rather **"given a query, does the model put the
target message at the top of the ranking when it's buried in a messy corpus?"**
That is the only thing that matters for a launcher.

## TL;DR

```bash
# one-time
pip install sentence-transformers numpy certifi

# 1. build the eval dataset (60 stratified pairs, real Discord messages,
#    LLM-generated queries with overlap rejection, hard-negative mining)
python3 scripts/embeddings/build_eval.py

# 2. review every pair — accept / edit / reject
python3 scripts/embeddings/review_cli.py

# 3. (after the next plan ships) run the bench
python3 scripts/embeddings/bench_text.py
```

Output is a table with MRR / Recall@K per model plus a per-query breakdown
showing where each model ranked the target — and what it ranked at #1
instead when it missed.

## What's in here

| file | purpose |
| --- | --- |
| `build_eval.py` | Sample 60 stratified Discord messages, generate queries via `gpt-5.5` with 3-gram overlap rejection, mine top-20 hard negatives per query via `text-embedding-3-small`, write `eval_dataset.json`. |
| `review_cli.py` | Interactive review: target + query + hard negatives → accept / edit / reject. Atomic writes survive Ctrl-C. |
| `_common.py` | Shared helpers (key loading, TLS, Discord conn, tokenization, n-gram overlap, atomic JSON write). |
| `eval_dataset.json` | The labelled eval set. Generated; hand-editable. See `eval_schema.md`. |
| `eval_schema.md` | Plain-prose schema doc for `eval_dataset.json`. |
| `prompts/few_shot.jsonl` | Per-tier worked examples (incl. one explicit negative example showing the v1 failure mode). Edit to tune the generator without touching code. |
| `cache/` | Cached corpus embeddings (gitignored). Re-runs of `build_eval.py` skip the ~30s OpenAI re-embed when the row count is unchanged. |
| `bench_text.py` | Loads the eval set + a corpus of distractor messages, runs every configured embedding model, records the rank of the target per query, aggregates into MRR / Recall@K. **Note**: today reads the old v1 `ground_truth.json` format; the next plan evolves it to read `eval_dataset.json` and respect `corpus_recipe`. |
| `bench_image.py` | Sanity-check the existing MobileCLIP-S2 text-to-image pipeline against the real `images.db`. Image embeddings are already local, so this is a quality probe, not a model shootout. |
| `queries.json` | Image queries for `bench_image.py`. |
| `archive/` | The v1 attempt — `generate_ground_truth.py`, `ground_truth.json`, `last_text_run.json`. Kept as receipts. |

## Methodology — text

### Why this is harder than it looks

`discord_index.db` has no `reply_to` or `thread_id` columns. There is no
free signal in the schema that says "these two messages belong together,"
so we cannot derive labelled pairs from joins. We have to make them.

**v1 (deprecated, archived):** sample N messages, ask GPT to write a query
for each, done. Failure mode: the LLM keyword-extracted the message ("senior
fullstack smart contract developer" → "senior fullstack smart contract
developer looking for job"). Every embedding model scored MRR = 1.00.
Useless.

**v2 (current):** five mitigations from the literature (BEIR, MS MARCO,
InPars-v2, SyNeg):

1. **Stratified difficulty tiers** — easy / medium / hard / very_hard with
   1:1 query-style lock (paraphrase / synonym / intent / degraded).
2. **3-gram overlap rejection** — strict per-tier jaccard threshold; queries
   that share n-grams with the target are regenerated up to 2× then dropped.
3. **Few-shot prompting with a negative example** — `prompts/few_shot.jsonl`
   includes the v1 failure literally, framed as "do not emit queries like
   this."
4. **Hard-negative mining with the baseline model** — `text-embedding-3-small`
   itself picks the top-20 confusable distractors per query. The bench
   corpus is forced to include them, so no random-sampling luck.
5. **Human review CLI** — every pair is eyeballed; you can edit or reject.

### How `eval_dataset.json` is built

`build_eval.py` does this end-to-end:

1. Pull a candidate pool of substantive messages (`length >= 40`, no
   pure-URL, no pure-mention, deduped).
2. Stratify-assign 60 targets across difficulty / style / length / content
   type, capped at 10% per channel.
3. For each target, call `gpt-5.5` with a per-tier system prompt + few-shot
   examples. Validate the response (3-gram overlap below threshold, word
   count 3–12, no model preamble). Retry up to 2×.
4. Mine top-20 hard negatives per query with `text-embedding-3-small`
   (cached on first run).
5. Atomic write to `eval_dataset.json`. Print the verification report.

Then run `review_cli.py` to walk through pairs and accept / edit / reject.
Expect ~90 minutes for 60 pairs at ~40 pairs/hr.

### How `bench_text.py` measures quality

For each model:

1. Embed a corpus of `--distractors` random messages plus every target
   message (so each target is findable). Default corpus: ~1500 distractors
   + 7 targets ≈ 1507 messages.
2. For each `(query, target_id)` pair:
   - Embed the query.
   - Cosine-rank the corpus.
   - Record at what 1-indexed position `target_id` came back.
3. Aggregate:
   - **MRR** (Mean Reciprocal Rank): `mean(1 / target_rank)` across queries.
     A perfect model scores 1.0; a model that always lands the target at
     rank 10 scores 0.1. This is the single number to compare on.
   - **Recall@K** for K ∈ {1, 5, 10}: fraction of queries where the target
     was inside the top K results. R@1 = "is it the first result?" — what
     users actually feel.

The per-query output also shows **what the model put at rank #1 instead**
when it missed. Eyeball that to see what kind of mistake each model is
making (synonym collapse, prefix match weirdness, etc.).

## Methodology — images

The image path is already local. `images.db` stores 512-dim MobileCLIP-S2
embeddings (L2-normalised float32 BLOBs). `bench_image.py` takes a text
query, runs it through the same CoreML text encoder, cosine-ranks against
all stored image embeddings, and prints top-K paths so you can eyeball.

This is a probe, not a shootout. Comparing vision-language models means
re-encoding every image with the new model's vision encoder — that
belongs in a separate script if/when we want to try SigLIP or OpenCLIP
variants.

The text-encoder invocation currently goes through Python + `coremltools`
(install: `pip install coremltools transformers torch numpy`). A faster
Swift path is possible but not wired up yet — see TODO at the bottom.

## Models compared (text)

| spec | params | dim | size on disk | license | notes |
| --- | --- | --- | --- | --- | --- |
| `openai:text-embedding-3-small` | unknown | 1536 | cloud | proprietary | current production. baseline. |
| `openai:text-embedding-3-large` | unknown | 3072 | cloud | proprietary | cloud quality ceiling. expensive. |
| `st:BAAI/bge-small-en-v1.5` | 33M | 384 | ~130MB | MIT | MTEB ~63. The shipping candidate. |
| `st:sentence-transformers/all-MiniLM-L6-v2` | 22M | 384 | ~90MB | Apache 2.0 | The classic. Slightly worse than BGE. |
| `st:mixedbread-ai/mxbai-embed-large-v1` | 335M | 1024 | ~1.3GB | Apache 2.0 | Top-tier local quality, too heavy to bundle. |

Add or remove via `--models openai:...,st:...`.

### Models NOT measured here (yet)

- **Apple `NLContextualEmbedding`** (built into NaturalLanguage, zero bundle
  cost, Apple-maintained). Only callable from Swift. A Swift probe that
  mirrors `bench_text.py`'s output for direct comparison is a TODO — see
  bottom of this file.
- **MobileCLIP-S2 text encoder reused for text-text search**. You already
  ship this model. It's optimised for image-text matching, not text-text
  similarity, so quality on prose is expected to be worse than BGE — but
  it would cost zero additional bundle bytes. Worth a measurement before
  ruling out.

## How to read the output

The per-query block looks like:

```
==========================================================================================
Q 3: how do i install gstreamer on android
target: !sudo apt-get install -y libgstreamer1.0 gstreamer1.0-plugins-base ...
target_id: 1304165722481623040
------------------------------------------------------------------------------------------
  openai:text-embedding-3-small                  target_rank=#1     score=0.812
  st:BAAI/bge-small-en-v1.5                      target_rank=#1     score=0.741
  st:sentence-transformers/all-MiniLM-L6-v2      target_rank=#3     score=0.612
    rank-1 instead: !pip install pygobject cairo pkg-config  (score=0.658)
```

Then the summary:

```
SUMMARY  (corpus = 1507 messages, queries = 7)
==========================================================================================
model                                            dim    MRR    R@1    R@5   R@10  enc_s   q_ms
------------------------------------------------------------------------------------------
openai:text-embedding-3-small                   1536  0.857   0.71   1.00   1.00   18.4   42.1
st:BAAI/bge-small-en-v1.5                        384  0.786   0.57   1.00   1.00    2.1   11.3
st:sentence-transformers/all-MiniLM-L6-v2        384  0.619   0.43   0.86   1.00    1.6    8.7
```

(Numbers are illustrative — real ones come out of `bench_text.py` runs.)

What to look for:
- **MRR within 0.1 of OpenAI**: good enough to ship the local model.
- **R@5 = 1.00 across the board**: any of these is fine for a UI that
  shows 5 results.
- **R@1 gap**: feels biggest to users. If OpenAI hits R@1 = 0.71 and BGE
  hits 0.57, every 6th query feels worse on local. Decide if that's
  acceptable.
- **`q_ms` column**: per-query latency. Local should be 10× faster on
  warm cache (no network round-trip).

## Cost / size tradeoffs

| dimension | OpenAI 3-small | BGE-small | MiniLM-L6 |
| --- | --- | --- | --- |
| privacy | query text leaves device | local | local |
| bundle size | 0 | ~130MB | ~90MB |
| inference latency (warm) | ~100ms incl network | ~10ms on ANE | ~8ms on ANE |
| cost / 1M tokens | $0.02 | $0 | $0 |
| offline | no | yes | yes |
| MTEB avg score (published) | ~62 | ~63 | ~58 |

## Decision matrix

After running the bench, the decision tree is:

- BGE-small's **MRR ≥ OpenAI - 0.05** AND **R@5 = OpenAI's R@5** → ship BGE,
  drop OpenAI for embeddings.
- BGE is worse but **R@5 still ≥ 0.85** → ship BGE as default, expose an
  "high-quality search (cloud)" toggle that falls back to OpenAI for
  users who opt in. Matches the planner's privacy-receipts pattern.
- BGE is meaningfully worse → try `mxbai-embed-large-v1` for the same
  bench. If it wins, decide whether 1.3GB is acceptable on disk. If not,
  fine-tune BGE on tvara's data (later problem).

## Reproducibility / cost

A full bench run with default settings (1500 distractors, 7 queries, 3
models) costs:

- **OpenAI embeddings**: ~75k input tokens (corpus encode + queries) ≈ $0.0015
- **OpenAI ground-truth generation** (one-time): 7 chat calls ≈ $0.002
- **Local models**: first run downloads ~220MB to `~/.cache/huggingface/`
  (BGE + MiniLM). Subsequent runs are zero-cost.

The whole loop completes in roughly 1–2 minutes on Apple Silicon.

## TODO

- **`bench_apple_nl.swift`** — Swift probe that runs Apple's
  `NLContextualEmbedding` over the same `ground_truth.json` and emits a
  JSON report in the same shape so it can be diffed against the Python
  output. Right now the Apple option is undocumented quality-wise; without
  this we can't justify or rule it out.
- **CoreML conversion of the winning model**. After picking, run
  `coremltools` to convert the HF checkpoint to `.mlpackage` and bundle
  alongside the existing MobileCLIP models in `imagesearch/models/` (or
  a sibling `Resources/embeddings/`).
- **Swift wrapper that mirrors `embed_messages.py`** — once the local
  model is bundled, the bulk embed path should be Swift, not Python.
- **Replace the OpenAI embedding call in `EmbeddingStore.swift`** with
  the local model. This is the actual ship.
- **Faster image text-encode path** — wire `bench_image.py` to call the
  existing CoreML text model directly via Swift, not Python + coremltools.

## Where the data lives

- Source corpus: `~/Library/Application Support/tvara/discord_index.db` (9k+ messages)
- Image corpus: `~/Library/Application Support/tvara/images.db` (7k+ images, 512-d MobileCLIP embeddings)
- Ground truth: `scripts/embeddings/ground_truth.json` (regenerable)
- Reports: `scripts/embeddings/last_*_run.json` (overwritten each run)
- HF model cache: `~/.cache/huggingface/` (BGE / MiniLM downloads)
