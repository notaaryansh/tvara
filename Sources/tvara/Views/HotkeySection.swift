import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The hotkey picker, shared by onboarding (step 1) and Settings (Shortcut tab)
/// so both render the exact same surface. Click Edit → chips dissolve →
/// pulsing "Listening…" → press a combo → new chips morph in. Owns its own
/// capture state so it drops into any container unchanged.
struct HotkeySection: View {
    @State private var hotkeyChips: [String] = ["⌘", "K"]

    private enum HotkeyMode { case idle, listening, registered }
    @State private var hotkeyMode: HotkeyMode = .idle
    @State private var preListenMode: HotkeyMode = .idle
    /// Stashed chips from before Edit was clicked so Cancel/Esc can restore the
    /// previously registered combo instead of leaving the block empty.
    @State private var preListenChips: [String] = []
    @State private var keyMonitorToken: Any? = nil
    @State private var listeningPulse: Bool = false
    @State private var hotkeyHint: String? = nil

    /// Shared namespace so the key-cap chips morph (glass flows between shapes)
    /// as the captured combo changes during listening.
    @Namespace private var glassNS

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            chipsBlock
            rightColumn
            Spacer()
        }
        .frame(minHeight: 68)
        .onDisappear { removeMonitor() }
    }

    /// Chip block stays visible in every mode. During listening it fills live
    /// as modifiers are held; on the finalizing keypress the letter chip lands
    /// and mode flips to .registered.
    private var chipsBlock: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if hotkeyChips.isEmpty && hotkeyMode == .listening {
                    waitingPlaceholder
                        .transition(.opacity)
                } else {
                    ForEach(hotkeyChips, id: \.self) { chip in
                        keyCapChip(chip)
                            .glassMorphID(chip, in: glassNS)
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
    }

    /// Softly pulsing dashed slot shown while listening but no keys are held yet.
    private var waitingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
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

    /// Right column: subtitle line on top, action button below.
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
                    Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                    Text("Edit").font(.system(size: 11, weight: .medium))
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

    // MARK: - Capture

    private func startListening() {
        preListenMode = hotkeyMode
        preListenChips = hotkeyChips
        hotkeyHint = nil

        withAnimation(.snappy(duration: 0.32, extraBounce: 0)) { hotkeyMode = .listening }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { hotkeyChips = [] }

        if !listeningPulse {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                listeningPulse = true
            }
        }

        removeMonitor()
        keyMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            if event.type == .flagsChanged {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let chips = modifierChipList(for: mods)
                hotkeyHint = chips.count > 3 ? "2 or 3 keys only — release one." : nil
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                    hotkeyChips = chips
                }
                return nil
            }

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

            hotkeyHint = nil
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { hotkeyChips = chips }
            removeMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.snappy(duration: 0.30, extraBounce: 0)) { hotkeyMode = .registered }
                listeningPulse = false
            }
            return nil
        }
    }

    private func cancelListening() {
        removeMonitor()
        hotkeyHint = nil
        listeningPulse = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { hotkeyChips = preListenChips }
        withAnimation(.snappy(duration: 0.30, extraBounce: 0)) { hotkeyMode = preListenMode }
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
}
