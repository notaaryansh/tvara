import AppKit
import SwiftUI

/// First-run onboarding — "Living Glass" direction. Four steps: welcome,
/// shortcut, permissions, done. The shortcut and permissions steps embed the
/// shared HotkeySection / PermissionsSection views, so the Settings window
/// presents the identical surfaces (one source of truth, no duplication).
///
/// Voice: plain and specific. Say what a thing does, in the words macOS
/// itself uses ("shortcut", "Allow", "System Settings"), and never promise
/// something the step doesn't actually do.
struct OnboardingView: View {
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var stepIndex: Int

    /// `initialStep` exists for previews and layout snapshots; the app
    /// always starts at 0.
    init(initialStep: Int = 0, onSkip: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.onSkip = onSkip
        self.onFinish = onFinish
        _stepIndex = State(initialValue: initialStep)
    }
    /// The live shortcut, so the last step names the keys the user actually
    /// picked instead of a hardcoded ⌘K.
    @State private var hotkey: Hotkey = HotKeyManager.shared.current

    /// Entrance materialize — the panel scales + fades in on first appear
    /// rather than snapping in, so it reads as glass settling into place.
    @State private var appeared: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 12, y: 0)),
                removal: .opacity.combined(with: .offset(x: -12, y: 0))
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            topBar
            progressDots
        }
        .frame(width: panelWidth, height: panelHeight)
        .glassSurface(cornerRadius: 20)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .animation(.snappy(duration: 0.22, extraBounce: 0), value: stepIndex)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyManager.didChange)) { _ in
            hotkey = HotKeyManager.shared.current
        }
    }

    // MARK: - Overlays

    /// Back on the left (steps 1–3, also bound to Esc), dev skip on the right.
    private var topBar: some View {
        VStack {
            HStack {
                if stepIndex > 0 {
                    Button { stepIndex -= 1 } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.80))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .glassCapsule(fallbackStroke: 0.24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .transition(.opacity)
                }
                Spacer()
                // Dev-only escape hatch. Release builds ship without it.
                #if DEBUG
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
                #endif
            }
            .padding(14)
            Spacer()
        }
    }

    private var progressDots: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i == stepIndex ? Color.white.opacity(0.92) : Color.white.opacity(0.26))
                        .frame(width: i == stepIndex ? 20 : 6, height: 6)
                        .animation(.snappy(duration: 0.22, extraBounce: 0), value: stepIndex)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(stepIndex + 1) of \(totalSteps)")
            .padding(.bottom, 22)
        }
    }

    // MARK: - Step 0 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("tvara")
                .font(.system(size: 68, weight: .semibold, design: .default))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .tracking(-1.5)

            Text("Search your Mac from one shortcut.")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.white.opacity(0.86))

            Text("Apps, files, messages, mail, notes and photos. Plus quick actions, like snapping a window or sending a message.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.64))
                .lineSpacing(3)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                primaryButton(title: "Get started") { stepIndex = 1 }
                Text("Two quick steps.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 1 — Shortcut

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(kicker: "Shortcut",
                       title: "Choose your shortcut.",
                       subtitle: "Press it anywhere to open tvara.")
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
                       title: "Choose what tvara can use.",
                       subtitle: "All optional. You can change them any time in Settings.")
            PermissionsSection()
            Spacer(minLength: 0)
            primaryButton(title: "Continue") { stepIndex = 3 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 3 — Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                .accessibilityHidden(true)
                Text("You're all set.")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .tracking(-0.8)
            }

            Text("Press \(Text(hotkey.display).fontWeight(.semibold).foregroundColor(.white.opacity(0.95))) anywhere to open tvara. It also lives in your menu bar.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.70))
                .accessibilityLabel("Press \(hotkey.chips.joined(separator: " ")) anywhere to open tvara. It also lives in your menu bar.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Things to try".uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.60))
                ForEach(examples, id: \.query) { example in
                    HStack(spacing: 12) {
                        Text(example.query)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .glassSurface(cornerRadius: 7, fallbackFill: 0.05, fallbackStroke: 0.18)
                        Text(example.result)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.66))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)

            Spacer(minLength: 0)

            primaryButton(title: "Open tvara") {
                onFinish()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only suggest things that work with what the user has allowed, so the
    /// first thing they type never dead-ends on a missing permission.
    private var examples: [(query: String, result: String)] {
        var out: [(query: String, result: String)] = [
            ("safari", "opens an app"),
            ("appearance", "jumps to a System Settings pane"),
        ]
        if PermissionsBootstrap.currentlyGranted(.accessibility) {
            out.append(("left half", "snaps the window you were in"))
        }
        return out
    }

    // MARK: - Reusable pieces

    private func stepHeader(kicker: String, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.60))
            Text(title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.66))
            }
        }
    }

    /// The step's main action. Bound to Return so the whole flow can be
    /// driven from the keyboard — fitting for a keyboard launcher.
    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(.black.opacity(0.88))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.95)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .focusEffectDisabled()
    }
}
