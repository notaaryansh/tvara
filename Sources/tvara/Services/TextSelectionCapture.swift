import AppKit
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
        let sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName

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

        // The system needs a moment to handle the keystroke and write
        // to the pasteboard. 80ms is empirically enough for most apps
        // (including Chrome/Electron); 50ms is too tight, 100ms is safe.
        // Block briefly — this runs on the main thread but it's an
        // 80ms window we're going to spend opening the panel anyway.
        Thread.sleep(forTimeInterval: 0.08)

        let afterChange = pb.changeCount
        let captured: String? = (afterChange > beforeChange)
            ? pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // Restore the user's original clipboard so we haven't polluted it.
        // Done AFTER reading our copy.
        restorePasteboard(pb, from: snapshot)

        guard let text = captured, !text.isEmpty else { return nil }
        return Result(text: text, sourceAppName: sourceAppName)
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
