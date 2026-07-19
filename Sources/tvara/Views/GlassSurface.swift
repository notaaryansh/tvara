import AppKit
import SwiftUI

/// The single availability seam for Liquid Glass. On macOS 26+ this applies
/// the real `.glassEffect(...)` material; on Sonoma/Sequoia it degrades to the
/// existing `VisualEffectView` blur + hairline stroke — i.e. exactly today's
/// look. Every glass surface in the onboarding (panel shell, key-cap chips,
/// permission cards, buttons) routes through here so the `@available` gate
/// lives in one place instead of being sprinkled across the views.
///
/// Generic over the clip shape so the same seam covers rounded-rect panels
/// and capsule pills — see the `glassSurface`/`glassCapsule` conveniences.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    /// Optional glass tint (26+). Ignored on the fallback path.
    var tint: Color? = nil
    /// Reacts to cursor/press with live specular movement (26+). No-op on
    /// the fallback path.
    var interactive: Bool = false
    /// Fallback-only knobs so callers can match today's per-surface look.
    var fallbackMaterial: NSVisualEffectView.Material = .hudWindow
    var fallbackFill: Double = 0.0
    var fallbackStroke: Double = 0.22

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(glass(), in: shape)
        } else {
            content
                .background(shape.fill(Color.white.opacity(fallbackFill)))
                .background(VisualEffectView(material: fallbackMaterial, blendingMode: .behindWindow))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(fallbackStroke), lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private func glass() -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Liquid Glass surface (26+) clipped to a continuous rounded rect, with
    /// a graceful blur fallback. See `GlassSurface` for the parameter contract.
    func glassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackMaterial: NSVisualEffectView.Material = .hudWindow,
        fallbackFill: Double = 0.0,
        fallbackStroke: Double = 0.22
    ) -> some View {
        modifier(GlassSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint, interactive: interactive,
            fallbackMaterial: fallbackMaterial,
            fallbackFill: fallbackFill, fallbackStroke: fallbackStroke
        ))
    }

    /// Liquid Glass surface (26+) clipped to a capsule — for pill buttons and
    /// chips. Interactive by default since pills are almost always tappable.
    func glassCapsule(
        tint: Color? = nil,
        interactive: Bool = true,
        fallbackMaterial: NSVisualEffectView.Material = .hudWindow,
        fallbackFill: Double = 0.0,
        fallbackStroke: Double = 0.22
    ) -> some View {
        modifier(GlassSurface(
            shape: Capsule(style: .continuous),
            tint: tint, interactive: interactive,
            fallbackMaterial: fallbackMaterial,
            fallbackFill: fallbackFill, fallbackStroke: fallbackStroke
        ))
    }
}
