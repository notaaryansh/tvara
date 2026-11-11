import Foundation

/// Debug aid: catches main-thread stalls as they happen.
///
/// Launch with `-hangWatch YES`. A background thread pings the main thread
/// every 100 ms; if a ping isn't answered within `threshold`, it runs
/// `/usr/bin/sample` against this process for two seconds and saves the
/// result to `~/Library/Logs/tvara/hang-<time>.txt`. The saved stacks show
/// exactly what the main thread was stuck in, without anyone having to
/// time a recording to the freeze. Inert unless the argument is passed.
enum HangWatch {
    private static let threshold: TimeInterval = 0.4

    static func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "hangWatch") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/tvara", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let thread = Thread {
            let pid = ProcessInfo.processInfo.processIdentifier
            let stamp = DateFormatter()
            stamp.dateFormat = "HHmmss"
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + threshold) == .timedOut {
                    let out = dir.appendingPathComponent("hang-\(stamp.string(from: Date())).txt")
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    task.arguments = ["\(pid)", "2", "2", "-file", out.path]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    try? task.run()
                    task.waitUntilExit()
                    NSLog("HangWatch: main thread stalled, saved %@", out.path)
                    // Wait for the stall to clear so one freeze = one file.
                    answered.wait()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "tvara.hangwatch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
