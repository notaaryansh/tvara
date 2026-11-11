#!/usr/bin/env swift
// Launcher speed benchmark: tvara vs Alfred vs Raycast vs Spotlight.
//
//   swift scripts/bench-launchers.swift                 # defaults below
//   swift scripts/bench-launchers.swift --trials 15 --query saf --expect Safari
//   swift scripts/bench-launchers.swift --hotkey raycast=ctrl+space
//   swift scripts/bench-launchers.swift --skip spotlight   # leave one out
//
// For every launcher that is running it repeats, `--trials` times:
//   1. press the launcher's shortcut           → time until its window is on screen
//   2. type the query                          → time from the LAST keystroke until
//                                                a result containing `--expect` is
//                                                readable in the window
//   3. press Esc to close, pause, repeat
// and prints a Markdown table of medians.
//
// Requirements
//   • The terminal running this needs Accessibility permission (System
//     Settings › Privacy & Security › Accessibility): it posts keystrokes
//     and reads each launcher's window through the Accessibility API.
//   • Each launcher must be running, past its onboarding, and bound to the
//     shortcut listed in `defaultHotkeys` (override with --hotkey).
//     Alfred and Raycast both default to ⌥Space; give one a different key.
//   • Don't touch the keyboard or mouse while it runs.
//
// Reading the numbers
//   Result detection polls the Accessibility tree, so each reading is
//   quantised to one poll (the median cost of a poll is reported per
//   launcher). Differences
//   smaller than that are noise. The same method is used for every launcher.

import AppKit
import ApplicationServices

// MARK: - Configuration

struct Launcher {
    let name: String
    let bundleID: String
    var hotkey: String
}

var launchers = [
    Launcher(name: "tvara",     bundleID: "com.aaryansh.tvara",            hotkey: "cmd+k"),
    Launcher(name: "Alfred",    bundleID: "com.runningwithcrayons.Alfred", hotkey: "opt+space"),
    Launcher(name: "Raycast",   bundleID: "com.raycast.macos",             hotkey: "ctrl+space"),
    Launcher(name: "Spotlight", bundleID: "com.apple.Spotlight",           hotkey: "cmd+space"),
]

var trials = 10
var query = "saf"
var expect = "Safari"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { fatalError("missing value for \(flag)") }
    let value = args.removeFirst()
    switch flag {
    case "--trials": trials = Int(value) ?? trials
    case "--query":  query = value
    case "--expect": expect = value
    case "--hotkey":
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let i = launchers.firstIndex(where: { $0.name.lowercased() == parts[0].lowercased() })
        else { fatalError("--hotkey expects name=combo, e.g. raycast=ctrl+space") }
        launchers[i].hotkey = parts[1]
    case "--skip":
        launchers.removeAll { $0.name.lowercased() == value.lowercased() }
    default: fatalError("unknown option \(flag)")
    }
}

// MARK: - Keys

let keyCodes: [String: CGKeyCode] = [
    "space": 49, "k": 40, "return": 36, "escape": 53,
    "a": 0, "s": 1, "d": 2, "f": 3, "j": 38, "l": 37, "p": 35, "o": 31,
]

func parseHotkey(_ s: String) -> (CGKeyCode, CGEventFlags) {
    var flags: CGEventFlags = []
    var code: CGKeyCode?
    for part in s.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command":  flags.insert(.maskCommand)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "shift":           flags.insert(.maskShift)
        default:
            guard let c = keyCodes[part] else { fatalError("unknown key '\(part)' in \(s)") }
            code = c
        }
    }
    guard let code else { fatalError("no key in hotkey '\(s)'") }
    return (code, flags)
}

let source = CGEventSource(stateID: .hidSystemState)

func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

/// Type one character without depending on the keyboard layout.
func type(_ ch: Character) {
    let utf16 = Array(String(ch).utf16)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
        e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        e?.post(tap: .cghidEventTap)
    }
}

// MARK: - Observation

func now() -> Double { CFAbsoluteTimeGetCurrent() }

/// True when `pid` owns an on-screen floating window big enough to be its
/// panel (filters out menu-bar status items and ordinary windows).
func panelVisible(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              (b["Width"] ?? 0) > 300, (b["Height"] ?? 0) > 40,
              ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
              // Launcher panels float above normal windows (layer > 0).
              // Requiring that keeps an open Settings or preferences
              // window (layer 0) from being mistaken for the panel.
              ((w[kCGWindowLayer as String] as? Int) ?? 0) > 0
        else { continue }
        return true
    }
    return false
}

let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

/// Depth-first search of the launcher's windows for any non-input element
/// whose text contains `needle`. Bounded so a huge tree can't stall a poll.
func resultVisible(_ app: AXUIElement, needle: String) -> Bool {
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
    var stack = windows
    var visited = 0
    while let el = stack.popLast(), visited < 600 {
        visited += 1
        let role = attribute(el, kAXRoleAttribute) as? String ?? ""
        if !textRoles.contains(role) {
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = attribute(el, name) as? String,
                   s.range(of: needle, options: .caseInsensitive) != nil {
                    return true
                }
            }
        }
        if let kids = attribute(el, kAXChildrenAttribute) as? [AXUIElement] {
            stack.append(contentsOf: kids)
        }
    }
    return false
}

/// Poll `condition` until it is true or `timeout` passes. Returns the
/// elapsed seconds, or nil on timeout.
func waitFor(timeout: Double, _ condition: () -> Bool) -> Double? {
    let start = now()
    while now() - start < timeout {
        if condition() { return now() - start }
        usleep(500)
    }
    return nil
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func ms(_ seconds: Double) -> String {
    seconds.isNaN ? "–" : String(format: "%.0f", seconds * 1000)
}

// MARK: - Run

func fail(_ message: String) -> Never {
    print(message)
    exit(2)
}
if trials < 1 { fail("--trials must be at least 1") }
if query.isEmpty || expect.isEmpty { fail("--query and --expect must not be empty") }
if query.count >= expect.count,
   expect.range(of: query, options: .caseInsensitive) != nil || query.caseInsensitiveCompare(expect) == .orderedSame {
    fail("--query must be shorter than --expect so the typed text itself isn't counted as a result")
}

guard AXIsProcessTrusted() else {
    print("""
    This terminal doesn't have Accessibility permission.
    Add it in System Settings › Privacy & Security › Accessibility, then run again.
    """)
    exit(1)
}

print("Query \"\(query)\" → expecting \"\(expect)\", \(trials) trials each (first one discarded as warm-up).\n")
print("| Launcher | Shortcut | Open panel (ms) | First result (ms) | Median poll (ms) | Misses |")
print("| --- | --- | ---: | ---: | ---: | ---: |")

for launcher in launchers {
    guard let running = NSRunningApplication
        .runningApplications(withBundleIdentifier: launcher.bundleID).first
    else {
        print("| \(launcher.name) | \(launcher.hotkey) | not running | | | |")
        continue
    }
    let pid = running.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    let (code, flags) = parseHotkey(launcher.hotkey)

    var opens: [Double] = []
    var results: [Double] = []
    var polls: [Double] = []
    var misses = 0

    /// Esc twice, then wait for the panel to be gone, so every trial
    /// starts from a closed launcher.
    func closePanel() {
        press(53); usleep(80_000); press(53)
        _ = waitFor(timeout: 2) { !panelVisible(pid) }
        usleep(400_000)
    }
    if panelVisible(pid) { closePanel() }

    for trial in 0...trials {          // trial 0 is the warm-up
        press(code, flags: flags)
        guard let tOpen = waitFor(timeout: 2, { panelVisible(pid) }) else {
            // The panel may still show up late. Give it a moment and close
            // it, or the next shortcut press would toggle it shut and every
            // later trial would type into the wrong state.
            usleep(500_000)
            if panelVisible(pid) { closePanel() }
            if trial > 0 { misses += 1 }
            continue
        }
        usleep(150_000)                // let the panel take focus

        for ch in query { type(ch); usleep(1_000) }
        let typed = now()

        var trialPolls: [Double] = []
        let found = waitFor(timeout: 3) {
            let t = now()
            let hit = resultVisible(app, needle: expect)
            trialPolls.append(now() - t)
            return hit
        }
        let tResult = found.map { _ in now() - typed }

        closePanel()

        guard trial > 0 else { continue }
        opens.append(tOpen)
        polls.append(contentsOf: trialPolls)
        if let tResult { results.append(tResult) } else { misses += 1 }
    }

    print("| \(launcher.name) | \(launcher.hotkey) | \(ms(median(opens))) | \(ms(median(results))) | \(ms(median(polls))) | \(misses) |")
}

print("\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
