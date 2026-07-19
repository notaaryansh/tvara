import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Mock onboarding — "Living Glass" direction. Permissions still visual-only,
/// but the hotkey step now really listens: click Edit → chips dissolve →
/// pulsing "Listening…" bubble → press a combo → new chips animate in.
struct OnboardingView: View {
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var stepIndex: Int = 0
    @State private var permissionGranted: [String: Bool] = [:]
    @State private var hotkeyChips: [String] = ["⌘", "K"]

    // Hotkey capture state machine. `preListenMode` remembers where we
    // came from so Esc during listening restores it rather than
    // wiping the previously registered shortcut.
    private enum HotkeyMode { case idle, listening, registered }
    @State private var hotkeyMode: HotkeyMode = .idle
    @State private var preListenMode: HotkeyMode = .idle
    @State private var keyMonitorToken: Any? = nil
    @State private var listeningPulse: Bool = false
    @State private var hotkeyHint: String? = nil

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

            skipButton
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

            HStack(alignment: .center, spacing: 20) {
                chipsBlock
                rightColumn
                Spacer()
            }
            .frame(minHeight: 68)

            Spacer(minLength: 0)

            primaryButton(title: "Continue") {
                cancelListening()
                stepIndex = 2
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { removeMonitor() }
    }

    /// Chip block stays visible in every mode. During listening it fills
    /// live as modifiers are held; on the finalizing keypress the letter
    /// chip lands and mode flips to .registered.
    private var chipsBlock: some View {
        HStack(spacing: 10) {
            if hotkeyChips.isEmpty && hotkeyMode == .listening {
                waitingPlaceholder
                    .transition(.opacity)
            } else {
                ForEach(hotkeyChips, id: \.self) { chip in
                    keyCapChip(chip)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.55).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        ))
                }
            }
        }
        .frame(minWidth: 130, minHeight: 62, alignment: .leading)
        .animation(.spring(response: 0.34, dampingFraction: 0.62), value: hotkeyChips)
    }

    /// Softly pulsing dashed slot shown while listening but no keys are
    /// held yet — visual anchor so the block doesn't collapse.
    private var waitingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .foregroundColor(.white.opacity(listeningPulse ? 0.38 : 0.16))
            .frame(width: 54, height: 54)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(listeningPulse ? 0.85 : 0.35))
                    .frame(width: 6, height: 6)
            )
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: listeningPulse)
    }

    /// Right column: subtitle line on top, action button below. Content
    /// swaps in-place per mode so the layout stays anchored.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
                .frame(maxWidth: 400, alignment: .leading)
                .animation(.snappy(duration: 0.24, extraBounce: 0), value: hotkeyMode)
                .animation(.snappy(duration: 0.20, extraBounce: 0), value: hotkeyHint)
            actionButton
                .animation(.snappy(duration: 0.28, extraBounce: 0), value: hotkeyMode)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch hotkeyMode {
        case .idle:
            Text("Cmd+Space is taken by Spotlight — ⌘K is our default.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        case .registered:
            Text("Registered — you can summon tvara with your keyboard hotkey.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    listeningDot
                    Text("Listening")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                }
                Text(hotkeyHint ?? "press any combination — Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(hotkeyHint == nil ? 0.44 : 0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listeningDot: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 14, height: 14)
                .scaleEffect(listeningPulse ? 1.5 : 1.0)
                .opacity(listeningPulse ? 0.0 : 0.85)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 6, height: 6)
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder private var actionButton: some View {
        switch hotkeyMode {
        case .idle, .registered:
            Button(action: startListening) {
                HStack(spacing: 5) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.80))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .glassCapsule(fallbackStroke: 0.28)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.90)))
        case .listening:
            Button(action: cancelListening) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassCapsule(fallbackStroke: 0.20)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.90)))
        }
    }

    private func keyCapChip(_ chip: String) -> some View {
        Text(chip)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.95))
            .frame(minWidth: 54, minHeight: 54)
            .padding(.horizontal, 14)
            .glassSurface(cornerRadius: 12, fallbackFill: 0.06, fallbackStroke: 0.28)
    }

    // MARK: - Hotkey capture

    /// Stashed chips from before Edit was clicked so Cancel/Esc can
    /// restore the previously registered combo instead of leaving the
    /// block empty.
    @State private var preListenChips: [String] = []

    private func startListening() {
        preListenMode = hotkeyMode
        preListenChips = hotkeyChips
        hotkeyHint = nil

        // Chips clear so the user sees them fill live as they press.
        // Wrap in the same spring so the exit staggers naturally.
        withAnimation(.snappy(duration: 0.32, extraBounce: 0)) {
            hotkeyMode = .listening
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            hotkeyChips = []
        }

        // Kick off the placeholder pulse. Guard against re-entry.
        if !listeningPulse {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                listeningPulse = true
            }
        }

        removeMonitor()
        keyMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            // ── modifier-only edits: keep the preview live ────────────
            if event.type == .flagsChanged {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let chips = modifierChipList(for: mods)
                if chips.count > 3 {
                    hotkeyHint = "2 or 3 keys only — release one."
                } else {
                    hotkeyHint = nil
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                    hotkeyChips = chips
                }
                return nil
            }

            // ── key press ─────────────────────────────────────────────
            if Int(event.keyCode) == kVK_Escape {
                cancelListening()
                return nil
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var chips = modifierChipList(for: mods)
            guard !chips.isEmpty else {
                hotkeyHint = "Hold at least one modifier (⌘, ⌥, ⌃, or ⇧)."
                return nil
            }
            guard let keyChip = keyChipLabel(for: event) else { return nil }
            chips.append(keyChip)
            if chips.count > 3 {
                hotkeyHint = "2 or 3 keys only — release one and try again."
                return nil
            }

            // Success — animate the final chip in, then flip to registered
            // after a beat so the spring is visible before the status
            // line swaps to "Registered".
            hotkeyHint = nil
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                hotkeyChips = chips
            }
            removeMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.snappy(duration: 0.30, extraBounce: 0)) {
                    hotkeyMode = .registered
                }
                listeningPulse = false
            }
            return nil
        }
    }

    private func cancelListening() {
        removeMonitor()
        hotkeyHint = nil
        listeningPulse = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            hotkeyChips = preListenChips
        }
        withAnimation(.snappy(duration: 0.30, extraBounce: 0)) {
            hotkeyMode = preListenMode
        }
    }

    private func removeMonitor() {
        if let token = keyMonitorToken {
            NSEvent.removeMonitor(token)
            keyMonitorToken = nil
        }
    }

    private func modifierChipList(for mods: NSEvent.ModifierFlags) -> [String] {
        var chips: [String] = []
        if mods.contains(.control) { chips.append("⌃") }
        if mods.contains(.option)  { chips.append("⌥") }
        if mods.contains(.shift)   { chips.append("⇧") }
        if mods.contains(.command) { chips.append("⌘") }
        return chips
    }

    private func keyChipLabel(for event: NSEvent) -> String? {
        let specials: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "↩",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        if let s = specials[Int(event.keyCode)] { return s }
        if let chars = event.charactersIgnoringModifiers?.uppercased(),
           !chars.isEmpty, chars != " " {
            return chars
        }
        return nil
    }

    // MARK: - Step 2 — Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(kicker: "Permissions",
                       title: "A few things tvara needs.",
                       subtitle: "Grant now, or later from Settings.")

            GlassGroup(spacing: 8) {
                VStack(spacing: 8) {
                    permissionRow(id: "accessibility", symbol: "hand.tap",
                                  name: "Accessibility",
                                  why: "Global hotkey and text injection")
                    permissionRow(id: "contacts", symbol: "person.crop.circle",
                                  name: "Contacts",
                                  why: "Look up people by name for iMessage & email")
                    permissionRow(id: "automation", symbol: "app.connected.to.app.below.fill",
                                  name: "Automation",
                                  why: "Send iMessages and create calendar events")
                    permissionRow(id: "fulldisk", symbol: "internaldrive",
                                  name: "Full Disk Access",
                                  why: "Index files beyond Documents & Downloads")
                }
            }

            Spacer(minLength: 0)

            primaryButton(title: "Continue") {
                stepIndex = 3
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(id: String, symbol: String, name: String, why: String) -> some View {
        let granted = permissionGranted[id] ?? false
        return HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Text(why)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.48))
            }

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.24, extraBounce: 0.15)) {
                    permissionGranted[id] = !granted
                }
            } label: {
                grantPillLabel(granted: granted)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassSurface(cornerRadius: 10, fallbackFill: 0.03, fallbackStroke: 0.08)
    }

    /// Granted → solid white affirmative pill (deliberate high contrast so a
    /// completed grant reads at a glance). Ungranted → interactive glass, so
    /// the actionable state is the one that shimmers under the cursor.
    @ViewBuilder
    private func grantPillLabel(granted: Bool) -> some View {
        let content = HStack(spacing: 6) {
            if granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            Text(granted ? "Granted" : "Grant")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(granted ? .black.opacity(0.85) : .white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)

        if granted {
            content
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        } else {
            content.glassCapsule(fallbackFill: 0.04, fallbackStroke: 0.22)
        }
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
            .background(
                Capsule().fill(Color.white.opacity(0.95))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
