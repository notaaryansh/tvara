import AppKit
import SwiftUI

final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// First-run onboarding window. Same visual grammar as the search panel
/// (Living Glass direction): borderless, non-activating, vibrancy blur
/// behind a rounded rect. Unlike the search panel, does NOT hide on
/// resign key — the user may click into System Settings during real
/// permission grants and we don't want the panel disappearing on them.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user leaves onboarding. `openSearch` is true when
    /// they finished via the last step's "Open tvara" button (so the caller
    /// should drop them straight into search) and false for the dev Skip.
    var onDismiss: ((_ openSearch: Bool) -> Void)?

    private var hosting: NSHostingView<OnboardingView>!

    init() {
        let panel = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: the glass is translucent and fills a rectangular
        // window, so AppKit can't derive the rounded silhouette and instead
        // draws a hard-cornered shadow around the full window rect — a visible
        // rectangular line that only appears while the panel is key. Grounding
        // via a window shadow needs a padded transparent window; not worth it.
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // The whole surface is designed as white-on-dark glass. Without
        // this, a Mac in Light mode gets light glass under white text.
        panel.appearance = NSAppearance(named: .darkAqua)

        super.init(window: panel)
        panel.delegate = self

        hosting = NSHostingView(rootView: makeRoot())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        repositionForCurrentScreen()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeRoot() -> OnboardingView {
        OnboardingView(
            onSkip: { [weak self] in self?.finish(openSearch: false) },
            onFinish: { [weak self] in self?.finish(openSearch: true) }
        )
    }

    func show() {
        guard let window else { return }
        // Already up (e.g. the shortcut was pressed mid-onboarding): just
        // bring it forward, don't lose the user's place.
        if window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Fresh presentation always starts at the first step.
        hosting.rootView = makeRoot()
        repositionForCurrentScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func finish(openSearch: Bool) {
        hide()
        onDismiss?(openSearch)
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
