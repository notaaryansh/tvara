# Search planner bench: OpenAI vs FoundationModels

Goal: can Apple's on-device `FoundationModels` replace OpenAI `gpt-5.5` in
`SmartSearchService.plan()` without paying a multi-second tail on every
natural-language query?

## Setup

- Query: `"beautiful girl with glasses"`
- App: `tvara.app`, library: 7,020 images, 250 ms keystroke debounce
- Measured via `NSLog("SmartSearch: plan() ...")` around the planner call,
  captured by launching with stderr → `/tmp/spotlight-perf.log`
- Cold = first call after app launch; warm = subsequent same query

## Results

| Backend | Prompt | Output | Cold | Warm |
|---|---|---|---|---|
| OpenAI gpt-5.5, reasoning_effort=low | ~2500 tok | JSON text | — | ~3100 ms |
| FoundationModels | ~2500 tok | JSON text | 3962 ms | 2408 ms |
| FoundationModels | ~80 tok | `@Generable` struct | 1713 ms | TBD |

## Takeaways

1. **OpenAI's ~3 s tail is consistent.** Reasoning model + network round-trip;
   little headroom to optimize without leaving the API.
2. **FM with the full OpenAI prompt is *slower*, not faster.** On-device
   prefill is linear in prompt length, and ~2500 tokens of rules + examples
   buries the small model in instructions before it generates a single field.
3. **Slim prompt + `@Generable` cuts cost in half on a cold run.** The model
   fills typed fields with `Guide` annotations carrying semantics — no JSON
   syntax to emit, no parser fallbacks, no markdown-fence cleanup.
4. **Warm-call number is the one that matters.** Apple's docs suggest
   sub-second is achievable once weights are paged in. Open question pending
   real-world warm captures.

## What to try next

- Pre-warm a single `LanguageModelSession` at app launch (in
  `SmartSearchService.warmCache`) so the first user-facing call isn't a cold
  start.
- Reuse one session across calls instead of constructing a new one per query.
- If warm stays above ~500 ms after both: tighten the prompt further, or
  consider a small fine-tuned local GGUF model for this specific task.

## How to reproduce

```bash
./scripts/build-app.sh
pkill -x tvara
: > /tmp/spotlight-perf.log
./tvara.app/Contents/MacOS/tvara > /tmp/spotlight-perf.log 2>&1 &
# type "beautiful girl with glasses" in the launcher; let each search complete
grep "SmartSearch:" /tmp/spotlight-perf.log
```

Log lines:
- `SmartSearch: plan() FM <ms> query=<q>` — on-device served the call
- `SmartSearch: plan() openai <ms> query=<q>` — fallback served (currently
  commented out for FM-only benching; flip back in `SmartSearchService.plan`)
- `SmartSearch: FM failed (<err>)` — FM threw before completing
