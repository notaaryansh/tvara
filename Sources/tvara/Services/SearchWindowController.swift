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

        // BEFORE we steal focus, capture the app that was frontmost so
        // window-management commands target THAT app, not our own panel.
        // Skip ourselves and the loginwindow PID. Same critical timing
        // as the text-selection grab below — once NSApp.activate fires,
        // frontmostApplication is us.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let app = frontmost, app.processIdentifier != getpid() {
            viewModel.setWindowTarget(
                pid: app.processIdentifier,
                appName: app.localizedName
            )
        } else {
            viewModel.setWindowTarget(pid: nil, appName: nil)
        }

        // BEFORE we steal focus, try to grab whatever text the user has
        // selected in the frontmost app. If they have a selection, we
        // open straight into "acting mode" with that text as the context
        // — so they can say things like "send a summary of this to mikki"
        // about anything they're reading. If there's no selection, this
        // is a no-op (returns nil silently) and we open as normal search.
        let captured = TextSelectionCapture.grab()

        repositionForCurrentScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if let captured {
            viewModel.beginActingWithSelection(
                text: captured.text,
                sourceAppName: captured.sourceAppName
            )
        }
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
                // Hierarchical layer-pop: zoomed → deck → blended →
                // clear query → dismiss. The VM decides; controller only
                // acts on the .dismiss outcome.
                switch self.viewModel.handleEscape() {
                case .handled: break
                case .dismiss: self.hide()
                }
                return nil
            case kVK_DownArrow:
                if self.viewModel.viewMode == .deck {
                    self.viewModel.moveCardSelection(by: 1)
                } else {
                    self.viewModel.moveSelection(by: 1)
                }
                return nil
            case kVK_UpArrow:
                if self.viewModel.viewMode == .deck {
                    self.viewModel.moveCardSelection(by: -1)
                } else {
                    self.viewModel.moveSelection(by: -1)
                }
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // In acting mode the typed text is an action intent, not a
                // search query — submit it to the planner.
                if self.viewModel.actingOn != nil {
                    self.viewModel.submitActionIntent()
                    return nil
                }
                // Enter on a category card zooms into that category's full
                // list. From the zoomed list and from the blended list,
                // Enter opens the selected result as usual.
                if self.viewModel.viewMode == .deck {
                    self.viewModel.zoomSelectedCard()
                    return nil
                }
                // ⌘↩ on a selected result enters acting mode instead of
                // opening it. Plain ↩ keeps the existing open-on-selected
                // behavior so the launcher still works the old way.
                if event.modifierFlags.contains(.command),
                   self.viewModel.results.indices.contains(self.viewModel.selectedIndex) {
                    let r = self.viewModel.results[self.viewModel.selectedIndex]
                    // ⌘↩ on a collection row is meaningless (the row isn't
                    // an openable target). Fall through silently — let the
                    // user pick a thumb first with → before acting.
                    if case .imagesCollection = r.openTarget {
                        return nil
                    }
                    self.viewModel.beginActing(on: r)
                    return nil
                }
                // Photo collection row: row-level ↩ zooms into Images;
                // thumb-level ↩ opens the focused photo and dismisses.
                if self.viewModel.results.indices.contains(self.viewModel.selectedIndex),
                   case .imagesCollection(let photos)
                        = self.viewModel.results[self.viewModel.selectedIndex].openTarget {
                    if let thumbIdx = self.viewModel.selectedThumbIndex,
                       photos.indices.contains(thumbIdx) {
                        if self.viewModel.open(photos[thumbIdx]) { self.hide() }
                    } else {
                        self.viewModel.zoomToImagesFromCollection()
                    }
                    return nil
                }
                if self.viewModel.openSelected() { self.hide() }
                return nil
            case kVK_LeftArrow:
                // ← only does work on a collection row in the blended /
                // zoomed list — retreats focus through the thumb strip
                // and back to row-level. Pass through to SwiftUI on any
                // other row so cursor movement inside the search field
                // still works the normal way.
                if self.viewModel.viewMode != .deck,
                   self.viewModel.selectedPhotoCollection != nil,
                   self.viewModel.selectedThumbIndex != nil {
                    self.viewModel.retreatThumbSelection()
                    return nil
                }
                return event
            case kVK_RightArrow:
                // → enters / advances thumb focus on a collection row.
                // Same passthrough-on-other-rows policy as ←.
                if self.viewModel.viewMode != .deck,
                   self.viewModel.selectedPhotoCollection != nil {
                    self.viewModel.advanceThumbSelection()
                    return nil
                }
                return event
            case kVK_Tab:
                // Tab now toggles the category deck instead of cycling
                // the (now-removed) pill strip. Shift-Tab is reserved
                // for future "back to deck from zoomed" once we want
                // a distinct gesture; right now Esc does that job.
                self.viewModel.toggleDeck()
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
