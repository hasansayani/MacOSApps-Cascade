import Cocoa
import Carbon.HIToolbox
import CascadeCore
import Combine

// MARK: - Settings persistence

/// Main-thread owner of the user's settings, persisted as JSON in UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    @Published var settings: CascadeSettings {
        didSet {
            // Assigning inside didSet does not re-trigger observers, so clamp then save once.
            let clean = settings.sanitized()
            if clean != settings { settings = clean }
            guard settings != oldValue else { return }
            save()
        }
    }

    private static let migrationKey = "settings.migration"

    private init() {
        var loaded = CascadeSettings()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(CascadeSettings.self, from: data) {
            loaded = decoded.sanitized()
        }
        // 2.0.1 defaulted to gathering every window onto one display. Windows now stay on their own
        // display; move existing settings over once (users can still opt back in).
        if UserDefaults.standard.integer(forKey: Self.migrationKey) < 1 {
            loaded.displayMode = .eachDisplay
            UserDefaults.standard.set(1, forKey: Self.migrationKey)
        }
        settings = loaded
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func resetToDefaults() { settings = CascadeSettings() }
}

// MARK: - Global hotkeys (Carbon: needs no extra permission)

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false
    /// Display strings of shortcuts macOS refused (usually taken by another app).
    private(set) static var failed: [String] = []

    static func register(id: UInt32, _ shortcut: Shortcut, _ handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4353_4344), id: id)   // 'CSCD'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        } else {
            failed.append(shortcut.displayString)
            log.error("could not register hotkey \(shortcut.displayString, privacy: .public) (status \(status))")
        }
    }

    static func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    static func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
        failed.removeAll()
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            DispatchQueue.main.async { HotKeys.handlers[hotKey.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Carbon modifier flags for AppKit modifier flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= Shortcut.cmdKey }
        if flags.contains(.option) { m |= Shortcut.optionKey }
        if flags.contains(.control) { m |= Shortcut.controlKey }
        if flags.contains(.shift) { m |= Shortcut.shiftKey }
        return m
    }

    static func appKitModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & Shortcut.cmdKey != 0 { f.insert(.command) }
        if carbon & Shortcut.optionKey != 0 { f.insert(.option) }
        if carbon & Shortcut.controlKey != 0 { f.insert(.control) }
        if carbon & Shortcut.shiftKey != 0 { f.insert(.shift) }
        return f
    }

    /// Readable label for a key code, e.g. "C", "F5", "Space".
    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(keyCode)] { return s }
        return (characters ?? "?").uppercased()
    }

    /// Menu key equivalent for a shortcut (lowercase character), when representable.
    static func keyEquivalent(_ shortcut: Shortcut?) -> String {
        guard let key = shortcut?.key, key.count == 1, key.unicodeScalars.first!.properties.isAlphabetic
                || key.unicodeScalars.first!.properties.numericType != nil else { return "" }
        return key.lowercased()
    }
}

extension NSMenuItem {
    func setShortcut(_ shortcut: Shortcut?) {
        keyEquivalent = HotKeys.keyEquivalent(shortcut)
        keyEquivalentModifierMask = shortcut.map { HotKeys.appKitModifiers($0.modifiers) } ?? []
    }
}
