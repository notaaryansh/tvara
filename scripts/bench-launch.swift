#!/usr/bin/env swift
// Launch-time benchmark: how long each launcher takes from "open" until
// macOS reports it has finished launching (NSRunningApplication
// .isFinishedLaunching). Needs no special permissions.
//
//   swift scripts/bench-launch.swift "/Applications/Alfred 5.app" /Applications/Raycast.app ./tvara.app
//   swift scripts/bench-launch.swift --runs 7 <app> ...
//
// Each app is quit, then launched `--runs` times; the first launch is
// discarded (it warms the disk cache) and the median of the rest is printed.
import AppKit

var runs = 6
var paths: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--runs", !args.isEmpty { runs = max(2, Int(args.removeFirst()) ?? runs) } else { paths.append(a) }
}
guard !paths.isEmpty else { print("usage: bench-launch.swift [--runs N] <app> ..."); exit(2) }

func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func quit(_ bundleID: String) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        if !app.terminate() { app.forceTerminate() }
    }
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline,
          !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
        pump(0.05)
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.forceTerminate() }
    pump(1.0)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

print("| Launcher | Launch, median (ms) | Fastest (ms) | Slowest (ms) | Runs |")
print("| --- | ---: | ---: | ---: | ---: |")
for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
        print("| \(url.lastPathComponent) | not found | | | |"); continue
    }
    let name = (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
    var times: [Double] = []
    for run in 0..<runs {
        quit(id)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        let t0 = CFAbsoluteTimeGetCurrent()
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        var done: Double?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               app.isFinishedLaunching {
                done = CFAbsoluteTimeGetCurrent() - t0; break
            }
            pump(0.002)
        }
        if let done, run > 0 { times.append(done * 1000) }
        pump(1.5)
    }
    if times.isEmpty { print("| \(name) | did not finish launching | | | |"); continue }
    print(String(format: "| %@ | %.0f | %.0f | %.0f | %d |", name, median(times), times.min()!, times.max()!, times.count))
}
