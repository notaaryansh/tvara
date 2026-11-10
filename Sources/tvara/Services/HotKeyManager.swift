import AppKit
import Carbon.HIToolbox

/// The global shortcut that opens tvara. Stored as a Carbon key code +
/// Carbon modifier mask (what `RegisterEventHotKey` takes) plus the label
/// shown on the key cap, so the UI never has to reverse-map a key code.
struct Hotkey: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let `default` = Hotkey(
        keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), keyLabel: "K"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags, keyLabel: String) {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(keyCode), modifiers: carbon, keyLabel: keyLabel)
    }

    /// Key caps in the standard macOS order: ⌃ ⌥ ⇧ ⌘ then the key.
    var chips: [String] {
        var out: [String] = []
        if modifiers & UInt32(controlKey) != 0 { out.append("⌃") }
        if modifiers & UInt32(optionKey)  != 0 { out.append("⌥") }
        if modifiers & UInt32(shiftKey)   != 0 { out.append("⇧") }
        if modifiers & UInt32(cmdKey)     != 0 { out.append("⌘") }
        out.append(keyLabel)
        return out
    }

    /// Inline form for sentences, e.g. "⌘K" or "⌥Space".
    var display: String { chips.joined() }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        return flags
    }
}

/// Owns the one global shortcut: registers it with Carbon (no Accessibility
/// permission needed), persists the user's choice, and tells the UI when it
/// changes.
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Posted on the main thread after the shortcut changes.
    static let didChange = Notification.Name("tvara.hotkeyDidChange")

    private static let defaultsKey = "hotkey.v1"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    /// The shortcut currently saved (and, unless suspended, registered).
    private(set) var current: Hotkey

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Hotkey.self, from: data) {
            current = saved
        } else {
            current = .default
        }
    }

    /// Install the press handler and register the saved shortcut. If the
    /// saved one can't be registered any more, fall back to the default so
    /// the app is never left without a way in.
    func start(handler: @escaping () -> Void) {
        self.handler = handler
        installEventHandlerIfNeeded()
        if !register(current), current != .default, register(.default) {
            current = .default
        }
    }

    /// Switch to a new shortcut. Returns false — leaving the previous one
    /// registered — if the system refuses it.
    @discardableResult
    func update(to hotkey: Hotkey) -> Bool {
        let previous = current
        guard register(hotkey) else {
            _ = register(previous)
            return false
        }
        current = hotkey
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    /// Temporarily release the shortcut so the picker can capture the same
    /// keys (a registered Carbon hotkey swallows the event before the app's
    /// own key monitor sees it).
    func suspend() { unregister() }

    func resume() { _ = register(current) }

    // MARK: - Carbon

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handler?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: fourCharCode("SPTL"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func fourCharCode(_ s: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in s.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
