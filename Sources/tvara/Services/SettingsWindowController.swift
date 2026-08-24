import AppKit
import SwiftUI

private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless glass panel hosting SettingsView — same visual grammar as the
/// onboarding panel so Settings reads as the same surface, not a stock sheet.
/// tvara is an accessory (LSUIElement) app, so show() activates the app first.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init(onPermissionsChanged: @escaping () -> Void) {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        super.init(window: panel)
        panel.delegate = self

        let root = SettingsView(
            onClose: { [weak self] in self?.hide() },
            onPermissionsChanged: onPermissionsChanged
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        recenter()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func recenter() {
        guard let window, let screen = NSScreen.main else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    // Esc closes the panel.
    override func cancelOperation(_ sender: Any?) { hide() }
}
