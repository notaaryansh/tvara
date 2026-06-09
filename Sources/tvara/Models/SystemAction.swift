import Foundation

/// Discrete system-level actions: sleep, shut down, restart, lock screen,
/// log out. Surfaced as launcher commands but with stricter matching than
/// the other command sources — no Levenshtein fuzzy fallback, because a
/// typo of `shutdown` accidentally surfacing Shut Down would be a real
/// foot-gun.
enum SystemAction: Hashable {
    case sleep
    case shutDown
    case restart
    case lockScreen
    case logOut
}
