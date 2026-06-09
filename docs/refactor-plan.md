# Action-Layer Refactor — Plan & Checklist

## Goal

Restructure the action layer so adding a new compose verb (Mail, Reminder, Note, …)
is a self-contained operation: one folder, one file per concern, one line in the
registry. No more god-object edits, no more cross-folder feature scatter.

## Non-goals (this session — pursue separately)

- Decomposing the 1215-line `SearchViewModel`.
- Restructuring the 18 search-provider services into `Sources/`.
- Replacing the LLM planner with a local grammar.
- Making WhatsApp / Discord / Mail composes actually send (still UI stubs).
- Pulling iMessage send out of `SearchViewModel.confirmSend` (needs the
  messages service for handle resolution — left for a later pass).

## Target shape — landed

```
Sources/tvara/
  Actions/
    ComposeVerb.swift              <- protocol every verb conforms to
    ComposeVerbRegistry.swift      <- single source of truth (static array)
    Compose/
      CommonModels.swift           <- ComposeKind, ComposeStage, ComposeState, ComposePlatform
    Calendar/
      CalendarVerb.swift           <- conforms to ComposeVerb
      CalendarPayload.swift        <- EventAction struct
      CalendarComposeView.swift    <- moved from Views/
      CalendarEventSaver.swift     <- moved from Services/
    Message/
      MessageVerb.swift
      MessagePayload.swift         <- MessageAction struct
      MessageComposeView.swift     <- extracted from ComposeView.swift
      IMessageSender.swift         <- moved from Services/
Tests/
  tvaraTests/
    FuzzyMatchTests.swift                  (12 tests — pre-existing behavior)
    SystemActionsServiceTests.swift        (15 tests — pre-existing behavior)
    ComposeVerbRegistryTests.swift         (8 tests — new shape)
    CalendarVerbTests.swift                (6 tests)
    MessageVerbTests.swift                 (8 tests)
```

## Checklist

### Phase 0 — Safety baseline
- [x] Verify clean build (`swift build`) — baseline confirmed
- [x] Add `Tests/tvaraTests/` target to `Package.swift`
- [x] Write `FuzzyMatchTests.swift` — 12 tests pin current behavior
- [x] Write `SystemActionsServiceTests.swift` — 15 tests pin destructive-action safety
- [x] `swift test` green (27 tests)

### Phase 1 — Introduce abstractions
- [x] Create `Actions/ComposeVerb.swift` (protocol)
- [x] Create `Actions/ComposeVerbRegistry.swift` (empty array)
- [x] `swift build` green

### Phase 2 — Calendar verb extraction
- [x] `mkdir Actions/Calendar`
- [x] Move `Services/CalendarEventSaver.swift` → `Actions/Calendar/`
- [x] `swift build` green
- [x] Move `Views/CalendarComposeView.swift` → `Actions/Calendar/`
- [x] `swift build` green
- [x] Create `Actions/Calendar/CalendarPayload.swift` with `EventAction`; remove from `Models/ComposeAction.swift`
- [x] `swift build` green
- [x] Create `Actions/Calendar/CalendarVerb.swift` (conforms to ComposeVerb)
- [x] Register in `ComposeVerbRegistry.all`
- [x] `swift build` green; `swift test` green

### Phase 3 — Message verb extraction
- [x] `mkdir Actions/Message`
- [x] Move `Services/IMessageSender.swift` → `Actions/Message/`
- [x] `swift build` green
- [x] Extract message UI from `ComposeView.swift` into `Actions/Message/MessageComposeView.swift`
- [x] `swift build` green
- [x] Create `Actions/Message/MessagePayload.swift` with `MessageAction`; remove from `Models/ComposeAction.swift`
- [x] `swift build` green
- [x] Create `Actions/Message/MessageVerb.swift`
- [x] Register in `ComposeVerbRegistry.all`
- [x] Refactor `ComposeView.content(for:)` to consult registry instead of hardcoded `switch kind`
- [x] `swift build` green; `swift test` green

### Phase 4 — Consolidate shared compose models
- [x] Create `Actions/Compose/CommonModels.swift` with `ComposeKind`, `ComposePlatform`, `ComposeStage`, `ComposeState`
- [x] Delete `Models/ComposeAction.swift`
- [x] `swift build` green; `swift test` green

### Phase 5 — Verb-level tests
- [x] Write `ComposeVerbRegistryTests.swift` — registry size, id uniqueness, state routing
- [x] Write `CalendarVerbTests.swift` — handles/rejects + payload equality
- [x] Write `MessageVerbTests.swift` — handles/rejects + platform metadata
- [x] `swift test` green (49 tests total)

### Phase 6 — Final verification
- [x] `swift build` green
- [x] `swift test` green
- [x] Document "how to add a new verb" recipe (below)

## How to add a new verb

Concrete example — adding a Reminder verb that creates an item in Apple
Reminders.

### 1. Create the folder

```
Sources/tvara/Actions/Reminder/
```

### 2. Define the payload — `ReminderPayload.swift`

```swift
import Foundation

struct ReminderAction: Equatable {
    var title: String
    var dueDate: Date?
    var notes: String
}
```

### 3. Add the executor — `ReminderSaver.swift`

```swift
import EventKit

enum ReminderSaver {
    static func save(_ action: ReminderAction) async throws { ... }
}
```

### 4. Add the SwiftUI compose form — `ReminderComposeView.swift`

```swift
import SwiftUI

struct ReminderComposeView: View {
    @ObservedObject var viewModel: SearchViewModel
    let action: ReminderAction
    let sourceSnippet: String
    let sending: Bool
    var body: some View { ... }
}
```

### 5. Add a new `ComposeKind` case — `Actions/Compose/CommonModels.swift`

```swift
enum ComposeKind: Equatable {
    case sendMessage(MessageAction)
    case createEvent(EventAction)
    case createReminder(ReminderAction)   // ← new
}
```

This is the one cross-cutting edit. The `ComposeKind` enum is the planner's
output type and has to enumerate what it can produce — this coupling is
intentional, not a leaky abstraction.

### 6. Define the verb — `ReminderVerb.swift`

```swift
import SwiftUI

@MainActor
struct ReminderVerb: ComposeVerb {
    let id = "reminder"
    let displayName = "Reminder"

    func handles(_ state: ComposeState) -> Bool {
        guard case .createReminder = state.kind else { return false }
        return true
    }

    func makeView(state: ComposeState, viewModel: SearchViewModel) -> AnyView {
        guard case .createReminder(let r) = state.kind else { return AnyView(EmptyView()) }
        return AnyView(ReminderComposeView(
            viewModel: viewModel, action: r,
            sourceSnippet: state.sourceSnippet,
            sending: state.stage == .sending
        ))
    }

    func execute(state: ComposeState) async throws {
        guard case .createReminder(let r) = state.kind else { return }
        try await ReminderSaver.save(r)
    }
}
```

### 7. Register — `ComposeVerbRegistry.swift`

```swift
static let all: [any ComposeVerb] = [
    CalendarVerb(),
    MessageVerb(),
    ReminderVerb(),   // ← add one line
]
```

### 8. Wire the planner

Update `SmartSearchService.planAction` to emit `.createReminder(...)` when
the intent matches. (Planner-side; out of scope for the verb refactor.)

### 9. Update `SearchViewModel.confirmSend`

Add a `case .createReminder(let r):` arm that calls
`try await ReminderVerb().execute(state: state)`. This is a temporary
ergonomic gap — `confirmSend` still has a per-kind switch because iMessage
needs the message service for handle resolution. Once that special case is
moved off `confirmSend`, the switch can become a single
`try await ComposeVerbRegistry.verb(for: state)?.execute(state: state)`
call and step 9 will disappear.

### 10. Tests — `Tests/tvaraTests/ReminderVerbTests.swift`

Mirror `CalendarVerbTests.swift` — `handles`, payload equality, stable id.

### What did NOT need to be touched

- `ComposeView.swift` — the router consults the registry, no per-verb switch.
- `Models/SearchResult.swift` — verbs are orthogonal to result types.
- All 18 search-provider services.

That's the modularity payoff.
