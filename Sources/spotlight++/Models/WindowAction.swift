import Foundation

/// Discrete window-management presets we surface as launcher commands.
/// Each one resolves to an absolute AX rect (or a screen move) at execute
/// time against the previously-frontmost app's focused window.
///
/// v0 lineup: 14 actions across 4 groups (Halves / Quadrants / Thirds /
/// Display). Top/bottom halves, two-thirds, and almost-maximize were
/// trimmed to keep the table cleanly groupable as 2/4/3/N.
enum WindowAction: Hashable {
    // Halves (2-way vertical split)
    case leftHalf, rightHalf
    // Quadrants (4-way split)
    case topLeft, topRight, bottomLeft, bottomRight
    // Thirds (3-way vertical split)
    case leftThird, centerThird, rightThird
    // Display
    case maximize, minimize, center
    case nextDisplay, previousDisplay
}
