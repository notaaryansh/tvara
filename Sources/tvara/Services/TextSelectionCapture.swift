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
        // text. Native Cocoa text views answer this directly, so we skip
        // the synthetic ⌘C, the main-thread wait and the clipboard
        // snapshot/restore entirely. Electron/web views usually don't
        // answer — they fall through to the ⌘C path below.
        if let pid = frontmost?.processIdentifier,
           let text = axSelectedText(pid: pid) {
            return Result(text: text, sourceAppName: sourceAppName)
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

    /// Selected text of the focused UI element in `pid`, via the AX API.
    /// Returns nil when the app doesn't expose it or nothing is selected.
    /// A short messaging timeout keeps an unresponsive app from stalling
    /// the hotkey.
    private static func axSelectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
