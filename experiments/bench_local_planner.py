#!/usr/bin/env python3
"""
Local-LLM planner benchmark.

Drives Ollama with the real spotlight++ planner system prompt + 5 synthetic
queries that mirror the actual planner workload. Measures latency, JSON
validity, and source-classification accuracy per model.

Usage:
    # 1) pick one or more small models and pull them (one-time, ~2GB each):
    ollama pull llama3.2:3b
    ollama pull qwen2.5:3b
    ollama pull phi3.5:latest
    ollama pull gemma2:2b

    # 2) make sure ollama serve is running (background daemon usually is):
    ollama list

    # 3) run the benchmark:
    python3 experiments/bench_local_planner.py
    # or pick specific models:
    python3 experiments/bench_local_planner.py llama3.2:3b qwen2.5:3b

The script runs each prompt N=3 times per model to get a stable median, and
prints a comparison table at the end.
"""

import json
import statistics
import sys
import time
import urllib.error
import urllib.request

OLLAMA_URL = "http://localhost:11434/api/generate"

DEFAULT_MODELS = [
    "llama3.2:3b",
    "qwen2.5:3b",
    "phi3.5:latest",
    "gemma2:2b",
]

# Lifted verbatim from Sources/spotlight++/Services/SmartSearchService.swift
# so the local model is doing the EXACT same task as the OpenAI planner.
SYSTEM_PROMPT = """You are a query planner for spotlight++, a personal Mac search app. The user types natural-language queries and you decide which of their local data sources to search and what the actual search terms should be.

Available sources:
- "messages": chat messages from WhatsApp, iMessage, Discord
- "mail": email subjects, senders, and bodies
- "browser": pages they have visited (titles + URLs)
- "files": local files and folders by name
- "apps": installed Mac applications
- "clipboard": clipboard copy history
- "any": when the query is too vague to predict

Respond with ONLY a JSON object, no other text:

{
  "source": "<one of the values above>",
  "search_term": "<conceptual phrase used for semantic ranking>",
  "keywords": ["short", "search", "terms"],
  "contact": null OR "<a person's name as a single string>",
  "time_range": "today" OR "week" OR "month" OR "year" OR "any",
  "explanation": "<one sentence explaining what you're searching for>"
}

Rules:
- "search_term": the CONCEPTUAL CORE of what the user is looking for, expanded with 2-5 synonyms or related terms. URLs/links → "https". Emails → "@gmail.com". Phone numbers → "+1 555".
- "keywords": 1-5 short search terms; strip filler words.
- "contact": when the query mentions a person by name, put that name here. Otherwise null.
- "time_range": only when the query mentions a time window; default "any".
- "source": pick the single most likely source. When ambiguous, prefer "any".
"""

# Five synthetic prompts. Each has an expected source + contact so we can
# score classification accuracy. search_term is open-ended so we don't grade
# it strictly — we just check JSON validity + required fields.
TESTS = [
    {
        "name": "single-word contact",
        "query": "babe",
        "expected_source": "messages",
        "expected_contact_present": True,
    },
    {
        "name": "messages with contact + topic",
        "query": "address i sent drish last week",
        "expected_source": "messages",
        "expected_contact_present": True,
    },
    {
        "name": "ambiguous / semantic",
        "query": "beautiful girl with glasses",
        "expected_source": "any",  # files/any both acceptable
        "expected_contact_present": False,
    },
    {
        "name": "mail with time range",
        "query": "the email from chase about my credit card last week",
        "expected_source": "mail",
        "expected_contact_present": False,
    },
    {
        "name": "clipboard recall",
        "query": "did i copy that aws cli command earlier",
        "expected_source": "clipboard",
        "expected_contact_present": False,
    },
]

RUNS_PER_PROMPT = 3
REQUIRED_FIELDS = {"source", "search_term", "keywords", "contact", "time_range", "explanation"}


def list_installed_models() -> set[str]:
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2) as resp:
            data = json.loads(resp.read())
        return {m["name"] for m in data.get("models", [])}
    except Exception as e:
        print(f"[fatal] could not reach Ollama at {OLLAMA_URL}: {e}")
        print("        is `ollama serve` running? try `ollama list` in a terminal.")
        sys.exit(1)


def warm_model(model: str) -> None:
    """One short call so the model loads into memory before we time anything."""
    body = json.dumps({
        "model": model,
        "prompt": "hi",
        "stream": False,
        "options": {"num_predict": 1},
    }).encode()
    req = urllib.request.Request(
        OLLAMA_URL, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            resp.read()
    except Exception as e:
        print(f"   warm-up failed for {model}: {e}")


def call_model(model: str, query: str) -> tuple[float, str]:
    """Returns (wall_seconds, raw_response_text)."""
    body = json.dumps({
        "model": model,
        "system": SYSTEM_PROMPT,
        "prompt": query,
        "format": "json",
        "stream": False,
        "options": {"temperature": 0.0},
    }).encode()
    req = urllib.request.Request(
        OLLAMA_URL, data=body, headers={"Content-Type": "application/json"}
    )
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read())
    elapsed = time.perf_counter() - t0
    return elapsed, payload.get("response", "")


def score(raw: str, test: dict) -> dict:
    """Returns {json_ok, schema_ok, source_match, contact_ok, plan?}."""
    result = {"json_ok": False, "schema_ok": False, "source_match": False, "contact_ok": False, "plan": None}
    try:
        plan = json.loads(raw)
    except json.JSONDecodeError:
        return result
    if not isinstance(plan, dict):
        return result
    result["json_ok"] = True
    result["plan"] = plan
    missing = REQUIRED_FIELDS - set(plan.keys())
    result["schema_ok"] = len(missing) == 0

    src = str(plan.get("source", "")).lower()
    expected = test["expected_source"]
    # Accept "any" as a wildcard match — the planner is allowed to be cautious.
    result["source_match"] = (src == expected) or (expected == "any") or (src == "any" and expected != "any")

    contact = plan.get("contact")
    has_contact = contact not in (None, "", "null")
    result["contact_ok"] = has_contact == test["expected_contact_present"]
    return result


def run_for_model(model: str) -> dict:
    print(f"\n── {model} " + "─" * (60 - len(model)))
    warm_model(model)

    rows = []
    for test in TESTS:
        latencies = []
        scores = []
        last_plan = None
        for _ in range(RUNS_PER_PROMPT):
            try:
                wall, raw = call_model(model, test["query"])
            except Exception as e:
                print(f"  [{test['name']}] error: {e}")
                latencies.append(float("nan"))
                scores.append({"json_ok": False, "schema_ok": False, "source_match": False, "contact_ok": False})
                continue
            s = score(raw, test)
            latencies.append(wall)
            scores.append(s)
            last_plan = s.get("plan")

        med = statistics.median(latencies) if latencies else float("nan")
        json_rate = sum(1 for s in scores if s["json_ok"]) / len(scores)
        schema_rate = sum(1 for s in scores if s["schema_ok"]) / len(scores)
        source_rate = sum(1 for s in scores if s["source_match"]) / len(scores)
        contact_rate = sum(1 for s in scores if s["contact_ok"]) / len(scores)
        rows.append({
            "test": test["name"], "query": test["query"],
            "median_ms": med * 1000,
            "json_ok": json_rate, "schema_ok": schema_rate,
            "source_match": source_rate, "contact_ok": contact_rate,
            "sample_plan": last_plan,
        })
        plan_str = json.dumps(last_plan, separators=(",", ":")) if last_plan else "<no parseable plan>"
        plan_str = plan_str[:90] + ("…" if len(plan_str) > 90 else "")
        print(f"  {test['name']:32}  {med*1000:7.0f} ms   src✓{source_rate*100:.0f}%   {plan_str}")

    return {"model": model, "rows": rows}


def print_summary(results: list[dict]) -> None:
    print("\n\n══════ SUMMARY ══════")
    print(f"{'model':<22}{'median ms':>12}{'p95 ms':>10}{'json':>8}{'src ✓':>8}{'contact ✓':>11}")
    print("-" * 71)
    for r in results:
        all_ms = [row["median_ms"] for row in r["rows"]]
        med = statistics.median(all_ms)
        p95 = sorted(all_ms)[max(0, int(len(all_ms) * 0.95) - 1)]
        json_rate = statistics.mean(row["json_ok"] for row in r["rows"])
        src_rate = statistics.mean(row["source_match"] for row in r["rows"])
        ctc_rate = statistics.mean(row["contact_ok"] for row in r["rows"])
        print(f"{r['model']:<22}{med:>12.0f}{p95:>10.0f}{json_rate*100:>7.0f}%{src_rate*100:>7.0f}%{ctc_rate*100:>10.0f}%")
    print("-" * 71)
    print("median/p95 are across all 5 prompts; rates are means across the same 5.\n")


def main() -> None:
    requested = sys.argv[1:] or DEFAULT_MODELS
    installed = list_installed_models()
    if not installed:
        print("[!] no models installed. pull at least one first:")
        for m in DEFAULT_MODELS:
            print(f"    ollama pull {m}")
        sys.exit(1)

    to_run = [m for m in requested if m in installed]
    skipped = [m for m in requested if m not in installed]
    if skipped:
        print(f"[skip] not installed: {', '.join(skipped)}")
        for m in skipped:
            print(f"       ollama pull {m}")
    if not to_run:
        print("[fatal] none of the requested models are installed.")
        sys.exit(1)

    results = [run_for_model(m) for m in to_run]
    print_summary(results)


if __name__ == "__main__":
    main()
