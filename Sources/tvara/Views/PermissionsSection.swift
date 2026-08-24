import SwiftUI
import AppKit

/// The permission list, shared by onboarding (step 2) and Settings (Permissions
/// tab) so both render the exact same rows. Each Grant button fires the real
/// system prompt for that ONE permission — never batched — then reflects the
/// result. Statuses refresh whenever the app regains focus, so granting
/// Accessibility / Full Disk out in System Settings flips the pill to "Granted"
/// when the user comes back.
struct PermissionsSection: View {
    /// Called after a permission is granted, so the app can start the source
    /// that just became available (SearchViewModel.startDataServices).
    var onPermissionsChanged: () -> Void = {}

    @State private var granted: [String: Bool] = [:]

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(PermissionsBootstrap.allPermissions, id: \.rawValue) { permission in
                    row(permission)
                }
            }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
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
                    .foregroundColor(.white.opacity(0.48))
            }
            Spacer()
            Button { grant(permission) } label: { pill(granted: isGranted) }
                .buttonStyle(.plain)
                .disabled(isGranted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassSurface(cornerRadius: 10, fallbackFill: 0.03, fallbackStroke: 0.08)
    }

    /// Granted → solid white affirmative pill. Ungranted → interactive glass.
    @ViewBuilder
    private func pill(granted: Bool) -> some View {
        let content = HStack(spacing: 6) {
            if granted {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
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
