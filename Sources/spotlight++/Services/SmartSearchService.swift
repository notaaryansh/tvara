import Foundation

/// LLM-backed query planner. For sentence-like natural-language queries
/// we ask OpenAI to figure out (a) which data source to search, (b) what
/// the actual keywords are once filler words are stripped, (c) whether a
/// person is named, (d) any time bound. The plan then drives our existing
/// per-source services — the LLM never sees user data, only the query.
///
/// API key is read from `~/Library/Application Support/spotlight++/openai_key.txt`.
/// If the file is missing or empty, smart search is disabled and the
/// caller falls back to keyword search.
actor SmartSearchService {
    private var cachedKey: String?
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let model = "gpt-5.5"
    private static let reasoningEffort = "low"   // gpt-5.5 valid values: none/low/medium/high/xhigh

    /// Where we'll look for the OpenAI API key, in order. First non-empty
    /// hit wins. We support several conventions so the user can drop the
    /// key wherever feels natural — project-root .env (their stated
    /// preference), Application Support, plain env var, or home dir.
    private static var keyLookupPaths: [String] {
        let home = NSHomeDirectory()
        return [
            // Project-root .env files (when running from `swift run`):
            FileManager.default.currentDirectoryPath + "/.env",
            // Beside the .app bundle (when running the bundled app from
            // ~/Documents/GitHub/spotlight++/spotlight++.app):
            Bundle.main.bundleURL.deletingLastPathComponent().path + "/.env",
            // Application Support — the macOS-native location:
            home + "/Library/Application Support/spotlight++/.env",
            home + "/Library/Application Support/spotlight++/openai_key.txt",
            // Home dir fallback:
            home + "/.env",
        ]
    }

    init() {
        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
    }

    /// True iff an OpenAI key file exists with non-empty content. Cheap to
    /// call repeatedly — caches after first hit.
    func isAvailable() -> Bool {
        loadKey() != nil
    }

    /// Surface the loaded key so other AI services (EmbeddingStore) can
    /// reuse the same lookup paths instead of duplicating .env scanning.
    func apiKey() -> String? {
        loadKey()
    }

    /// Eagerly resolve the API key at app launch so the first search doesn't
    /// pay scan latency AND so a transient miss (e.g. if the file's still
    /// being written) doesn't sit in the cache as a permanent nil.
    func warmCache() async {
        _ = loadKey()
    }

    /// Returns true if the query is "sentence-like" enough to benefit from
    /// AI planning. Short / keyword queries skip the LLM entirely so we
    /// don't pay latency + cost on every keystroke.
    ///
    /// Heuristic: >5 characters AND ≥4 whitespace-separated words. This
    /// keeps "resume aari 2025" (3 words) on the keyword path, sends
    /// "i sent an airbnb link to drishtu" (8 words) through the planner.
    nonisolated func shouldUseSmartSearch(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 5 else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return words >= 4
    }

    /// Ask the LLM to plan the query. Network + ~1s latency. Throws on
    /// missing key, network error, or unparseable response — callers
    /// should fall back to keyword search on failure.
    func plan(query: String) async throws -> QueryPlan {
        guard let key = loadKey() else { throw SmartSearchError.noAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        // gpt-5.5 is a reasoning model — drop `temperature`, add
        // `reasoning_effort`. We use "low" because "none" trades quality
        // for ~0.8s of latency and we observed it picking wrong sources.
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user",   "content": query]
            ],
            "response_format": ["type": "json_object"],
            "reasoning_effort": Self.reasoningEffort
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SmartSearchError.apiError(body.prefix(200).description)
        }

        let envelope = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let planData = content.data(using: .utf8) else {
            throw SmartSearchError.parseError("no content in response")
        }
        do {
            return try JSONDecoder().decode(QueryPlan.self, from: planData)
        } catch {
            throw SmartSearchError.parseError(
                "JSON decode failed: \(error.localizedDescription); raw: \(content.prefix(200))"
            )
        }
    }

    /// Plan a compose action from a free-form intent + the content the user
    /// was acting on. The planner decides whether to return a message-send
    /// or a calendar-event action. Caller switches on ComposeKind.
    ///
    /// `sourceApp`, when non-nil, tells the planner which app the user
    /// captured the text from (e.g. "Messages", "WhatsApp", "Cursor").
    /// Critical for attribution: a paragraph captured from Messages is
    /// almost certainly a quote from someone else, so summaries should
    /// say "Aum said X" rather than "I X".
    func planAction(intent: String, sourceContent: String, sourceApp: String? = nil) async throws -> ComposeKind {
        guard let key = loadKey() else { throw SmartSearchError.noAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        // Give the model a stable "now" so relative times like "tomorrow"
        // resolve correctly without depending on its training-date drift.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowISO = iso.string(from: Date())

        let userMsg = """
        Current time: \(nowISO)

        Selected content:
        \(sourceContent.prefix(800))

        Action intent:
        \(intent)
        """

        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": Self.actionSystemPrompt],
                ["role": "user",   "content": userMsg]
            ],
            "response_format": ["type": "json_object"],
            "reasoning_effort": Self.reasoningEffort
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SmartSearchError.apiError(body.prefix(200).description)
        }

        let envelope = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let planData = content.data(using: .utf8) else {
            throw SmartSearchError.parseError("no content in action plan")
        }

        // The model returns either a message envelope or an event envelope.
        // Discriminated by the "type" field at the top of the JSON.
        struct Discriminator: Decodable { let type: String }
        let kind = try JSONDecoder().decode(Discriminator.self, from: planData)

        switch kind.type.lowercased() {
        case "message":
            struct Raw: Decodable {
                let platform: String
                let recipient: String
                let content: String
            }
            let raw = try JSONDecoder().decode(Raw.self, from: planData)
            guard let platform = ComposePlatform(rawValue: raw.platform.lowercased()) else {
                throw SmartSearchError.parseError("unknown platform: \(raw.platform)")
            }
            return .sendMessage(MessageAction(
                platform: platform,
                recipientName: raw.recipient,
                content: raw.content,
                contactAvatar: nil
            ))

        case "event":
            struct Raw: Decodable {
                let title: String
                let start_date: String        // ISO 8601
                let duration_minutes: Int?
                let attendees: [String]?
                let location: String?
                let notes: String?
            }
            let raw = try JSONDecoder().decode(Raw.self, from: planData)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var startDate = iso.date(from: raw.start_date)
            if startDate == nil {
                let basic = ISO8601DateFormatter()
                basic.formatOptions = [.withInternetDateTime]
                startDate = basic.date(from: raw.start_date)
            }
            guard let start = startDate else {
                throw SmartSearchError.parseError("bad start_date: \(raw.start_date)")
            }
            return .createEvent(EventAction(
                title: raw.title,
                startDate: start,
                durationMinutes: raw.duration_minutes ?? 60,
                attendees: raw.attendees ?? [],
                location: raw.location ?? "",
                notes: raw.notes ?? ""
            ))

        default:
            throw SmartSearchError.parseError("unknown action type: \(kind.type)")
        }
    }

    private static let actionSystemPrompt = """
    You convert a user's free-form action intent into a structured JSON
    plan. Two action types are supported. Respond ONLY with one JSON
    object — no other text. The first field is always "type", which is
    either "message" or "event".

    ─── Type "message" — for sending a message ─────────────────────────────
    {
      "type": "message",
      "platform": "whatsapp" | "imessage" | "discord" | "mail",
      "recipient": "<contact name as written by the user, no titles>",
      "content": "<the message body to pre-populate the compose box>"
    }

    ─── Type "event" — for creating a calendar event ───────────────────────
    {
      "type": "event",
      "title": "<short event title>",
      "start_date": "<ISO 8601 absolute datetime with tz, e.g. 2026-05-28T15:00:00Z>",
      "duration_minutes": <int, default 60>,
      "attendees": ["name1", "name2"],
      "location": "<optional location string, or empty>",
      "notes": "<optional context for the description, or empty>"
    }

    Picking the type:
    - "send/text/email/message/dm/whatsapp/imessage" → message
    - "meeting/event/calendar/invite/schedule/book/set up a call" → event
    - When ambiguous, prefer message.

    Message rules:
    - "platform" defaults to "whatsapp" when not specified.
    - "content" should be short (1-3 sentences), conversational. Rephrase
      "this" into a sendable form rather than copying verbatim. Don't
      include greetings or the recipient's name as a salutation.
    - Explicit messages ("send drishtu hi") are used verbatim.

    Event rules:
    - "start_date" MUST be ISO 8601 with a Z or ±offset. Resolve relative
      times ("tomorrow at 3pm", "next monday morning") against the
      "Current time" header in the user message. Assume local timezone if
      none specified, and emit with the local offset.
    - "duration_minutes" defaults to 60 if not specified. Common values:
      15, 30, 45, 60, 90, 120.
    - "attendees" is a list of contact names as written; resolve to
      addresses later. Always include the people the user mentioned.
    - "notes" should briefly capture what the meeting is about. If the
      intent says "about this", use the selected content as context but
      summarize it (don't paste raw).

    Examples:

    Selected: "625 Leavenworth St, San Francisco, CA 94109"
    Intent:   "send a message to drishtu on whatsapp about this"
    →
    {"type":"message","platform":"whatsapp","recipient":"drishtu","content":"Here's the address: 625 Leavenworth St, San Francisco, CA 94109"}

    Selected: "(any content)"
    Intent:   "email mom saying happy birthday"
    →
    {"type":"message","platform":"mail","recipient":"mom","content":"Happy birthday!"}

    Current time: 2026-05-27T11:00:00-07:00
    Selected: "we should chat about the modding tool"
    Intent:   "set up a 30min meeting with drishtu tomorrow at 3pm about this"
    →
    {"type":"event","title":"Modding tool discussion","start_date":"2026-05-28T15:00:00-07:00","duration_minutes":30,"attendees":["drishtu"],"location":"","notes":"Chat about the modding tool."}

    Current time: 2026-05-27T11:00:00-07:00
    Selected: "(any content)"
    Intent:   "book a 1hr coffee with jamie next thursday at 10am at blue bottle"
    →
    {"type":"event","title":"Coffee with Jamie","start_date":"2026-06-04T10:00:00-07:00","duration_minutes":60,"attendees":["jamie"],"location":"Blue Bottle","notes":""}
    """

    // MARK: - Key handling

    private func loadKey() -> String? {
        // Only cache successful loads. A miss is NOT cached — otherwise one
        // transient failure (file not yet readable, race with app launch,
        // etc.) kills AI for the entire session and the user has to relaunch.
        // Re-scanning paths on misses is a few stat() calls — negligible.
        if let k = cachedKey, !k.isEmpty { return k }

        // 1. Process environment first — set via `OPENAI_API_KEY=... open …`
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.isEmpty {
            cachedKey = env
            return env
        }

        // 2. Scan candidate file paths. A file can be either:
        //    - A bare key (one line, just sk-...)
        //    - A .env file with OPENAI_API_KEY=sk-... among other lines
        for path in Self.keyLookupPaths {
            guard FileManager.default.fileExists(atPath: path),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }

            if let key = Self.extractKey(from: contents), !key.isEmpty {
                cachedKey = key
                return key
            }
        }

        return nil
    }

    /// Pull `OPENAI_API_KEY` out of a file's contents. Handles both:
    ///   - .env style:  OPENAI_API_KEY=sk-...
    ///   - .env w/ quotes:  OPENAI_API_KEY="sk-..."
    ///   - bare key file:  sk-...
    nonisolated private static func extractKey(from contents: String) -> String? {
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Skip comment lines
            if line.hasPrefix("#") { continue }
            // dotenv-style key=value
            if line.hasPrefix("OPENAI_API_KEY") || line.hasPrefix("export OPENAI_API_KEY") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                var value = line[line.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { return value }
            }
            // Bare key file: a single line starting with "sk-"
            if line.hasPrefix("sk-") {
                return line
            }
        }
        return nil
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    You are a query planner for spotlight++, a personal Mac search app. The user types natural-language queries and you decide which of their local data sources to search and what the actual search terms should be.

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
    - "search_term": the CONCEPTUAL CORE of what the user is looking for, expanded with 2-5 synonyms or related terms. This is what gets embedded for semantic similarity, so include words that the matching messages would actually contain — NOT the contact's name, NOT filler. e.g. for "addresses i sent drishti" → "street address physical location". For "what is drishti mad about" → "angry upset confrontation hurt feelings".
    - SPECIAL CASE — LITERAL-TOKEN ENTITIES: when the user is asking about URLs / links, emails, phone numbers, or other entities recognized by a literal token prefix, the "search_term" MUST be that literal prefix (not synonyms). The embedding model aligns far more strongly with the exact token used in real data than with abstract synonyms. Map:
        • URLs / links / websites / articles → search_term: "https"
        • email addresses / emails sent      → search_term: "@gmail.com"
        • phone numbers                      → search_term: "+1 555"
        • hex color codes                    → search_term: "#ff"
      Verified empirically: "https" alone gives clean separation between real URL strings and conversational text; expanded variants like "URL link shared" miss URLs that score 0.20-0.25 and accept noise that scores higher.
    - "keywords": 1-5 short search terms extracted from the query — used as a fallback keyword filter. STRIP filler words. Keep nouns, proper names, meaningful verbs.
    - "contact": when the query mentions a person by name, put that name here (without titles). Otherwise null. The contact is a FILTER, not a search term.
    - "time_range": only when the query explicitly mentions a time window; default to "any".
    - "source": pick the single most likely place. When ambiguous, prefer "any".

    Examples:

    Q: "i sent an airbnb link to drishtu can you find it"
    A: {"source": "messages", "search_term": "https", "keywords": ["airbnb", "link"], "contact": "drishtu", "time_range": "any", "explanation": "Searching messages with drishtu for an airbnb link"}

    Q: "what links have i sent to drish"
    A: {"source": "messages", "search_term": "https", "keywords": ["link"], "contact": "drish", "time_range": "any", "explanation": "Searching messages with drish for links you sent"}

    Q: "phone number mom gave me"
    A: {"source": "messages", "search_term": "+1 555", "keywords": ["phone", "number"], "contact": "mom", "time_range": "any", "explanation": "Searching messages with mom for a phone number"}

    Q: "addresses i sent drishti"
    A: {"source": "messages", "search_term": "street address physical location apartment", "keywords": ["address"], "contact": "drishti", "time_range": "any", "explanation": "Searching messages with drishti for street addresses"}

    Q: "what was drishti mad about"
    A: {"source": "messages", "search_term": "angry upset confrontation hurt feelings frustrated", "keywords": ["mad", "angry"], "contact": "drishti", "time_range": "any", "explanation": "Searching messages from drishti for angry/upset content"}

    Q: "the email from chase about my credit card last week"
    A: {"source": "mail", "search_term": "credit card statement transaction", "keywords": ["chase", "credit", "card"], "contact": null, "time_range": "week", "explanation": "Last week's email from Chase about a credit card"}

    Q: "show me my resume from 2026"
    A: {"source": "files", "search_term": "resume cv document", "keywords": ["resume", "2026"], "contact": null, "time_range": "any", "explanation": "Searching files for 2026 resume"}

    Q: "that article i was reading about transformers"
    A: {"source": "browser", "search_term": "transformer neural network attention article", "keywords": ["transformers", "article"], "contact": null, "time_range": "any", "explanation": "Browser history for a transformers article"}

    Q: "did i copy that aws cli command earlier"
    A: {"source": "clipboard", "search_term": "aws cli command shell", "keywords": ["aws"], "contact": null, "time_range": "today", "explanation": "Clipboard history for an AWS CLI command"}
    """
}

// MARK: - Plan model

struct QueryPlan: Hashable {
    enum Source: String, Hashable {
        case messages, mail, browser, files, apps, clipboard, any
    }
    enum TimeRange: String, Hashable {
        case today, week, month, year, any
    }

    let source: Source
    let searchTerm: String
    let keywords: [String]
    let contact: String?
    let timeRange: TimeRange
    let explanation: String

    var searchQuery: String {
        // Composed string for services that don't take a contact filter
        // (browser/files/clipboard). For messaging sources we use the
        // contact-aware path in the ViewModel and ignore this.
        var parts = keywords
        if let c = contact, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " ")
    }
}

// Custom decoder so we can be lenient with what the LLM returns:
//   - `time_range` may be null, missing, or an unknown string
//   - `source` may come back as "email" instead of "mail", or unknown
//   - missing optional fields don't blow up the whole plan
extension QueryPlan: Decodable {
    enum CodingKeys: String, CodingKey {
        case source, keywords, contact, explanation
        case searchTerm = "search_term"
        case timeRange  = "time_range"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawSource = (try? c.decode(String.self, forKey: .source)) ?? "any"
        switch rawSource.lowercased() {
        case "messages", "message", "chat", "chats": self.source = .messages
        case "mail", "email", "emails":              self.source = .mail
        case "browser", "web", "history":            self.source = .browser
        case "files", "file", "folder", "folders":   self.source = .files
        case "apps", "app", "application":           self.source = .apps
        case "clipboard", "clip", "pasteboard":      self.source = .clipboard
        default:                                     self.source = .any
        }

        self.keywords    = (try? c.decode([String].self, forKey: .keywords)) ?? []
        self.contact     = try? c.decodeIfPresent(String.self, forKey: .contact)
        self.explanation = (try? c.decode(String.self, forKey: .explanation)) ?? ""

        // Fall back to joined keywords when the planner forgets to emit one.
        let rawTerm = (try? c.decodeIfPresent(String.self, forKey: .searchTerm)) ?? ""
        self.searchTerm = rawTerm.isEmpty ? self.keywords.joined(separator: " ") : rawTerm

        let rawTime: String = (try? c.decodeIfPresent(String.self, forKey: .timeRange)) ?? "any"
        self.timeRange = TimeRange(rawValue: rawTime.lowercased()) ?? .any
    }
}

enum SmartSearchError: Error, CustomStringConvertible {
    case noAPIKey
    case apiError(String)
    case parseError(String)

    var description: String {
        switch self {
        case .noAPIKey:           return "OpenAI API key not configured"
        case .apiError(let s):    return "OpenAI API error: \(s)"
        case .parseError(let s):  return "Parse error: \(s)"
        }
    }
}

// MARK: - OpenAI response envelope

private struct OpenAIChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
    }
    struct Message: Decodable {
        let content: String
    }
}
