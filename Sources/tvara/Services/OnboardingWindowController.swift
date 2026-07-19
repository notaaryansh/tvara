import AppKit
import SwiftUI

final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Mock onboarding window. Same visual grammar as the search panel
/// (Living Glass direction): borderless, non-activating, vibrancy blur
/// behind a rounded rect. Unlike the search panel, does NOT hide on
/// resign key — the user may click into System Settings during real
/// permission grants and we don't want the panel disappearing on them.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user finishes onboarding, either via Skip or the
    /// final "Start using tvara" button. Caller flips a session flag so
    /// subsequent hotkey presses open the search panel instead.
    var onDismiss: (() -> Void)?

    init() {
        let panel = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        super.init(window: panel)
        panel.delegate = self

        let root = OnboardingView(
            onSkip: { [weak self] in self?.finish() },
            onFinish: { [weak self] in self?.finish() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        repositionForCurrentScreen()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        repositionForCurrentScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func finish() {
        hide()
        onDismiss?()
    }

    private func repositionForCurrentScreen() {
        guard let window, let screen = NSScreen.main else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        // Slightly above true center — same optical placement people
        // expect from a "moment" window on macOS.
        let y = visible.midY - size.height / 2 + visible.height * 0.05
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
