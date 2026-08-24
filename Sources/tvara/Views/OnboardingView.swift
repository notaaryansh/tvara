import AppKit
import SwiftUI

/// First-run onboarding — "Living Glass" direction. Four steps: welcome, hotkey
/// picker, permissions, done. The hotkey and permissions steps embed the shared
/// HotkeySection / PermissionsSection views, so the Settings window can present
/// the identical surfaces (one source of truth, no duplication).
struct OnboardingView: View {
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var stepIndex: Int = 0

    /// Entrance materialize — the panel scales + fades in on first appear
    /// rather than snapping in, so it reads as glass settling into place.
    @State private var appeared: Bool = false

    private let totalSteps = 4
    private let panelWidth: CGFloat = 680
    private let panelHeight: CGFloat = 540

    var body: some View {
        ZStack {
            Group {
                switch stepIndex {
                case 0: welcomeStep
                case 1: hotkeyStep
                case 2: permissionsStep
                default: doneStep
                }
            }
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 72)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 12, y: 0)),
                removal: .opacity.combined(with: .offset(x: -12, y: 0))
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dev-only escape hatch. Release builds ship without it — users
            // complete onboarding via the final "Start using tvara" button.
            #if DEBUG
            skipButton
            #endif
            progressDots
        }
        .frame(width: panelWidth, height: panelHeight)
        .glassSurface(cornerRadius: 20)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .animation(.snappy(duration: 0.22, extraBounce: 0), value: stepIndex)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    // MARK: - Overlays

    #if DEBUG
    private var skipButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onSkip) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.85))
                            .frame(width: 5, height: 5)
                        Text("Skip (dev)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassCapsule(fallbackStroke: 0.28)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
            Spacer()
        }
    }
    #endif

    private var progressDots: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i == stepIndex ? Color.white.opacity(0.92) : Color.white.opacity(0.18))
                        .frame(width: i == stepIndex ? 20 : 6, height: 6)
                        .animation(.snappy(duration: 0.22, extraBounce: 0), value: stepIndex)
                }
            }
            .padding(.bottom, 22)
        }
    }

    // MARK: - Step 0 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("tvara")
                .font(.system(size: 68, weight: .semibold, design: .default))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .tracking(-1.5)

            Text("Search anything. Instantly.")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.white.opacity(0.72))

            Spacer(minLength: 0)

            primaryButton(title: "Get started") {
                stepIndex = 1
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 1 — Hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(kicker: "Shortcut",
                       title: "Pick how you open tvara.",
                       subtitle: nil)
            HotkeySection()
            Spacer(minLength: 0)
            primaryButton(title: "Continue") { stepIndex = 2 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 2 — Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(kicker: "Permissions",
                       title: "A few things tvara needs.",
                       subtitle: "Grant now, or later from Settings.")
            PermissionsSection()
            Spacer(minLength: 0)
            primaryButton(title: "Continue") { stepIndex = 3 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 3 — Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 44, height: 44)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                }
                Text("You're set.")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .tracking(-0.8)
            }

            Text("Press ")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.62))
            + Text("⌘K")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
            + Text(" anywhere to open tvara. It'll be waiting.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.62))

            Spacer(minLength: 0)

            primaryButton(title: "Start using tvara") {
                onFinish()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Reusable pieces

    private func stepHeader(kicker: String, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.55))
            Text(title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .tracking(-0.5)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.88))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.95)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
