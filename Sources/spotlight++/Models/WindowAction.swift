import Foundation

/// Discrete window-management presets we surface as launcher commands.
/// Each one resolves to an absolute AX rect (or a screen move) at execute
/// time against the previously-frontmost app's focused window.
enum WindowAction: Hashable {
    // Halves
    case leftHalf, rightHalf, topHalf, bottomHalf
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    // Thirds
    case leftThird, centerThird, rightThird
    // Two-thirds
    case leftTwoThirds, rightTwoThirds
    // Whole-screen
    case maximize, almostMaximize, center
    // Multi-display
    case nextDisplay, previousDisplay
}
