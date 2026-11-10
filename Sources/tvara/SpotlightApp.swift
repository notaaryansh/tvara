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

    /// Persisted once the user finishes (or dev-skips) onboarding. Until
    /// then the shortcut and the menu-bar "Open tvara" item both lead to
    /// the onboarding panel; afterwards they open search.
    private static let onboardingDoneKey = "hasCompletedOnboarding"
    private var hasSeenOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingDoneKey) }
    }
    private var openMenuItem: NSMenuItem?

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
        onboardingController.onDismiss = { [weak self] openSearch in
            guard let self else { return }
            self.hasSeenOnboarding = true
            // Start whatever data services are ALREADY permitted. Nothing here
            // prompts — startDataServices only warms sources whose permission
            // is already granted (see SearchViewModel.startDataServices).
            self.viewModel.startDataServices()
            // "Open tvara" on the last step does what it says.
            if openSearch { self.windowController.toggle() }
        }

        // Settings window. Granting a permission here re-runs startDataServices
        // so the newly-allowed source starts without a relaunch.
        settingsController = SettingsWindowController { [weak self] in
            self?.viewModel.startDataServices()
        }

        // Registers the user's saved shortcut (⌘K until they pick another).
        HotKeyManager.shared.start { [weak self] in
            self?.handleHotkey()
        }
        NotificationCenter.default.addObserver(
            forName: HotKeyManager.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncOpenMenuItemShortcut() }
        }

        installMenu()
        installStatusItem()

        if hasSeenOnboarding {
            // Returning user: sources start at launch. This used to wait for
            // onboarding to be dismissed, which happened again every launch.
            viewModel.startDataServices()
        } else {
            // First launch: tvara has no Dock icon and no window, so show
            // onboarding right away instead of waiting for a shortcut the
            // user hasn't been told about yet.
            onboardingController.show()
        }
    }

    /// Persistent menu-bar presence. Clicking the "t" drops a menu — the user
    /// chooses Open / Settings / Quit from there. (⌘K still opens search
    /// directly without touching the menu.)
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeMenuBarIcon()

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open tvara",
                                action: #selector(openSearch), keyEquivalent: "")
        openMenuItem = open
        syncOpenMenuItemShortcut()
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear search history",
                     action: #selector(clearSearchHistory), keyEquivalent: "")
        #if DEBUG
        menu.addItem(withTitle: "Show onboarding (dev)",
                     action: #selector(showOnboarding), keyEquivalent: "")
        #endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit tvara",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Assigning the menu makes a click (left or right) drop it automatically.
        item.menu = menu
        self.statusItem = item
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

    @objc private func clearSearchHistory() {
        viewModel.clearSelectionHistory()
    }

    /// Show the user's real shortcut next to "Open tvara". Menu key
    /// equivalents are single characters, so shortcuts on keys without one
    /// (F-keys, arrows…) simply show no hint.
    private func syncOpenMenuItemShortcut() {
        guard let item = openMenuItem else { return }
        let hotkey = HotKeyManager.shared.current
        let label = hotkey.keyLabel
        let key: String
        switch label {
        case "Space": key = " "
        case "↩":     key = "\r"
        case "⇥":     key = "\t"
        default:      key = label.count == 1 ? label.lowercased() : ""
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : hotkey.cocoaModifiers
    }

    /// Same route as the shortcut, so the menu can't bypass onboarding and
    /// land in a search panel whose sources were never started.
    @objc private func openSearch() {
        handleHotkey()
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
