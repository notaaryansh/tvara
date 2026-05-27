import AppKit
import Carbon.HIToolbox
import SwiftUI

final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SearchWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: SearchViewModel
    private var keyMonitor: Any?

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel

        let panel = SpotlightPanel(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
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
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none

        let root = SearchView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        super.init(window: panel)
        panel.delegate = self
        // Position once at init so the first show doesn't render at (0,0)
        // for a frame before snapping into place.
        repositionForCurrentScreen()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        guard let window else { return }
        repositionForCurrentScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        window?.orderOut(nil)
        viewModel.reset()
    }

    private func repositionForCurrentScreen() {
        guard let window, let screen = NSScreen.main else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        // Sit at roughly 1/4 from the top, like Spotlight.
        let y = visible.maxY - visible.height * 0.28 - size.height / 2
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow else { return event }

            // While the compose panel is showing, hand everything except
            // Escape (cancel) and ⌘↩ (send) through to SwiftUI so the
            // TextEditor + button shortcuts work natively.
            if self.viewModel.composeState != nil {
                switch Int(event.keyCode) {
                case kVK_Escape:
                    self.viewModel.cancelCompose()
                    return nil
                default:
                    return event
                }
            }

            switch Int(event.keyCode) {
            case kVK_Escape:
                // In acting mode without a compose panel yet, Esc backs out
                // of acting rather than dismissing the whole window.
                if self.viewModel.actingOn != nil {
                    self.viewModel.cancelCompose()
                    return nil
                }
                self.hide()
                return nil
            case kVK_DownArrow:
                self.viewModel.moveSelection(by: 1)
                return nil
            case kVK_UpArrow:
                self.viewModel.moveSelection(by: -1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // In acting mode the typed text is an action intent, not a
                // search query — submit it to the planner.
                if self.viewModel.actingOn != nil {
                    self.viewModel.submitActionIntent()
                    return nil
                }
                // ⌘↩ on a selected result enters acting mode instead of
                // opening it. Plain ↩ keeps the existing open-on-selected
                // behavior so the launcher still works the old way.
                if event.modifierFlags.contains(.command),
                   self.viewModel.results.indices.contains(self.viewModel.selectedIndex) {
                    let r = self.viewModel.results[self.viewModel.selectedIndex]
                    self.viewModel.beginActing(on: r)
                    return nil
                }
                if self.viewModel.openSelected() { self.hide() }
                return nil
            case kVK_Tab:
                let forward = !event.modifierFlags.contains(.shift)
                self.viewModel.cycleTab(forward: forward)
                return nil
            default:
                return event
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
