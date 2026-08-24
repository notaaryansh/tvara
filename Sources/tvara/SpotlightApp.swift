import AppKit
import Carbon.HIToolbox

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: SearchWindowController!
    private var viewModel: SearchViewModel!
    private var overlayController: WindowSnapOverlayController!
    private var statusItem: NSStatusItem!
    private var onboardingController: OnboardingWindowController!
    private var settingsController: SettingsWindowController!

    /// Session-only flag while the onboarding is still a mock. Every
    /// launch, the first ⌘K opens the onboarding panel; Skip / Finish
    /// flips this so subsequent presses open the real search panel.
    /// Swap for `@UserDefaults` once the flow is wired up for real.
    private var hasSeenOnboarding: Bool = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Permissions are NOT requested here anymore. Firing every TCC dialog
        // at launch ambushed the user with a stack of prompts before they'd
        // seen any UI. Each permission is now requested from the onboarding
        // "Permissions" step, when the user taps "Grant" on its row (see
        // PermissionsBootstrap.request + OnboardingView). The ⌘K hotkey uses
        // Carbon RegisterEventHotKey, which needs no Accessibility grant, so
        // onboarding is reachable before anything is granted.

        // Use the tvara "t" icon anywhere the app's icon is shown at runtime —
        // permission dialogs, NSAlerts (e.g. PermissionsBootstrap's "needs
        // access" popup), the About panel. The bundle already carries
        // AppIcon.icns; this makes sure the in-process icon matches it too.
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }

        // Build the window service ONCE and share between the view model
        // (it owns the captured PID + match/execute) and the overlay
        // controller (it reads previewRect from the same captured PID).
        // If we let them default-init separately each would have its own
        // empty `targetPID` and the overlay would never show.
        let windowService = WindowManagerService()
        viewModel = SearchViewModel(windowService: windowService)
        windowController = SearchWindowController(viewModel: viewModel)
        overlayController = WindowSnapOverlayController(
            viewModel: viewModel, windowService: windowService
        )

        onboardingController = OnboardingWindowController()
        onboardingController.onDismiss = { [weak self] in
            self?.hasSeenOnboarding = true
            // Start whatever data services are ALREADY permitted. Nothing here
            // prompts — startDataServices only warms sources whose permission
            // is already granted (see SearchViewModel.startDataServices).
            self?.viewModel.startDataServices()
        }

        // Settings window. Granting a permission here re-runs startDataServices
        // so the newly-allowed source starts without a relaunch.
        settingsController = SettingsWindowController { [weak self] in
            self?.viewModel.startDataServices()
        }

        HotKeyManager.shared.register(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            self?.handleHotkey()
        }

        installMenu()
        installStatusItem()
    }

    /// Persistent menu bar presence. Left-click opens the search panel
    /// (same as ⌘K); right-click shows a menu with Open + Quit so the app
    /// can be fully terminated without going through `killall`.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeMenuBarIcon()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Open tvara",
                     action: #selector(openSearch),
                     keyEquivalent: "k")
        menu.items.last?.keyEquivalentModifierMask = [.command]
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit tvara",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        // Attach via menu property only on demand so left-click can do its
        // own thing — we set/clear it inside statusItemClicked.
        item.menu = nil
        self.statusItem = item
        // Stash the menu on the item via associated object pattern would be
        // overkill; instead build it again in the handler. It's cheap.
    }

    /// Menu-bar icon: the tvara "t" in Georgia bold-italic (matching the app
    /// icon's Fraunces-style serif). Rendered as a TEMPLATE image, so macOS
    /// tints it to match the menu bar — white on a dark bar, black on a light
    /// one — instead of being locked to one colour. (Template images key off
    /// the glyph's alpha, so the fill colour here is only a mask.)
    private static func makeMenuBarIcon() -> NSImage {
        let font = NSFont(name: "Georgia-BoldItalic", size: 16)
            ?? NSFont.systemFont(ofSize: 16, weight: .bold)
        let str = NSAttributedString(string: "t", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        let textSize = str.size()
        let size = NSSize(width: ceil(textSize.width) + 4, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            )
            str.draw(at: origin)
            return true
        }
        image.isTemplate = true   // macOS tints to the menu bar (white on dark)
        image.accessibilityDescription = "tvara"
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            windowController.toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open tvara  ⌘K",
                     action: #selector(openSearch),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettings),
                     keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear search history",
                     action: #selector(clearSearchHistory),
                     keyEquivalent: "")
        #if DEBUG
        menu.addItem(withTitle: "Show onboarding (dev)",
                     action: #selector(showOnboarding),
                     keyEquivalent: "")
        #endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit tvara",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach so the next plain click opens the panel instead of the menu.
        statusItem.menu = nil
    }

    @objc private func clearSearchHistory() {
        viewModel.clearSelectionHistory()
    }

    @objc private func openSearch() {
        windowController.toggle()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    private func handleHotkey() {
        if hasSeenOnboarding {
            windowController.toggle()
        } else {
            onboardingController.show()
        }
    }

    @objc private func showOnboarding() {
        onboardingController.show()
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        // App menu (Quit)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit tvara",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // Edit menu — wires ⌘X/⌘C/⌘V/⌘A to the focused text field via the
        // responder chain. Without this, the system has no menu binding to
        // dispatch these standard actions even though the text field would
        // happily handle them.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete",
                         action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
