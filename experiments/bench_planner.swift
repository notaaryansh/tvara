// Latency + accuracy benchmark for the action-planner endpoint.
//
// Calls OpenAI's chat/completions with the exact same prompt shape
// SmartSearchService.planAction uses (same model, same system prompt,
// same JSON-object response format), and — when built against the
// macOS 26 SDK with Apple Intelligence enabled — also calls the
// on-device FoundationModels SystemLanguageModel with the same
// system prompt / user message. Reports per-call latency and
// JSON-shape accuracy on the same sample set.
//
// Usage:
//   swift experiments/bench_planner.swift
//
// Loads the API key the same way the app does (project root .env, then
// ~/Library/Application Support/tvara/.env). The key value is
// never printed.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ─── Config (kept in sync with SmartSearchService) ───────────────────
let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
let model = "gpt-5.5"
let reasoningEffort = "low"

let systemPrompt = """
You convert a user's free-form action intent into a structured JSON
plan. Two action types are supported. Respond ONLY with one JSON
object — no other text. The first field is always "type", which is
either "message" or "event".

─── Type "message" ─────────────────────────────
{
  "type": "message",
  "platform": "whatsapp" | "imessage" | "discord" | "mail",
  "recipient": "<contact name as written by the user, no titles>",
  "content": "<the message body to pre-populate the compose box>"
}

─── Type "event" ───────────────────────────────
{
  "type": "event",
  "title": "<short event title>",
  "start_date": "<ISO 8601 absolute datetime with tz>",
  "duration_minutes": <int, default 60>,
  "attendees": ["name1", "name2"],
  "location": "<optional location string, or empty>",
  "notes": "<optional context for the description, or empty>"
}

Picking the type:
- "send/text/email/message/dm/whatsapp/imessage" → message
- "meeting/event/calendar/invite/schedule/book" → event
- When ambiguous, prefer message.
"""

// ─── Sample inputs ───────────────────────────────────────────────────
struct Sample {
    let label: String
    let intent: String
    let source: String
    let expectedType: String   // "message" or "event"
}

let samples: [Sample] = [
    Sample(
        label: "msg-short",
        intent: "send drishtu a message about this on whatsapp",
        source: "Heading out, will be back by 6.",
        expectedType: "message"
    ),
    Sample(
        label: "msg-summarize",
        intent: "summarize this and send to mike on imessage",
        source: """
        Hey, just wanted to flag — the migration we discussed for the
        billing service is going to land Friday instead of Thursday.
        The QA team found a regression on the invoice PDF rendering when
        we batched the writes, and we want to ship a fix before the
        cutover. Same downtime window, just shifted one day.
        """,
        expectedType: "message"
    ),
    Sample(
        label: "evt-simple",
        intent: "schedule a meeting with mike tomorrow at 3pm about this",
        source: "Quarterly product roadmap review.",
        expectedType: "event"
    ),
    Sample(
        label: "evt-with-attendees",
        intent: "set up a 30 minute call with aum and drishtu next monday at 11am",
        source: "Spotlight++ launcher v1 design review — discuss the expanded mode.",
        expectedType: "event"
    ),
    Sample(
        label: "msg-long-source",
        intent: "draft a reply on email",
        source: """
        Hi team,

        Following up on the budget allocations we discussed. I went
        through the Q3 numbers and adjusted our infrastructure line item
        down by 12%. The bigger savings came from negotiating the
        Postgres instance class — we don't need r6g.4xlarge for the
        read replicas; r6g.2xlarge handles current load with 40% margin.

        Let me know if you'd like to walk through the full breakdown.

        Best,
        Sarah
        """,
        expectedType: "message"
    ),
]

func userMessage(for sample: Sample) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let nowISO = iso.string(from: Date())
    return """
    Current time: \(nowISO)

    Selected content:
    \(sample.source)

    Action intent:
    \(sample.intent)
    """
}

// ─── Accuracy scoring ────────────────────────────────────────────────
// Returns (typeOk, shapeOk). typeOk = "type" field matched expected.
// shapeOk = required fields for that type were all present and non-empty.
func score(jsonText: String, expected: String) -> (typeOk: Bool, shapeOk: Bool) {
    // Some models wrap JSON in ```json fences — strip them.
    var trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
        if let firstNL = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNL)...])
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, false) }
    guard let t = obj["type"] as? String else { return (false, false) }
    let typeOk = (t == expected)
    var shapeOk = false
    if t == "message" {
        let platform = (obj["platform"] as? String) ?? ""
        let recipient = (obj["recipient"] as? String) ?? ""
        let content = (obj["content"] as? String) ?? ""
        let validPlatforms: Set<String> = ["whatsapp", "imessage", "discord", "mail"]
        shapeOk = validPlatforms.contains(platform) && !recipient.isEmpty && !content.isEmpty
    } else if t == "event" {
        let title = (obj["title"] as? String) ?? ""
        let start = (obj["start_date"] as? String) ?? ""
        shapeOk = !title.isEmpty && !start.isEmpty
    }
    return (typeOk, shapeOk)
}

// ─── Key loading (mirrors SmartSearchService.loadKey) ────────────────
func loadKey() -> String? {
    if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
       !env.isEmpty { return env }
    let home = NSHomeDirectory()
    let candidates = [
        FileManager.default.currentDirectoryPath + "/.env",
        home + "/Library/Application Support/tvara/.env",
        home + "/Library/Application Support/tvara/openai_key.txt",
        home + "/.env",
    ]
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { continue }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("OPENAI_API_KEY=") {
                let v = String(trimmed.dropFirst("OPENAI_API_KEY=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !v.isEmpty { return v }
            }
            if trimmed.hasPrefix("sk-") { return trimmed }
        }
    }
    return nil
}

// ─── OpenAI plan call ────────────────────────────────────────────────
struct CallResult {
    let latencyMs: Double
    let bytes: Int
    let text: String
}

func planOpenAI(sample: Sample, key: String) async throws -> CallResult {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    let body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage(for: sample)],
        ],
        "response_format": ["type": "json_object"],
        "reasoning_effort": reasoningEffort,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let t0 = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    let elapsed = Date().timeIntervalSince(t0) * 1000

    let http = response as? HTTPURLResponse
    guard let code = http?.statusCode, code == 200 else {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "bench", code: http?.statusCode ?? -1,
                      userInfo: [NSLocalizedDescriptionKey: bodyStr.prefix(200).description])
    }
    // Pull the assistant content out of the chat-completions envelope.
    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = payload?["choices"] as? [[String: Any]] ?? []
    let message = (choices.first?["message"] as? [String: Any]) ?? [:]
    let text = (message["content"] as? String) ?? ""
    return CallResult(latencyMs: elapsed, bytes: data.count, text: text)
}

// ─── FoundationModels plan call (on-device) ──────────────────────────
#if canImport(FoundationModels)
@available(macOS 26.0, *)
func planFM(sample: Sample) async throws -> CallResult {
    let session = LanguageModelSession(instructions: { systemPrompt })
    let prompt = userMessage(for: sample)
    let t0 = Date()
    let response = try await session.respond(to: prompt)
    let elapsed = Date().timeIntervalSince(t0) * 1000
    let text = response.content
    return CallResult(latencyMs: elapsed, bytes: text.utf8.count, text: text)
}
#endif

// ─── Summary helpers ─────────────────────────────────────────────────
struct BackendStats {
    var name: String
    var latencies: [Double] = []
    var typeHits = 0
    var shapeHits = 0
    var attempted = 0
    var failures = 0
}

func printSummary(_ s: BackendStats) {
    guard !s.latencies.isEmpty else {
        print("  [\(s.name)] no successful runs")
        return
    }
    let sorted = s.latencies.sorted()
    let avg = sorted.reduce(0, +) / Double(sorted.count)
    let p50 = sorted[sorted.count / 2]
    let p95Idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
    let p95 = sorted[p95Idx]
    let typeAcc = Double(s.typeHits) / Double(s.attempted) * 100
    let shapeAcc = Double(s.shapeHits) / Double(s.attempted) * 100
    print(String(format: "  [%@] n=%d  avg %.0f ms  p50 %.0f ms  p95 %.0f ms",
                 s.name, sorted.count, avg, p50, p95))
    print(String(format: "         type-accuracy %.0f%% (%d/%d)  shape-accuracy %.0f%% (%d/%d)  failures %d",
                 typeAcc, s.typeHits, s.attempted,
                 shapeAcc, s.shapeHits, s.attempted,
                 s.failures))
}

// ─── Run ─────────────────────────────────────────────────────────────
let semaphore = DispatchSemaphore(value: 0)
Task {
    let runsPerSample = 3

    // ── OpenAI backend ────────────────────────────────────────────
    var openai = BackendStats(name: "openai/\(model)")
    if let key = loadKey() {
        print("→ openai: loaded key (len=\(key.count))   model=\(model)   reasoning=\(reasoningEffort)")
        for sample in samples {
            var runs: [Double] = []
            for run in 1...runsPerSample {
                openai.attempted += 1
                do {
                    let r = try await planOpenAI(sample: sample, key: key)
                    runs.append(r.latencyMs)
                    let (typeOk, shapeOk) = score(jsonText: r.text, expected: sample.expectedType)
                    if typeOk { openai.typeHits += 1 }
                    if shapeOk { openai.shapeHits += 1 }
                    let tick = (typeOk && shapeOk) ? "✓" : (typeOk ? "~" : "✗")
                    print(String(format: "  [openai/%@] run %d: %.0f ms %@",
                                 sample.label, run, r.latencyMs, tick))
                } catch {
                    openai.failures += 1
                    print("  [openai/\(sample.label)] run \(run): FAILED — \(error.localizedDescription)")
                }
            }
            openai.latencies.append(contentsOf: runs)
            if !runs.isEmpty {
                let avg = runs.reduce(0, +) / Double(runs.count)
                print(String(format: "  [openai/%@] avg %.0f ms (min %.0f, max %.0f)\n",
                             sample.label, avg, runs.min()!, runs.max()!))
            }
        }
    } else {
        print("✗ openai: no key found in env or .env files — skipping OpenAI backend\n")
    }

    // ── FoundationModels backend (on-device) ──────────────────────
    var fm = BackendStats(name: "apple/foundationmodels")
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let avail = SystemLanguageModel.default.availability
        switch avail {
        case .available:
            print("\n→ fm: SystemLanguageModel.available — running on-device bench")
            for sample in samples {
                var runs: [Double] = []
                for run in 1...runsPerSample {
                    fm.attempted += 1
                    do {
                        let r = try await planFM(sample: sample)
                        runs.append(r.latencyMs)
                        let (typeOk, shapeOk) = score(jsonText: r.text, expected: sample.expectedType)
                        if typeOk { fm.typeHits += 1 }
                        if shapeOk { fm.shapeHits += 1 }
                        let tick = (typeOk && shapeOk) ? "✓" : (typeOk ? "~" : "✗")
                        print(String(format: "  [fm/%@] run %d: %.0f ms %@",
                                     sample.label, run, r.latencyMs, tick))
                    } catch {
                        fm.failures += 1
                        print("  [fm/\(sample.label)] run \(run): FAILED — \(error.localizedDescription)")
                    }
                }
                fm.latencies.append(contentsOf: runs)
                if !runs.isEmpty {
                    let avg = runs.reduce(0, +) / Double(runs.count)
                    print(String(format: "  [fm/%@] avg %.0f ms (min %.0f, max %.0f)\n",
                                 sample.label, avg, runs.min()!, runs.max()!))
                }
            }
        case .unavailable(let reason):
            print("\n✗ fm: SystemLanguageModel.unavailable(\(reason)) — skipping FM backend")
        @unknown default:
            print("\n✗ fm: SystemLanguageModel.availability returned unknown case — skipping FM backend")
        }
    } else {
        print("\n✗ fm: needs macOS 26+ at runtime — skipping FM backend")
    }
    #else
    print("\n✗ fm: built without FoundationModels (needs macOS 26 SDK) — skipping FM backend")
    #endif

    // ── Side-by-side summary ──────────────────────────────────────
    print("\n══ SUMMARY ══")
    printSummary(openai)
    printSummary(fm)
    semaphore.signal()
}
semaphore.wait()
