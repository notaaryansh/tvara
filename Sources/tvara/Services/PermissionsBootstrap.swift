import AppKit
import ApplicationServices
import Contacts
import EventKit

/// Permission requests, driven by the onboarding "Permissions" step.
///
/// macOS' TCC system only prompts when a protected API is actually invoked
/// (Accessibility is the exception — it never auto-prompts). We used to fire
/// every prompt at launch via `requestAll()`, which dumped a stack of system
/// dialogs on the user before they'd seen any UI. Now each prompt is triggered
/// from the onboarding step, when the user taps "Grant" on the matching row,
/// so the ask carries context and the user is never ambushed at first launch.
///
/// The ⌘K global hotkey uses Carbon `RegisterEventHotKey`, which needs no
/// Accessibility grant — so onboarding stays reachable even before anything is
/// granted. Accessibility is only needed later for text injection.
enum PermissionsBootstrap {

    /// The permissions surfaced as rows in the onboarding step. Raw values
    /// match the `id` strings passed to `permissionRow(id:...)` in
    /// OnboardingView, so the view can map a row straight to a request.
    enum Permission: String {
        case accessibility          // global hotkey chrome + text injection
        case contacts               // name → phone/email lookup
        case automation             // Messages/Spotify AppleScript + Calendar
        case fulldisk               // Full Disk Access + Desktop/Docs/Downloads
    }

    // MARK: - Public API (called from OnboardingView)

    /// Fire the system prompt(s) for one onboarding row and return the best
    /// available "granted" reading afterwards. Services with a status API
    /// (Accessibility, Contacts, Calendar) report accurately; those without
    /// (Automation, Full Disk Access) can only be confirmed on next use, so
    /// this falls back to whatever `currentlyGranted` can determine.
    @MainActor
    @discardableResult
    static func request(_ permission: Permission) async -> Bool {
        switch permission {
        case .accessibility:
            return requestAccessibility()
        case .contacts:
            return await requestContacts()
        case .automation:
            // AEDeterminePermissionToAutomateTarget can block while the dialog
            // is up — keep it off the main actor. Calendar has a real status
            // API and is the row's headline action, so use it as the signal.
            Task.detached { requestAutomationTargets() }
            return await requestCalendar()
        case .fulldisk:
            requestUserFolders()
            return probeFullDiskAccess()
        }
    }

    /// Silent status check — never prompts. Used to pre-fill the onboarding
    /// pills so an already-granted permission shows "Granted" on open.
    static func currentlyGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .automation:
            // No status API for Automation; treat Calendar as the proxy since
            // the row's headline action is "create calendar events".
            let status = EKEventStore.authorizationStatus(for: .event)
            return status == .fullAccess || status == .writeOnly
        case .fulldisk:
            return probeFullDiskAccess()
        }
    }

    // MARK: - Accessibility

    /// Accessibility never auto-prompts; passing kAXTrustedCheckOptionPrompt
    /// shows the "open System Settings" dialog. Returns the current trust
    /// state — false until the user flips the toggle in Settings (which the
    /// pill picks up next time the step re-checks).
    @discardableResult
    private static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Contacts

    private static func requestContacts() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        default:
            return await withCheckedContinuation { cont in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Calendar

    @discardableResult
    private static func requestCalendar() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || status == .writeOnly { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { cont in
            EKEventStore().requestFullAccessToEvents { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Full Disk Access (Mail / Notes / Messages indexes)

    /// FDA has no public status API — probe a TCC-protected file. A single
    /// successful read means FDA is granted; if all fail the next service
    /// touch re-triggers the system prompt naturally.
    private static func probeFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        for path in [
            "/Library/Mail",
            "/Library/Application Support/com.apple.notes/NoteStore.sqlite",
            "/Library/Messages/chat.db",
        ] {
            let url = URL(fileURLWithPath: home + path)
            if (try? Data(contentsOf: url, options: [.mappedIfSafe])) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Desktop / Documents / Downloads (per-folder TCC)

    /// Listing each folder once prompts on first access and silently succeeds
    /// afterwards — same shape as FDA, no public status API.
    private static func requestUserFolders() {
        let home = NSHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            _ = try? FileManager.default
                .contentsOfDirectory(atPath: "\(home)/\(folder)")
        }
    }

    // MARK: - Automation → Messages / Spotify

    private static func requestAutomationTargets() {
        requestAutomation(bundleId: "com.apple.iChat",    label: "Messages")
        requestAutomation(bundleId: "com.spotify.client", label: "Spotify")
    }

    /// Trigger the Automation TCC prompt for a target app without launching
    /// it. typeWildCard asks for blanket AppleScript access. The first call
    /// IS the prompt; TCC caches the result for subsequent calls.
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
        case noErr:                            outcome = "granted"
        case OSStatus(errAEEventNotPermitted): outcome = "denied"
        case OSStatus(procNotFound):           outcome = "target app not installed"
        default:                               outcome = "status=\(status)"
        }
        NSLog("[perms] Automation → %@: %@", label, outcome)
    }
}

// MARK: - Display + System Settings deep-links

extension PermissionsBootstrap.Permission {
    /// Row title in the onboarding + Settings UIs.
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .contacts:      return "Contacts"
        case .automation:    return "Automation"
        case .fulldisk:      return "Full Disk Access"
        }
    }

    /// One-line rationale shown under the title.
    var rationale: String {
        switch self {
        case .accessibility: return "Global hotkey and text injection"
        case .contacts:      return "Look up people by name for iMessage & email"
        case .automation:    return "Send iMessages and create calendar events"
        case .fulldisk:      return "Index Mail, Notes and files beyond your Downloads"
        }
    }

    /// SF Symbol for the row.
    var symbol: String {
        switch self {
        case .accessibility: return "hand.tap"
        case .contacts:      return "person.crop.circle"
        case .automation:    return "app.connected.to.app.below.fill"
        case .fulldisk:      return "internaldrive"
        }
    }

    /// Deep-link to the exact System Settings › Privacy & Security pane so the
    /// user lands on the right toggle instead of hunting for it.
    var systemSettingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .contacts:      anchor = "Privacy_Contacts"
        case .automation:    anchor = "Privacy_Automation"
        case .fulldisk:      anchor = "Privacy_AllFiles"
        }
        return URL(string: base + anchor)
    }
}

extension PermissionsBootstrap {
    /// All permissions, in the order they appear in the UI.
    static let allPermissions: [Permission] = [.accessibility, .contacts, .automation, .fulldisk]

    /// Open System Settings on the pane for `permission`.
    @MainActor
    static func openSystemSettings(for permission: Permission) {
        if let url = permission.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Modal "tvara needs access" alert with a button that jumps straight to
    /// the right System Settings pane. Use from feature code when an action
    /// needs a permission the user hasn't granted.
    @MainActor
    static func presentAccessNeeded(for permission: Permission) {
        let alert = NSAlert()
        alert.messageText = "tvara needs \(permission.title) access"
        alert.informativeText = permission.rationale + "."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings(for: permission)
        }
    }
}
