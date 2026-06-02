import AppKit
import Foundation

/// System-level command source — sleep / shut down / restart / lock screen
/// / log out. Same alias-table shape as the other command services, with
/// two deliberate departures:
///
/// 1. **No Levenshtein fuzzy fallback.** A typo of `shutdown` quietly
///    surfacing Shut Down is exactly the kind of accident this app should
///    never enable. Match is strict prefix-only.
/// 2. **Minimum query length of 3.** Typing `s` shouldn't put Shut Down
///    at the top of an ambiguous result list. The user has to commit to
///    at least three characters before any system action shows up.
///
/// Execution goes through NSAppleScript on a detached task so the launcher
/// dismiss animation isn't blocked by AppleEvent IPC.
final class SystemActionsService {

    private struct Entry {
        let alias: String     // lowercase
        let canonical: String // shown as the row title
        let action: SystemAction
    }

    /// Hand-curated, deliberately small. Each canonical action has a few
    /// natural aliases. No bare single-word "go" / "now" / "off" type
    /// aliases that could surface unintentionally on partial typing.
    private static let entries: [Entry] = [
        Entry(alias: "sleep",          canonical: "Sleep",        action: .sleep),
        Entry(alias: "sleep now",      canonical: "Sleep",        action: .sleep),

        Entry(alias: "shut down",      canonical: "Shut Down",    action: .shutDown),
        Entry(alias: "shutdown",       canonical: "Shut Down",    action: .shutDown),
        Entry(alias: "power off",      canonical: "Shut Down",    action: .shutDown),
        Entry(alias: "turn off",       canonical: "Shut Down",    action: .shutDown),

        Entry(alias: "restart",        canonical: "Restart",      action: .restart),
        Entry(alias: "reboot",         canonical: "Restart",      action: .restart),

        Entry(alias: "lock screen",    canonical: "Lock Screen",  action: .lockScreen),
        Entry(alias: "lock",           canonical: "Lock Screen",  action: .lockScreen),

        Entry(alias: "log out",        canonical: "Log Out",      action: .logOut),
        Entry(alias: "logout",         canonical: "Log Out",      action: .logOut),
        Entry(alias: "sign out",       canonical: "Log Out",      action: .logOut),
    ]

    /// Minimum query length before any system action surfaces. Three
    /// characters is enough to disambiguate from other command sources
    /// while making it virtually impossible to surface a destructive
    /// action through a single accidental keystroke.
    private static let minimumQueryLength = 3

    func match(query rawQuery: String) -> [SearchResult] {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= Self.minimumQueryLength else { return [] }

        var seen: Set<SystemAction> = []
        var hits: [Entry] = []
        for entry in Self.entries {
            guard entry.alias.hasPrefix(normalized) else { continue }
            guard !seen.contains(entry.action) else { continue }
            seen.insert(entry.action)
            hits.append(entry)
        }
        // NO FUZZY FALLBACK — destructive actions should never surface
        // through Levenshtein guesses. If prefix doesn't hit, we return
        // nothing and the user has to type cleanly.

        return hits.prefix(8).enumerated().map { idx, entry in
            SearchResult(
                title: entry.canonical,
                subtitle: "System",
                source: .systemAction,
                date: nil,
                badge: nil,
                openTarget: .systemAction(entry.action),
                // Same command-band rank as window/settings/folders so
                // they interleave cleanly when a query spans multiple
                // command sources. 920 sits just below settings (930)
                // and folders (925) on purpose — system actions are
                // intentionally the LEAST clickable command class.
                rank: 920 - idx
            )
        }
    }

    /// Execute the action by running an AppleScript off the main thread.
    /// Shut down / restart / log out trigger macOS' built-in confirmation
    /// dialog with a 60-second countdown — we rely on that for safety,
    /// no extra prompt from our side.
    @discardableResult
    func execute(_ action: SystemAction) -> Bool {
        let script: String
        switch action {
        case .sleep:
            script = "tell application \"System Events\" to sleep"
        case .shutDown:
            script = "tell application \"System Events\" to shut down"
        case .restart:
            script = "tell application \"System Events\" to restart"
        case .logOut:
            script = "tell application \"System Events\" to log out"
        case .lockScreen:
            // ⌃⌘Q is the system shortcut for "Lock Screen" — Accessibility
            // already grants us the ability to post key events for window
            // management, so this reuses that permission.
            script = """
            tell application "System Events" to keystroke "q" using {command down, control down}
            """
        }
        Task.detached {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error {
                    NSLog("[system-action] %@ failed: %@",
                          String(describing: action), error)
                }
            }
        }
        return true
    }
}
