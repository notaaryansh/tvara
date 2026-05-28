import AppKit
import ApplicationServices
import Contacts
import EventKit

/// One-shot, fire-everything-at-launch permission bootstrapper.
///
/// macOS' TCC system is intentionally quiet — most permissions only
/// prompt the user when an API needing them is actually invoked. That
/// makes for surprise denials mid-flow ("why isn't iMessage sending?").
/// This bootstrap actively pokes every API we depend on so the user sees
/// all prompts up-front, in one batch, and we can log what came back.
///
/// Specifically handles:
///   - Accessibility            (CGEvent posting + global hotkey)
///   - Full Disk Access         (~/Library/Mail, /Notes, /Messages)
///   - Desktop / Documents / Downloads folder access
///   - Contacts                 (name → phone lookup)
///   - Calendar                 (event creation)
///   - Automation → Messages    (iMessage AppleScript send)
///   - Automation → Spotify     (playback control)
enum PermissionsBootstrap {
    /// Run on every app launch. Idempotent — if a permission is already
    /// granted or already denied, the relevant API call is a no-op.
    static func requestAll() {
        // Accessibility — the ONLY permission macOS won't auto-prompt for
        // even when an Accessibility-requiring API is called. We have to
        // explicitly ask via AXIsProcessTrustedWithOptions with the
        // prompt-option set. Shows "spotlight++ would like to control
        // this computer using Accessibility" → "Open System Settings".
        let axOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        NSLog("[perms] Accessibility: %@", axGranted ? "granted" : "denied/pending")

        // Full Disk Access (proxy via touching protected files).
        // No direct API — we just read a TCC-gated path and let macOS
        // show the prompt if needed.
        Task.detached {
            let home = NSHomeDirectory()
            for path in [
                "/Library/Mail",
                "/Library/Application Support/com.apple.notes/NoteStore.sqlite",
                "/Library/Messages/chat.db",
            ] {
                _ = try? Data(contentsOf: URL(fileURLWithPath: home + path),
                              options: [.mappedIfSafe])
            }
        }

        // Desktop / Documents / Downloads — handled by listing each dir;
        // macOS' file-folder TCC prompts on first list call.
        Task.detached {
            let home = NSHomeDirectory()
            for folder in ["Desktop", "Documents", "Downloads"] {
                _ = try? FileManager.default
                    .contentsOfDirectory(atPath: "\(home)/\(folder)")
            }
        }

        // Contacts — explicit async request via CNContactStore.
        let cnStore = CNContactStore()
        cnStore.requestAccess(for: .contacts) { granted, _ in
            NSLog("[perms] Contacts: %@", granted ? "granted" : "denied")
        }

        // Calendar (Events) — modern EKEventStore API on macOS 14+.
        let ekStore = EKEventStore()
        ekStore.requestFullAccessToEvents { granted, _ in
            NSLog("[perms] Calendar: %@", granted ? "granted" : "denied")
        }

        // Automation → Messages.app (com.apple.iChat). Posts the AE
        // permission prompt without actually launching Messages.
        Task.detached {
            requestAutomation(bundleId: "com.apple.iChat",   label: "Messages")
        }

        // Automation → Spotify.app
        Task.detached {
            requestAutomation(bundleId: "com.spotify.client", label: "Spotify")
        }
    }

    /// Trigger the Automation TCC prompt for a specific target app
    /// without launching it. typeWildCard means we're asking for blanket
    /// AppleScript access (good enough for our send/play scripts).
    private static func requestAutomation(bundleId: String, label: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let descPtr = target.aeDesc else {
            NSLog("[perms] Automation → %@: couldn't build AE descriptor", label)
            return
        }
        let status = AEDeterminePermissionToAutomateTarget(
            descPtr, typeWildCard, typeWildCard, true
        )
        let outcome: String
        switch status {
        case noErr:                       outcome = "granted"
        case OSStatus(errAEEventNotPermitted): outcome = "denied"
        case OSStatus(procNotFound):      outcome = "target app not installed"
        default:                          outcome = "status=\(status)"
        }
        NSLog("[perms] Automation → %@: %@", label, outcome)
    }
}
