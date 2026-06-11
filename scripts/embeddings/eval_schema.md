# `eval_dataset.json` schema (v2)

Single JSON document, hand-editable, produced by `build_eval.py` and reviewed via `review_cli.py`. The future bench reads it according to the `corpus_recipe` contract — do not change field names without updating the bench.

## Top-level

```jsonc
{
  "version": "2",
  "metadata": { ... },
  "pairs": [ ... ],
  "corpus_recipe": { ... }
}
```

### `metadata`

| field | type | meaning |
| --- | --- | --- |
| `generated_at` | int | unix ts of the build run |
| `generator_model` | string | what model wrote the queries (e.g. `gpt-5.5`) |
| `baseline_negative_miner` | string | the embedder used to choose hard negatives, prefixed with vendor (`openai:text-embedding-3-small`) |
| `source_db` | string | absolute path to the source corpus |
| `total_pairs` | int | count of `pairs` |
| `stratification_counts` | object | `by_difficulty / by_query_style / by_length_bucket / by_source` |
| `seed` | int | sampling seed; pass the same value to `--seed` to regenerate the same target IDs |
| `hard_negatives_per_pair` | int | K used for mining (0 if `--skip-mining`) |

## `pairs[]`

Each pair is one (query, target_message) retrieval test plus its mined adversarial distractors.

```jsonc
{
  "pair_id": "d-0001",
  "source": "discord",
  "target_id": "<discord message id>",
  "target_text": "<full target message content>",
  "target_metadata": {
    "channel_id": "...",
    "author_id": "...",
    "timestamp": 1700000000,
    "length_chars": 312,
    "length_bucket": "short | medium | long",
    "content_type": "technical | conversational | startup | link"
  },
  "query": "<generated query string>",
  "difficulty": "easy | medium | hard | very_hard",
  "query_style": "paraphrase | synonym | intent | degraded",
  "generator": "gpt-5.5 | edited | human",
  "reviewer_decision": "pending | accepted | edited | rejected",
  "reviewer_notes": "",
  "vocabulary_overlap": 0.18,
  "hard_negatives": [
    {
      "message_id": "...",
      "text_preview": "<first 80 chars of content>",
      "baseline_score": 0.71
    }
  ]
}
```

### Per-pair fields

| field | type | source | notes |
| --- | --- | --- | --- |
| `pair_id` | string | builder | stable across runs once written; reviewer state is keyed on this |
| `source` | string | builder | `"discord"` today. Schema is future-ready: when iMessage/Mail databases have data, add pairs with `"imessage"` / `"mail"` and a matching `target_id` namespace. |
| `target_id` | string | source DB | for Discord this is `messages.id`; the bench joins on this to fetch text at corpus-build time |
| `target_text` | string | source DB | denormalised at build time so the dataset is self-contained — the bench does not need the source DB to be readable, only the corpus DB |
| `target_metadata` | object | source DB | denormalised metadata for stratification analysis and CLI display |
| `query` | string | LLM | the query that must retrieve `target_id` |
| `difficulty` | enum | builder | controls validation strictness — see `OVERLAP_THRESHOLDS` in `build_eval.py` |
| `query_style` | enum | builder | locked 1:1 with `difficulty` in v2 — `easy↔paraphrase`, `medium↔synonym`, `hard↔intent`, `very_hard↔degraded` |
| `generator` | enum | builder / CLI | `gpt-5.5` if LLM, `edited` if `review_cli.py e` was used, `human` for hand-added |
| `reviewer_decision` | enum | CLI | `pending` until reviewed; the bench will respect this — `rejected` pairs are excluded |
| `reviewer_notes` | string | CLI | free-form, used when rejecting to record why |
| `vocabulary_overlap` | float | builder / CLI | 3-gram jaccard between `query` and `target_text` after stemming. Recomputed by `review_cli.py` when the query is edited. |
| `hard_negatives` | array | builder | top-K confusable distractors mined by `text-embedding-3-small`. Order is descending by `baseline_score` (cosine). |

## `corpus_recipe`

A CONTRACT the bench reads. The bench must construct its retrieval corpus from these three pieces — nothing else.

```jsonc
{
  "description": "Bench corpus = all pair.target_id + union of pair.hard_negatives + random_distractor_count random distractors (excluding any target or hard-negative id).",
  "mandatory_targets": ["<every pair.target_id>"],
  "mandatory_hard_negatives": ["<union of message_ids from pair.hard_negatives>"],
  "random_distractor_count": 1500,
  "random_distractor_seed": 42,
  "min_distractor_chars": 20
}
```

The point of this contract is: **hard negatives are not optional distractors**. If the bench could randomly sample a corpus that omitted the adversarial messages, an easy corpus would let a bad model look good. With this recipe, every model must rank against the same adversarial corpus.

## Adding pairs from a different source (future)

When `imessage_index.db` or `mail_index.db` have data, add pairs with the same shape but a different `source`:

```jsonc
{
  "pair_id": "m-0001",            // m- prefix for iMessage, mail-0001 for mail, etc.
  "source": "imessage",
  "target_id": "<imessage row id>",
  "target_text": "<message body>",
  "target_metadata": {
    "channel_id": "<thread guid>", // borrow the field name; semantics are per-source
    "author_id": "<sender handle>",
    "timestamp": 1700000000,
    "length_chars": 187,
    "length_bucket": "medium",
    "content_type": "conversational"
  },
  "query": "...",
  // remaining fields identical to Discord pairs
}
```

The bench must learn to load the right source DB per pair when fetching corpus text. That's a v3 concern — v2 supports the field but only Discord today.

## Reading and writing the file

- **Atomic writes only.** Both `build_eval.py` and `review_cli.py` write via `_common.atomic_write_json` (temp file + rename). Ctrl-C never leaves a half-written JSON on disk.
- **Hand-editing.** Open in any editor. The reviewer can edit a query directly, then re-run `review_cli.py --stats` to recompute overlap stats.
- **Idempotency.** Re-running `build_eval.py` after a partial failure preserves any `pair_id` already written — the orchestrator never overwrites existing pairs (TODO when implementing the resume path; today re-runs start fresh).

## Verification gates

Run automatically by `build_eval.py` at end-of-run, and via `review_cli.py --stats / --spot-check`. The plan defines five gates; the dataset is "proper" when all five pass:

1. Vocabulary-overlap monotonicity across tiers
2. Stratification coverage + channel cap
3. Human spot-check on accepted pairs
4. Hard-negative topical sanity
5. Cheap MRR sanity using `bge-small` (runs after the bench plan ships)
