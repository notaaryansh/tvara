import AppKit
import Combine
import SwiftUI

/// Rectangle/Magnet-style live preview of the snap target. A borderless,
/// click-through translucent panel that floats over the real desktop at
/// whatever rect the currently-selected window-action row would snap to.
/// Hides whenever the selected row isn't a window action, or the panel
/// itself is closed.
@MainActor
final class WindowSnapOverlayController {
    private let viewModel: SearchViewModel
    private let windowService: WindowManagerService
    private var overlay: NSPanel?
    private var hostingView: NSHostingView<SnapOverlayView>?
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: SearchViewModel, windowService: WindowManagerService) {
        self.viewModel = viewModel
        self.windowService = windowService

        // Re-evaluate on any ViewModel change. `results` is now computed
        // off backing arrays, so we can't subscribe to it directly via
        // Publishers.CombineLatest — instead we listen on objectWillChange
        // (fires before any @Published mutates) and recompute synchronously
        // on the next runloop tick.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    /// Compute target rect from current selection; show or hide accordingly.
    private func update() {
        let results = viewModel.results
        let idx = viewModel.selectedIndex
        guard results.indices.contains(idx) else { hide(); return }
        let selected = results[idx]
        guard case .windowAction(let action) = selected.openTarget else {
            hide()
            return
        }
        guard let (_, rect) = windowService.previewRect(for: action) else {
            hide()
            return
        }
        show(rect: rect)
    }

    /// Lazy-create the panel on first show. Keeping it alive between shows
    /// means moving from one preset to another animates the frame instead
    /// of recreating the window.
    private func show(rect: CGRect) {
        if overlay == nil { buildPanel() }
        guard let panel = overlay else { return }

        if panel.isVisible {
            // Already on-screen — animate frame change for that satisfying
            // Magnet-style slide between presets.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else {
            panel.setFrame(rect, display: false)
            panel.orderFront(nil)
            // Re-assert layering each time: spotlight++ panel sits at
            // .floating, our overlay sits one level below so window-stack
            // order is always overlay-under-panel.
        }
    }

    private func hide() {
        guard let panel = overlay, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        // One level below the spotlight++ panel (.floating == 3) so the
        // overlay never covers the launcher itself, but still floats over
        // every other app's normal-level windows.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient
        ]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: SnapOverlayView())
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        hostingView = host

        overlay = panel
    }
}

/// The blue snap-zone rectangle. Translucent fill + thicker border so it
/// reads against any backdrop the user happens to have open.
private struct SnapOverlayView: View {
    var body: some View {
        // Match the Source.window steel-blue so the desktop overlay reads
        // as the same visual family as the row's icon/source pill.
        let tint = Color(red: 0.35, green: 0.55, blue: 0.75)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.92), lineWidth: 2.5)
            )
            .padding(6)
    }
}
