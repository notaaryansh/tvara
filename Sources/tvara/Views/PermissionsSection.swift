import SwiftUI
import AppKit

/// The permission list, shared by onboarding (step 2) and Settings (Permissions
/// tab) so both render the exact same rows. Each button asks for that ONE
/// permission — never batched — then reflects the result. Statuses refresh
/// whenever the app regains focus (and on a short poll while visible), so
/// allowing Accessibility / Full Disk Access out in System Settings flips the
/// pill to "Allowed" when the user comes back.
struct PermissionsSection: View {
    /// Called after a permission is granted, so the app can start the source
    /// that just became available (SearchViewModel.startDataServices).
    var onPermissionsChanged: () -> Void = {}

    @State private var granted: [String: Bool] = [:]
    /// The window hosting this view. The status poll only runs while it is
    /// on screen — the onboarding and Settings panels are hidden, not
    /// destroyed, so an unconditional timer kept probing TCC (including
    /// touching the Mail / Messages databases) every 1.5s for the whole
    /// life of the app.
    @State private var hostWindow: NSWindow?

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(PermissionsBootstrap.allPermissions, id: \.rawValue) { permission in
                    row(permission)
                }
            }
        }
        .background(WindowReader(window: $hostWindow))
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // Poll while the view is visible so a grant made in System Settings (or
        // via the system prompt) flips the pill within ~1.5s — the Settings
        // panel is non-activating, so we can't rely on focus events alone.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            guard hostWindow?.isVisible == true else { return }
            refresh()
        }
    }

    private func row(_ permission: PermissionsBootstrap.Permission) -> some View {
        let isGranted = granted[permission.rawValue] ?? false
        return HStack(spacing: 14) {
            Image(systemName: permission.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Text(permission.rationale)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { grant(permission) } label: {
                pill(granted: isGranted,
                     opensSettings: PermissionsBootstrap.needsSystemSettings(permission))
            }
            .buttonStyle(.plain)
            .disabled(isGranted)
            .accessibilityLabel(isGranted
                ? "\(permission.title), allowed"
                : (PermissionsBootstrap.needsSystemSettings(permission)
                    ? "Open System Settings to allow \(permission.title)"
                    : "Allow \(permission.title)"))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassSurface(cornerRadius: 10, fallbackFill: 0.03, fallbackStroke: 0.08)
    }

    /// Allowed → green affirmative pill with a check. Otherwise an
    /// interactive glass pill whose label says what the click will do:
    /// "Allow" when macOS can ask in place, "Open Settings" when the only
    /// route is the System Settings pane (so the jump is never a surprise).
    @ViewBuilder
    private func pill(granted: Bool, opensSettings: Bool) -> some View {
        if granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Allowed")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(red: 0.22, green: 0.65, blue: 0.40)))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            Text(opensSettings ? "Open Settings" : "Allow")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.90))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassCapsule(fallbackFill: 0.04, fallbackStroke: 0.22)
        }
    }

    private func grant(_ permission: PermissionsBootstrap.Permission) {
        Task { @MainActor in
            let wasGranted = PermissionsBootstrap.currentlyGranted(permission)
            let isGranted = await PermissionsBootstrap.request(permission)
            refresh()
            if isGranted {
                onPermissionsChanged()
            } else if !wasGranted {
                // notDetermined→denied, or already denied: the system won't
                // re-prompt, so open the exact Settings pane. The pill updates
                // on refocus once the user flips the toggle.
                PermissionsBootstrap.openSystemSettings(for: permission)
            }
        }
    }

    private func refresh() {
        for permission in PermissionsBootstrap.allPermissions {
            let value = PermissionsBootstrap.currentlyGranted(permission)
            withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                granted[permission.rawValue] = value
            }
        }
    }
}

/// Hands the hosting NSWindow back to SwiftUI so a view can tell whether
/// it is actually on screen.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
