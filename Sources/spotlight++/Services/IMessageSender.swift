import Foundation

/// Send an iMessage by driving Messages.app via AppleScript. Requires the
/// user to grant Automation permission for spotlight++ → Messages on first
/// use (one-time TCC prompt). Throws on script failure or compile error.
///
/// Handle should be the iMessage-recognised identifier: phone like
/// "+15551234567" or email like "person@icloud.com". We don't do contact
/// resolution here — callers pass the resolved handle.
enum IMessageSender {
    enum SendError: Error, CustomStringConvertible {
        case compileFailed
        case scriptError(String)

        var description: String {
            switch self {
            case .compileFailed:        return "AppleScript compile failed"
            case .scriptError(let s):   return "AppleScript error: \(s)"
            }
        }
    }

    /// Synchronous — should be called from a background queue if you don't
    /// want to block the caller. The AppleScript itself returns quickly
    /// (~100-300ms) once Messages.app has been opened once.
    static func send(to handle: String, text: String) throws {
        let escHandle = handle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let source = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escHandle)" of targetService
            send "\(escText)" to targetBuddy
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw SendError.compileFailed
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        if let err {
            let msg = (err["NSAppleScriptErrorMessage"] as? String)
                ?? (err["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "unknown error"
            throw SendError.scriptError(msg)
        }
    }
}
