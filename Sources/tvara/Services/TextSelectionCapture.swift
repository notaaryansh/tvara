import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Capture the currently-selected text in the frontmost app by simulating
/// a ⌘C keystroke, reading the resulting pasteboard string, and restoring
/// the user's previous clipboard contents.
///
/// This is the standard macOS pattern for "act on whatever the user has
/// highlighted right now" because there's no public API to read another
/// app's selection directly (Accessibility's `AXSelectedText` works for
/// some apps but not Electron/web — the ⌘C trick is far more reliable).
///
/// Requires Accessibility permission to post CGEvents to other apps.
/// We already hold this for the global ⌘K hotkey.
enum TextSelectionCapture {
    /// Captured text + the human-readable name of the app the user was
    /// in when they pressed ⌘K. The app name drives the "FROM X" label
    /// in the acting context card so the user sees which app the
    /// selection came from (WhatsApp, Messages, Safari, etc.).
    struct Result {
        let text: String
        let sourceAppName: String?
    }

    /// Try to capture the selection. Returns nil if there's no text
    /// selected (the pasteboard didn't change after ⌘C), if the result
    /// is whitespace-only, or if posting events failed. Always restores
    /// the pasteboard to whatever it held before this call.
    static func grab() -> Result? {
        // Capture the frontmost app BEFORE we steal focus. After we open
        // our window, we'd be the frontmost app, which is useless info.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let sourceAppName = frontmost?.localizedName

        // Fast path: ask Accessibility for the focused element's selected
        // text. Native text views answer this directly, so we skip the
        // synthetic ⌘C, the main-thread wait and the clipboard
        // snapshot/restore entirely — both when there IS a selection and
        // when a native text field tells us there is none. Only apps that
        // don't answer (Electron/web views, mostly) fall through to ⌘C.
        if let pid = frontmost?.processIdentifier {
            switch axSelection(pid: pid) {
            case .text(let text):
                return Result(text: text, sourceAppName: sourceAppName)
            case .nothingSelected:
                return nil
            case .unknown:
                break
            }
        }

        let pb = NSPasteboard.general
        let beforeChange = pb.changeCount

        // Snapshot the user's current clipboard (all types) so we can
        // restore it after our temporary copy. Preserves rich content
        // like images, files, RTF that plain string-restore would lose.
        let snapshot = snapshotPasteboard(pb)

        // Post ⌘C to the focused app. Apple's recommended source for
        // synthesized "I'm pretending the user did this" events is
        // .combinedSessionState — gets posted as part of the session's
        // event stream so the target app processes it normally.
        guard postCommandC() else {
            return nil
        }

        // Poll for the copy to land instead of always sleeping the full
        // window: most apps write within a few ms, so a real selection
        // now opens the panel ~as soon as it's copied. 80ms stays the
        // ceiling (empirically enough for Chrome/Electron). Apps clear
        // the pasteboard (bumping changeCount) before writing, so keep
        // waiting until a string is actually readable.
        let deadline = Date().addingTimeInterval(0.08)
        var captured: String? = nil
        while Date() < deadline {
            if pb.changeCount != beforeChange,
               let s = pb.string(forType: .string) {
                captured = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let changed = pb.changeCount != beforeChange

        // Restore the user's original clipboard — but only if ⌘C actually
        // touched it. Rewriting an untouched pasteboard on every panel
        // open bumped changeCount (so clipboard history saw a phantom
        // "new" copy) and flattened lazily-promised types for nothing.
        if changed {
            restorePasteboard(pb, from: snapshot)
        }

        guard let text = captured, !text.isEmpty else { return nil }
        return Result(text: text, sourceAppName: sourceAppName)
    }

    private enum AXSelection {
        case text(String)
        /// A native text control answered and has no selection — definitive.
        case nothingSelected
        /// The app didn't answer or doesn't expose selection; try ⌘C.
        case unknown
    }

    /// Total time the AX queries below may block the hotkey, across all of
    /// them. Responsive apps answer in a few ms; an unresponsive one costs
    /// at most this before we move on.
    private static let axBudget: TimeInterval = 0.05

    /// Roles whose empty `AXSelectedText` really means "nothing selected".
    /// Other elements (web areas, groups) often report an empty string even
    /// when text is highlighted, so those stay `.unknown`.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Selection state of the focused UI element in `pid`, via the AX API.
    private static func axSelection(pid: pid_t) -> AXSelection {
        let deadline = Date().addingTimeInterval(axBudget)
        /// Give `element` whatever is left of the shared budget; false when
        /// it's spent.
        func arm(_ element: AXUIElement) -> Bool {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.005 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            return true
        }

        let app = AXUIElementCreateApplication(pid)
        guard arm(app) else { return .unknown }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unknown }
        let element = focused as! AXUIElement

        guard arm(element) else { return .unknown }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let str = value as? String else { return .unknown }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .text(trimmed) }

        guard arm(element) else { return .unknown }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &role
        ) == .success, let roleName = role as? String,
              textRoles.contains(roleName)
        else { return .unknown }
        return .nothingSelected
    }

    // MARK: - Pasteboard snapshot / restore

    private struct PasteboardItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    /// Capture every item + every type/data combination currently on the
    /// pasteboard so we can restore exactly what was there.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [PasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) {
                    data[type] = d
                }
            }
            return PasteboardItem(types: item.types, data: data)
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, from snapshot: [PasteboardItem]) {
        pb.clearContents()
        for snap in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in snap.data {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }

    // MARK: - CGEvent ⌘C synthesis

    /// Synthesize and post ⌘C to the frontmost app. Returns true if both
    /// the key-down and key-up events succeeded.
    private static func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // .cgAnnotatedSessionEventTap routes the event as if it came from
        // the user — most apps respond to this correctly.
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
