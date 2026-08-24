import SwiftUI
import AppKit

/// Settings, in the same "Living Glass" grammar as onboarding. Two tabs at the
/// top switch the body between the shared HotkeySection (Shortcut) and
/// PermissionsSection (Permissions) — the exact same surfaces onboarding uses,
/// so there is one source of truth for both. The Permissions tab is the only
/// place tvara ever asks for access.
struct SettingsView: View {
    var onClose: () -> Void = {}
    /// Forwarded to PermissionsSection: called after a permission is granted so
    /// the app can start the source that just became available.
    var onPermissionsChanged: () -> Void = {}

    enum Tab: String, CaseIterable { case shortcut = "Shortcut", permissions = "Permissions" }

    @State private var tab: Tab = .shortcut
    @Namespace private var tabNS

    private let panelWidth: CGFloat = 620
    private let panelHeight: CGFloat = 460

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 26) {
                tabBar
                Group {
                    switch tab {
                    case .shortcut:    shortcutTab
                    case .permissions: permissionsTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .padding(.bottom, 44)

            closeButton
        }
        .frame(width: panelWidth, height: panelHeight)
        .glassSurface(cornerRadius: 20)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0)) { tab = t }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(tab == t ? .black.opacity(0.85) : .white.opacity(0.62))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            if tab == t {
                                Capsule().fill(Color.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "tab", in: tabNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCapsule(fallbackFill: 0.04, fallbackStroke: 0.18)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .glassCapsule(fallbackFill: 0.05, fallbackStroke: 0.22)
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    // MARK: Tabs

    private var shortcutTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(kicker: "Shortcut",
                   title: "Open tvara.",
                   subtitle: "Press this anywhere to summon the launcher.")
            HotkeySection()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(kicker: "Permissions",
                   title: "Access.",
                   subtitle: "Grant only what you want — nothing is asked until you tap.")
            PermissionsSection(onPermissionsChanged: onPermissionsChanged)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Mirrors onboarding's stepHeader so the two surfaces read identically.
    private func header(kicker: String, title: String, subtitle: String?) -> some View {
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
}
