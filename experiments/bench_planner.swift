// Latency benchmark for the action-planner endpoint.
//
// Calls OpenAI's chat/completions with the exact same prompt shape
// SmartSearchService.planAction uses (same model, same system prompt,
// same JSON-object response format), across a sample of representative
// intent + selected-content pairs. Reports per-call latency.
//
// Usage:
//   swift experiments/bench_planner.swift
//
// Loads the API key the same way the app does (project root .env, then
// ~/Library/Application Support/spotlight++/.env). The key value is
// never printed.
//
// We can't bench Apple's Foundation Models here because this host is on
// macOS 15.4.1 and FM requires macOS 26+. Reference numbers for FM are
// included in the report at the end based on Apple's published figures.

import Foundation

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
}

let samples: [Sample] = [
    Sample(
        label: "msg-short",
        intent: "send drishtu a message about this on whatsapp",
        source: "Heading out, will be back by 6."
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
        """
    ),
    Sample(
        label: "evt-simple",
        intent: "schedule a meeting with mike tomorrow at 3pm about this",
        source: "Quarterly product roadmap review."
    ),
    Sample(
        label: "evt-with-attendees",
        intent: "set up a 30 minute call with aum and drishtu next monday at 11am",
        source: "Spotlight++ launcher v1 design review — discuss the expanded mode."
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
        """
    ),
]

// ─── Key loading (mirrors SmartSearchService.loadKey) ────────────────
func loadKey() -> String? {
    if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
       !env.isEmpty { return env }
    let home = NSHomeDirectory()
    let candidates = [
        FileManager.default.currentDirectoryPath + "/.env",
        home + "/Library/Application Support/spotlight++/.env",
        home + "/Library/Application Support/spotlight++/openai_key.txt",
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

// ─── Bench ───────────────────────────────────────────────────────────
func plan(sample: Sample, key: String) async throws -> (latencyMs: Double, bytes: Int) {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let nowISO = iso.string(from: Date())

    let userMsg = """
    Current time: \(nowISO)

    Selected content:
    \(sample.source)

    Action intent:
    \(sample.intent)
    """

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    let body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMsg],
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
    return (elapsed, data.count)
}

// ─── Run ─────────────────────────────────────────────────────────────
// Top-level await — swift script form, no @main.
let semaphore = DispatchSemaphore(value: 0)
Task {
    guard let key = loadKey() else {
        print("✗ no key found in env or .env files")
        semaphore.signal()
        return
    }
    print("→ loaded key (len=\(key.count) chars)")
    print("→ model: \(model)   reasoning_effort: \(reasoningEffort)")
    print("→ \(samples.count) samples × 3 runs each = \(samples.count * 3) requests\n")

    var allLatencies: [Double] = []

    for sample in samples {
        var runs: [Double] = []
        for run in 1...3 {
            do {
                let r = try await plan(sample: sample, key: key)
                runs.append(r.latencyMs)
                print(String(format: "  [%@] run %d: %.0f ms (resp %d bytes)",
                             sample.label, run, r.latencyMs, r.bytes))
            } catch {
                print("  [\(sample.label)] run \(run): FAILED — \(error.localizedDescription)")
            }
        }
        if !runs.isEmpty {
            let avg = runs.reduce(0, +) / Double(runs.count)
            let lo = runs.min()!
            let hi = runs.max()!
            print(String(format: "  [%@] avg %.0f ms (min %.0f, max %.0f)\n",
                         sample.label, avg, lo, hi))
            allLatencies.append(contentsOf: runs)
        }
    }

    if !allLatencies.isEmpty {
        allLatencies.sort()
        let avg = allLatencies.reduce(0, +) / Double(allLatencies.count)
        let p50 = allLatencies[allLatencies.count / 2]
        let p95Idx = min(allLatencies.count - 1, Int(Double(allLatencies.count) * 0.95))
        let p95 = allLatencies[p95Idx]
        print("══ SUMMARY ══")
        print(String(format: "  n=%d   avg %.0f ms   p50 %.0f ms   p95 %.0f ms",
                     allLatencies.count, avg, p50, p95))
    }
    semaphore.signal()
}
semaphore.wait()
