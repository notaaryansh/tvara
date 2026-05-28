import Foundation
import ApplicationServices

/// Drive Spotify.app via AppleScript. Spotify has excellent AppleScript
/// support, so playback control is reliable — set shuffle, then `play
/// track <uri>`. The URI can be a track, album, or playlist; for our
/// use case it's a `spotify:playlist:<id>`.
///
/// First call triggers an Automation permission prompt; we warm it at
/// app launch alongside the other TCC-gated services.
enum SpotifyPlayer {
    enum PlayError: Error, CustomStringConvertible {
        case compileFailed
        case scriptError(String)
        var description: String {
            switch self {
            case .compileFailed:      return "AppleScript compile failed"
            case .scriptError(let s): return "Spotify AppleScript error: \(s)"
            }
        }
    }

    /// Synchronous — call from a detached task if you don't want to block.
    static func play(uri: String, shuffle: Bool = true) throws {
        let escUri = uri
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Order matters: set shuffling BEFORE play, otherwise the new
        // track starts playing in sequence and shuffles from the next one.
        // `activate` brings Spotify to the foreground so the user can see
        // their playlist (otherwise it'd play in the background only).
        let shuffleLine = shuffle ? "set shuffling to true" : ""
        let source = """
        tell application "Spotify"
            activate
            \(shuffleLine)
            play track "\(escUri)"
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw PlayError.compileFailed
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        if let err {
            let msg = (err["NSAppleScriptErrorMessage"] as? String)
                ?? (err["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "unknown error"
            throw PlayError.scriptError(msg)
        }
    }

    /// Trip the Automation TCC prompt at launch (without actually opening
    /// Spotify) so the first real play doesn't get blocked by an
    /// unexpected permission dialog mid-demo.
    static func warmAccess() {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client")
        guard let aeDescPtr = target.aeDesc else { return }
        _ = AEDeterminePermissionToAutomateTarget(
            aeDescPtr,
            typeWildCard,
            typeWildCard,
            true   // askUserIfNeeded
        )
    }
}
