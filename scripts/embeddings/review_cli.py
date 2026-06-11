#!/usr/bin/env python3
"""
Interactive review for scripts/embeddings/eval_dataset.json.

For every pair with reviewer_decision == "pending", show the target message,
the generated query, vocabulary stats, and the top-3 hard negatives. Press a
key to accept, edit, reject, skip, go back, or quit. Every action persists
immediately (atomic write) so Ctrl-C never loses progress.

Modes:
    python3 scripts/embeddings/review_cli.py                 # review pending pairs
    python3 scripts/embeddings/review_cli.py --all           # also re-review accepted ones
    python3 scripts/embeddings/review_cli.py --stats         # print verification stats and exit
    python3 scripts/embeddings/review_cli.py --spot-check 5  # re-show 5 random accepted pairs

Keys:
    a  accept
    e  edit query (opens $EDITOR)
    r  reject
    s  skip for now (stays pending)
    b  back one pair
    q  save and quit
    ?  help
"""
from __future__ import annotations

import argparse
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import HERE, ngram_overlap, unigram_overlap, atomic_write_json  # noqa: E402

import json  # noqa: E402

DATASET = HERE / "eval_dataset.json"


# --------------------------------------------------------------------------
# pretty-print helpers

WRAP_WIDTH = 78


def _wrap(text: str, indent: str = "  ") -> str:
    out = []
    for paragraph in text.replace("\r", "").split("\n"):
        line = ""
        for word in paragraph.split():
            if line and len(line) + 1 + len(word) > WRAP_WIDTH:
                out.append(indent + line)
                line = word
            else:
                line = (line + " " + word).strip()
        if line:
            out.append(indent + line)
    return "\n".join(out)


def _print_pair(idx: int, total: int, p: dict) -> None:
    print()
    print("─" * 80)
    print(f"Pair {p['pair_id']}  ({idx + 1}/{total})  tier={p['difficulty']}  style={p['query_style']}")
    print(f"channel={p['target_metadata']['channel_id']}  length={p['target_metadata']['length_chars']}  type={p['target_metadata']['content_type']}")
    print("─" * 80)
    print("\nTARGET:")
    print(_wrap(p["target_text"]))
    print("\nGENERATED QUERY:")
    print(_wrap(p["query"]))
    print(f"\nvocab overlap (3-gram jaccard): {p['vocabulary_overlap']:.3f}    unigram jaccard: {unigram_overlap(p['query'], p['target_text']):.3f}")
    if p["hard_negatives"]:
        print("\nTop hard negatives (text-embedding-3-small):")
        for j, neg in enumerate(p["hard_negatives"][:3], start=1):
            print(f"  {j}. ({neg['baseline_score']:.2f})  {neg['text_preview']}")
    if p.get("reviewer_decision") and p["reviewer_decision"] != "pending":
        print(f"\nprior decision: {p['reviewer_decision']}")
        if p.get("reviewer_notes"):
            print(f"notes: {p['reviewer_notes']}")
    print()


def _edit_query(current: str) -> str:
    editor = os.environ.get("EDITOR", "nano")
    with tempfile.NamedTemporaryFile(mode="w+", suffix=".txt", delete=False) as f:
        f.write(current)
        path = f.name
    try:
        subprocess.call([editor, path])
        return Path(path).read_text().strip().splitlines()[0].strip()
    finally:
        os.unlink(path)


def _load() -> dict:
    if not DATASET.exists():
        sys.exit(f"missing {DATASET}\n  run first: python3 scripts/embeddings/build_eval.py")
    return json.loads(DATASET.read_text())


def _save(dataset: dict) -> None:
    atomic_write_json(DATASET, dataset)


# --------------------------------------------------------------------------
# stats mode

def _print_stats(dataset: dict) -> None:
    pairs = dataset["pairs"]
    if not pairs:
        print("no pairs in dataset")
        return

    print(f"total pairs: {len(pairs)}")
    by_decision: dict[str, int] = {}
    for p in pairs:
        by_decision[p["reviewer_decision"]] = by_decision.get(p["reviewer_decision"], 0) + 1
    print("by reviewer decision:")
    for k, v in sorted(by_decision.items()):
        print(f"  {k:<12} {v}")

    print("\nvocab overlap (3-gram jaccard) by tier:")
    by_tier: dict[str, list[float]] = {}
    for p in pairs:
        by_tier.setdefault(p["difficulty"], []).append(p["vocabulary_overlap"])
    for tier, vals in sorted(by_tier.items()):
        if not vals:
            continue
        mean = sum(vals) / len(vals)
        p95 = sorted(vals)[int(len(vals) * 0.95)] if len(vals) > 1 else vals[0]
        print(f"  {tier:<12} n={len(vals)}  mean={mean:.3f}  p95={p95:.3f}")


def _spot_check(dataset: dict, n: int) -> None:
    accepted = [p for p in dataset["pairs"] if p["reviewer_decision"] == "accepted"]
    if not accepted:
        print("no accepted pairs to spot-check yet")
        return
    sample = random.sample(accepted, min(n, len(accepted)))
    print(f"spot-checking {len(sample)} accepted pairs.")
    print("for each: 'could a real user find the target with this query AND")
    print("not confuse it with the top-3 hard negatives?'  y/n\n")
    yes = no = 0
    for p in sample:
        _print_pair(0, len(sample), p)
        ans = input("[y]es / [n]o: ").strip().lower()
        if ans == "y":
            yes += 1
        else:
            no += 1
    print(f"\nspot-check result: {yes} fair, {no} unfair  ({yes}/{len(sample)})")
    if no > len(sample) // 5:
        print("WARN: more than 1 in 5 pairs failed the human spot-check; generator/judge contract may be broken")


# --------------------------------------------------------------------------
# main review loop

HELP_TEXT = """
keys:
  a  accept this pair
  e  edit the query in $EDITOR
  r  reject (will be excluded from the eval set)
  s  skip — leave pending, come back later
  b  back one pair
  q  save and quit
  ?  show this help
"""


def review_loop(dataset: dict, review_all: bool) -> None:
    pairs = dataset["pairs"]
    pending_idxs = [i for i, p in enumerate(pairs)
                    if review_all or p["reviewer_decision"] == "pending"]

    if not pending_idxs:
        print("nothing to review — every pair has a non-pending decision. use --all to revisit.")
        return

    print(f"reviewing {len(pending_idxs)} pairs ({'all' if review_all else 'pending only'}).")

    cursor = 0
    while 0 <= cursor < len(pending_idxs):
        idx = pending_idxs[cursor]
        p = pairs[idx]
        _print_pair(cursor, len(pending_idxs), p)
        ans = input("[a]ccept [e]dit [r]eject [s]kip [b]ack [q]uit [?]help: ").strip().lower()
        if ans == "?":
            print(HELP_TEXT)
            continue
        elif ans == "a":
            p["reviewer_decision"] = "accepted"
            _save(dataset)
            cursor += 1
        elif ans == "e":
            new_q = _edit_query(p["query"])
            if new_q and new_q != p["query"]:
                p["query"] = new_q
                p["vocabulary_overlap"] = ngram_overlap(new_q, p["target_text"], n=3)
                p["generator"] = "edited"
                p["reviewer_decision"] = "edited"
                _save(dataset)
                print(f"  query updated → overlap now {p['vocabulary_overlap']:.3f}")
            cursor += 1
        elif ans == "r":
            p["reviewer_decision"] = "rejected"
            note = input("  reason (optional, enter to skip): ").strip()
            if note:
                p["reviewer_notes"] = note
            _save(dataset)
            cursor += 1
        elif ans == "s":
            cursor += 1
        elif ans == "b":
            cursor = max(0, cursor - 1)
        elif ans == "q":
            print("saved. bye.")
            return
        else:
            print(f"unknown key {ans!r} — type ? for help")

    print("\nall reviewed. saving and exiting.")
    _save(dataset)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true",
                    help="re-review every pair, not just pending ones")
    ap.add_argument("--stats", action="store_true",
                    help="print verification stats and exit")
    ap.add_argument("--spot-check", type=int, default=0, metavar="N",
                    help="re-show N random accepted pairs for a fairness sanity check")
    args = ap.parse_args()

    dataset = _load()
    if args.stats:
        _print_stats(dataset)
        return
    if args.spot_check > 0:
        _spot_check(dataset, args.spot_check)
        return
    review_loop(dataset, review_all=args.all)


if __name__ == "__main__":
    main()
