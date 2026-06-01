import SwiftUI

/// Schematic of where a `WindowAction` will place the focused window. Used
/// twice per row: a small (36×22) version as the row icon, and a larger
/// version in the trailing area when the row is selected so the user sees
/// the snap target before pressing ↩.
struct WindowActionPreview: View {
    let action: WindowAction
    /// Inner screen dimensions. 16:10 keeps it Mac-display-shaped.
    var screenSize: CGSize = CGSize(width: 36, height: 22)

    var body: some View {
        Group {
            switch action {
            case .nextDisplay, .previousDisplay:
                multiDisplayPreview
            default:
                singleScreenPreview
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    private var singleScreenPreview: some View {
        let rect = targetRect(in: screenSize)
        return ZStack(alignment: .topLeading) {
            screenChrome
                .frame(width: screenSize.width, height: screenSize.height)
            windowChip
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private var multiDisplayPreview: some View {
        let gap: CGFloat = 2
        let each = (screenSize.width - gap) / 2
        let targetIsRight = action == .nextDisplay
        // Show the window centered on the destination display at ~60% size
        // — purely illustrative; runtime size comes from the window itself.
        let winW = each * 0.6
        let winH = screenSize.height * 0.6
        let winX = targetIsRight
            ? (each + gap) + (each - winW) / 2
            : (each - winW) / 2
        let winY = (screenSize.height - winH) / 2

        return ZStack(alignment: .topLeading) {
            HStack(spacing: gap) {
                screenChrome.frame(width: each, height: screenSize.height)
                screenChrome.frame(width: each, height: screenSize.height)
            }
            windowChip
                .frame(width: winW, height: winH)
                .offset(x: winX, y: winY)
        }
    }

    /// The "display" — dark fill + thin highlight border. No menu-bar
    /// detail at 22px tall; would just be visual noise.
    private var screenChrome: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.black.opacity(0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
            )
    }

    /// The "window" — steel-blue tint matching Source.window so the preview
    /// reads as part of the same visual family as the row's source color.
    private var windowChip: some View {
        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
            .fill(SearchResult.Source.window.tint.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
            )
    }

    /// Compute the target rect inside the screen, in screen-local coords.
    /// Matches the geometry in WindowManagerService.rect(for:on:) so the
    /// preview is a faithful preview, not a hand-drawn approximation.
    private func targetRect(in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch action {
        case .leftHalf:        return CGRect(x: 0,         y: 0,       width: w/2,    height: h)
        case .rightHalf:       return CGRect(x: w/2,       y: 0,       width: w/2,    height: h)
        case .topHalf:         return CGRect(x: 0,         y: 0,       width: w,      height: h/2)
        case .bottomHalf:      return CGRect(x: 0,         y: h/2,     width: w,      height: h/2)
        case .topLeft:         return CGRect(x: 0,         y: 0,       width: w/2,    height: h/2)
        case .topRight:        return CGRect(x: w/2,       y: 0,       width: w/2,    height: h/2)
        case .bottomLeft:      return CGRect(x: 0,         y: h/2,     width: w/2,    height: h/2)
        case .bottomRight:     return CGRect(x: w/2,       y: h/2,     width: w/2,    height: h/2)
        case .leftThird:       return CGRect(x: 0,         y: 0,       width: w/3,    height: h)
        case .centerThird:     return CGRect(x: w/3,       y: 0,       width: w/3,    height: h)
        case .rightThird:      return CGRect(x: 2*w/3,     y: 0,       width: w/3,    height: h)
        case .leftTwoThirds:   return CGRect(x: 0,         y: 0,       width: 2*w/3,  height: h)
        case .rightTwoThirds:  return CGRect(x: w/3,       y: 0,       width: 2*w/3,  height: h)
        case .maximize:        return CGRect(x: 0,         y: 0,       width: w,      height: h)
        case .almostMaximize:
            // Visual margin scales with the preview size so the inset is
            // perceptible even on the small icon variant.
            let m = max(w * 0.08, 1.5)
            return CGRect(x: m, y: m, width: w - 2*m, height: h - 2*m)
        case .center:
            // Center preset preserves the window's existing size at runtime;
            // we don't know what that is, so render a representative 62%
            // centered block.
            let cw = w * 0.62, ch = h * 0.62
            return CGRect(x: (w - cw)/2, y: (h - ch)/2, width: cw, height: ch)
        case .nextDisplay, .previousDisplay:
            return .zero  // handled by multiDisplayPreview
        }
    }
}
