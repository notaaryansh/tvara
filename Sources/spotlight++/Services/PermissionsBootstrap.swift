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
    /// Run on every app launch. Each permission is *checked first*; the
    /// underlying request API is only invoked when the status is still
    /// undetermined. Combined with a stable signing identity (see
    /// build-app.sh), grants persist across rebuilds and the user only
    /// ever sees prompts on the very first launch of a fresh install.
    static func requestAll() {
        requestAccessibilityIfNeeded()
        requestContactsIfNeeded()
        requestCalendarIfNeeded()
        requestFullDiskAccessIfNeeded()
        requestUserFoldersIfNeeded()
        requestAutomationIfNeeded()
    }

    // MARK: - Accessibility

    /// Accessibility is the one TCC service that won't auto-prompt when
    /// its API is hit — you have to call AXIsProcessTrustedWithOptions
    /// with kAXTrustedCheckOptionPrompt = true. We check the silent
    /// `AXIsProcessTrusted()` first so a granted user gets no popup.
    private static func requestAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            NSLog("[perms] Accessibility: already granted")
            return
        }
        let axOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        NSLog("[perms] Accessibility: %@", axGranted ? "granted" : "prompted")
    }

    // MARK: - Contacts

    private static func requestContactsIfNeeded() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            NSLog("[perms] Contacts: already granted")
        case .denied, .restricted:
            NSLog("[perms] Contacts: denied (user must change in Settings)")
        default:
            // .notDetermined — fire the actual prompt.
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                NSLog("[perms] Contacts: %@", granted ? "granted" : "denied")
            }
        }
    }

    // MARK: - Calendar

    private static func requestCalendarIfNeeded() {
        let status = EKEventStore.authorizationStatus(for: .event)
        // macOS 14+ adds .fullAccess / .writeOnly. Treat both as granted.
        if #available(macOS 14.0, *) {
            if status == .fullAccess || status == .writeOnly {
                NSLog("[perms] Calendar: already granted")
                return
            }
        } else if status == .authorized {
            NSLog("[perms] Calendar: already granted")
            return
        }
        if status == .denied || status == .restricted {
            NSLog("[perms] Calendar: denied (user must change in Settings)")
            return
        }
        // .notDetermined — request.
        EKEventStore().requestFullAccessToEvents { granted, _ in
            NSLog("[perms] Calendar: %@", granted ? "granted" : "denied")
        }
    }

    // MARK: - Full Disk Access (Mail / Notes / Messages indexes)

    /// FDA has no public status API — the only way to know whether we
    /// have access to a TCC-protected file is to *try* reading it. We
    /// do a single one-byte probe per indexable source and short-circuit
    /// if any succeeds (which means FDA is already granted; macOS won't
    /// prompt again). When ALL probes fail, the next service touch will
    /// re-trigger the system prompt naturally.
    private static func requestFullDiskAccessIfNeeded() {
        Task.detached {
            let home = NSHomeDirectory()
            for path in [
                "/Library/Mail",
                "/Library/Application Support/com.apple.notes/NoteStore.sqlite",
                "/Library/Messages/chat.db",
            ] {
                let url = URL(fileURLWithPath: home + path)
                if (try? Data(contentsOf: url, options: [.mappedIfSafe])) != nil {
                    NSLog("[perms] Full Disk Access: already granted")
                    return
                }
            }
            NSLog("[perms] Full Disk Access: not granted (will prompt on first use)")
        }
    }

    // MARK: - Desktop / Documents / Downloads (per-folder TCC)

    /// macOS gates the three "user data folders" via separate TCC entries.
    /// Listing each once will prompt on first ever access and silently
    /// succeed on every later launch — same as FDA, no public status API.
    private static func requestUserFoldersIfNeeded() {
        Task.detached {
            let home = NSHomeDirectory()
            for folder in ["Desktop", "Documents", "Downloads"] {
                _ = try? FileManager.default
                    .contentsOfDirectory(atPath: "\(home)/\(folder)")
            }
        }
    }

    // MARK: - Automation → Messages / Spotify

    /// AEDeterminePermissionToAutomateTarget caches the result inside TCC
    /// once granted — subsequent calls return noErr without prompting.
    /// The first call IS the prompt. Safe to keep at launch.
    private static func requestAutomationIfNeeded() {
        Task.detached {
            requestAutomation(bundleId: "com.apple.iChat",    label: "Messages")
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
