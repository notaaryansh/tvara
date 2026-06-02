import AppKit
import Foundation

/// Deep-links into macOS System Settings panes. macOS 13+ exposes a
/// documented URL scheme (`x-apple.systempreferences:<extension-id>`)
/// that opens directly to a specific pane — no AppleScript, no UI
/// scripting, no Accessibility taps required. Just NSWorkspace.open.
///
/// Match is a flat lowercase-prefix loop over a hardcoded alias table —
/// identical pattern to WindowManagerService. ~150 entries × prefix
/// check is sub-millisecond.
final class SystemSettingsService {

    /// One row per (alias → pane). `group` becomes the breadcrumb segment
    /// surfaced in the row subtitle ("Settings > Privacy"), so the user
    /// sees where in the System Settings hierarchy each pane lives.
    private struct Entry {
        let alias: String     // lowercase, what the user types
        let canonical: String // "Bluetooth", "Privacy → Camera"
        let group: String     // "Hardware", "System", "Privacy", "Identity"
        let paneID: String    // the part after `x-apple.systempreferences:`
    }

    /// Hand-curated panes worth deep-linking from a launcher. Add an entry
    /// here when you want another pane reachable directly. Declaration
    /// order is the permanent display priority within ties.
    private static let entries: [Entry] = [
        // ─── Hardware ─────────────────────────────────────────────────
        Entry(alias: "wifi",             canonical: "Wi-Fi",              group: "Hardware",
              paneID: "com.apple.wifi-settings-extension"),
        Entry(alias: "wi-fi",            canonical: "Wi-Fi",              group: "Hardware",
              paneID: "com.apple.wifi-settings-extension"),
        Entry(alias: "wireless",         canonical: "Wi-Fi",              group: "Hardware",
              paneID: "com.apple.wifi-settings-extension"),

        Entry(alias: "bluetooth",        canonical: "Bluetooth",          group: "Hardware",
              paneID: "com.apple.BluetoothSettings"),
        Entry(alias: "bt",               canonical: "Bluetooth",          group: "Hardware",
              paneID: "com.apple.BluetoothSettings"),

        Entry(alias: "network",          canonical: "Network",            group: "Hardware",
              paneID: "com.apple.Network-Settings.extension"),
        Entry(alias: "ethernet",         canonical: "Network",            group: "Hardware",
              paneID: "com.apple.Network-Settings.extension"),
        Entry(alias: "vpn",              canonical: "Network",            group: "Hardware",
              paneID: "com.apple.Network-Settings.extension"),

        Entry(alias: "sound",            canonical: "Sound",              group: "Hardware",
              paneID: "com.apple.Sound-Settings.extension"),
        Entry(alias: "audio",            canonical: "Sound",              group: "Hardware",
              paneID: "com.apple.Sound-Settings.extension"),
        Entry(alias: "volume",           canonical: "Sound",              group: "Hardware",
              paneID: "com.apple.Sound-Settings.extension"),

        Entry(alias: "displays",         canonical: "Displays",           group: "Hardware",
              paneID: "com.apple.Displays-Settings.extension"),
        Entry(alias: "display",          canonical: "Displays",           group: "Hardware",
              paneID: "com.apple.Displays-Settings.extension"),
        Entry(alias: "monitor",          canonical: "Displays",           group: "Hardware",
              paneID: "com.apple.Displays-Settings.extension"),
        Entry(alias: "resolution",       canonical: "Displays",           group: "Hardware",
              paneID: "com.apple.Displays-Settings.extension"),

        Entry(alias: "battery",          canonical: "Battery",            group: "Hardware",
              paneID: "com.apple.Battery-Settings.extension"),
        Entry(alias: "power",            canonical: "Battery",            group: "Hardware",
              paneID: "com.apple.Battery-Settings.extension"),

        Entry(alias: "keyboard",         canonical: "Keyboard",           group: "Hardware",
              paneID: "com.apple.Keyboard-Settings.extension"),
        Entry(alias: "shortcuts",        canonical: "Keyboard",           group: "Hardware",
              paneID: "com.apple.Keyboard-Settings.extension"),

        Entry(alias: "trackpad",         canonical: "Trackpad",           group: "Hardware",
              paneID: "com.apple.Trackpad-Settings.extension"),
        Entry(alias: "gestures",         canonical: "Trackpad",           group: "Hardware",
              paneID: "com.apple.Trackpad-Settings.extension"),

        Entry(alias: "mouse",            canonical: "Mouse",              group: "Hardware",
              paneID: "com.apple.Mouse-Settings.extension"),

        Entry(alias: "printers",         canonical: "Printers & Scanners", group: "Hardware",
              paneID: "com.apple.Print-Scan-Settings.extension"),
        Entry(alias: "scanners",         canonical: "Printers & Scanners", group: "Hardware",
              paneID: "com.apple.Print-Scan-Settings.extension"),
        Entry(alias: "print",            canonical: "Printers & Scanners", group: "Hardware",
              paneID: "com.apple.Print-Scan-Settings.extension"),

        // ─── System ───────────────────────────────────────────────────
        Entry(alias: "notifications",    canonical: "Notifications",      group: "System",
              paneID: "com.apple.Notifications-Settings.extension"),

        Entry(alias: "focus",            canonical: "Focus",              group: "System",
              paneID: "com.apple.Focus-Settings.extension"),
        Entry(alias: "do not disturb",   canonical: "Focus",              group: "System",
              paneID: "com.apple.Focus-Settings.extension"),
        Entry(alias: "dnd",              canonical: "Focus",              group: "System",
              paneID: "com.apple.Focus-Settings.extension"),

        Entry(alias: "screen time",      canonical: "Screen Time",        group: "System",
              paneID: "com.apple.Screen-Time-Settings.extension"),

        Entry(alias: "general",          canonical: "General",            group: "System",
              paneID: "com.apple.systempreferences.GeneralSettings"),
        Entry(alias: "about",            canonical: "General",            group: "System",
              paneID: "com.apple.systempreferences.GeneralSettings"),

        Entry(alias: "appearance",       canonical: "Appearance",         group: "System",
              paneID: "com.apple.Appearance-Settings.extension"),
        Entry(alias: "dark mode",        canonical: "Appearance",         group: "System",
              paneID: "com.apple.Appearance-Settings.extension"),
        Entry(alias: "light mode",       canonical: "Appearance",         group: "System",
              paneID: "com.apple.Appearance-Settings.extension"),
        Entry(alias: "theme",            canonical: "Appearance",         group: "System",
              paneID: "com.apple.Appearance-Settings.extension"),

        Entry(alias: "accessibility",    canonical: "Accessibility",      group: "System",
              paneID: "com.apple.Accessibility-Settings.extension"),

        Entry(alias: "control center",   canonical: "Control Center",     group: "System",
              paneID: "com.apple.ControlCenter-Settings.extension"),
        Entry(alias: "menu bar",         canonical: "Control Center",     group: "System",
              paneID: "com.apple.ControlCenter-Settings.extension"),

        Entry(alias: "siri",             canonical: "Siri & Spotlight",   group: "System",
              paneID: "com.apple.Siri-Settings.extension"),
        Entry(alias: "spotlight",        canonical: "Siri & Spotlight",   group: "System",
              paneID: "com.apple.Siri-Settings.extension"),

        Entry(alias: "date and time",    canonical: "Date & Time",        group: "System",
              paneID: "com.apple.Date-Time-Settings.extension"),
        Entry(alias: "date & time",      canonical: "Date & Time",        group: "System",
              paneID: "com.apple.Date-Time-Settings.extension"),
        Entry(alias: "clock",            canonical: "Date & Time",        group: "System",
              paneID: "com.apple.Date-Time-Settings.extension"),
        Entry(alias: "timezone",         canonical: "Date & Time",        group: "System",
              paneID: "com.apple.Date-Time-Settings.extension"),

        Entry(alias: "software update",  canonical: "Software Update",    group: "System",
              paneID: "com.apple.Software-Update-Settings.extension"),
        Entry(alias: "update",           canonical: "Software Update",    group: "System",
              paneID: "com.apple.Software-Update-Settings.extension"),
        Entry(alias: "system update",    canonical: "Software Update",    group: "System",
              paneID: "com.apple.Software-Update-Settings.extension"),

        Entry(alias: "storage",          canonical: "Storage",            group: "System",
              paneID: "com.apple.settings.Storage"),
        Entry(alias: "disk space",       canonical: "Storage",            group: "System",
              paneID: "com.apple.settings.Storage"),

        // ─── Privacy ──────────────────────────────────────────────────
        Entry(alias: "privacy",          canonical: "Privacy & Security", group: "Privacy",
              paneID: "com.apple.settings.PrivacySecurity.extension"),
        Entry(alias: "security",         canonical: "Privacy & Security", group: "Privacy",
              paneID: "com.apple.settings.PrivacySecurity.extension"),
        Entry(alias: "privacy and security", canonical: "Privacy & Security", group: "Privacy",
              paneID: "com.apple.settings.PrivacySecurity.extension"),

        Entry(alias: "camera",           canonical: "Privacy → Camera",   group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Camera"),
        Entry(alias: "camera permissions", canonical: "Privacy → Camera", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Camera"),

        Entry(alias: "microphone",       canonical: "Privacy → Microphone", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Microphone"),
        Entry(alias: "mic",              canonical: "Privacy → Microphone", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Microphone"),

        Entry(alias: "screen recording", canonical: "Privacy → Screen Recording", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_ScreenCapture"),
        Entry(alias: "screen capture",   canonical: "Privacy → Screen Recording", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_ScreenCapture"),

        Entry(alias: "full disk access", canonical: "Privacy → Full Disk Access", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_AllFiles"),
        Entry(alias: "disk access",      canonical: "Privacy → Full Disk Access", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_AllFiles"),

        Entry(alias: "location",         canonical: "Privacy → Location",  group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_LocationServices"),
        Entry(alias: "location services", canonical: "Privacy → Location", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_LocationServices"),

        Entry(alias: "app permissions",  canonical: "Privacy → Accessibility", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Accessibility"),
        Entry(alias: "accessibility permissions", canonical: "Privacy → Accessibility", group: "Privacy",
              paneID: "com.apple.preference.security?Privacy_Accessibility"),

        // ─── Identity ─────────────────────────────────────────────────
        Entry(alias: "apple id",         canonical: "Apple ID",           group: "Identity",
              paneID: "com.apple.systempreferences.AppleIDSettings"),
        Entry(alias: "icloud",           canonical: "Apple ID",           group: "Identity",
              paneID: "com.apple.systempreferences.AppleIDSettings"),
        Entry(alias: "account",          canonical: "Apple ID",           group: "Identity",
              paneID: "com.apple.systempreferences.AppleIDSettings"),

        Entry(alias: "passwords",        canonical: "Passwords",          group: "Identity",
              paneID: "com.apple.Passwords-Settings.extension"),
        Entry(alias: "keychain",         canonical: "Passwords",          group: "Identity",
              paneID: "com.apple.Passwords-Settings.extension"),
    ]

    /// Two-stage matcher: prefix first (instant), fuzzy fallback if zero
    /// prefix hits. The fuzzy budget scales with query length so 2-char
    /// nonsense can't fuzzy-route to a valid pane.
    func match(query rawQuery: String) -> [SearchResult] {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        // ─── Pass 1: prefix ───────────────────────────────────────────
        var seen: Set<String> = []
        var prefixHits: [Entry] = []
        for entry in Self.entries {
            guard entry.alias.hasPrefix(normalized) else { continue }
            // Dedupe by paneID so multiple aliases for the same pane
            // ("wifi" / "wi-fi" / "wireless") collapse into one row.
            guard !seen.contains(entry.paneID) else { continue }
            seen.insert(entry.paneID)
            prefixHits.append(entry)
        }
        if !prefixHits.isEmpty {
            return Self.render(entries: Array(prefixHits.prefix(8)), rankBase: 930)
        }

        // ─── Pass 2: fuzzy fallback ───────────────────────────────────
        let budget = FuzzyMatch.budget(for: normalized)
        guard budget > 0 else { return [] }
        seen.removeAll(keepingCapacity: true)
        var fuzzyHits: [(Entry, Int)] = []
        for entry in Self.entries {
            guard !seen.contains(entry.paneID) else { continue }
            if let dist = FuzzyMatch.levenshtein(
                normalized, entry.alias, budget: budget
            ) {
                seen.insert(entry.paneID)
                fuzzyHits.append((entry, dist))
            }
        }
        fuzzyHits.sort { $0.1 < $1.1 }
        return Self.render(
            entries: fuzzyHits.prefix(8).map { $0.0 },
            rankBase: 870
        )
    }

    private static func render(entries: [Entry], rankBase: Int) -> [SearchResult] {
        entries.enumerated().map { idx, entry in
            SearchResult(
                title: entry.canonical,
                subtitle: "Settings > \(entry.group)",
                source: .settings,
                date: nil,
                badge: nil,
                openTarget: .url("x-apple.systempreferences:\(entry.paneID)"),
                rank: rankBase - idx
            )
        }
    }

    /// True when the typed query equals one of our aliases exactly. Used
    /// by the ViewModel's exclusivity rule.
    func hasExactMatch(query rawQuery: String) -> Bool {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return false }
        return Self.entries.contains { $0.alias == normalized }
    }
}
