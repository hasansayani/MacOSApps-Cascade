// Cascade — a menu bar utility that arranges windows in a classic Windows-style cascade.
//
// Windows are grouped by application, sized identically, and offset diagonally so every
// window's title bar and left edge stay visible and clickable.

import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// Private but long-stable API (used by Rectangle, AltTab, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Accessibility helpers

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var size: CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    func setFrame(_ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position → size → position: moving first avoids the size being clamped by the old
        // screen, and re-positioning fixes apps that shift the origin while resizing.
        set(kAXPositionAttribute, pos)
        if isSettable(kAXSizeAttribute) { set(kAXSizeAttribute, sz) }
        set(kAXPositionAttribute, pos)
    }
}

// MARK: - Window discovery

enum Scope {
    case visible        // on-screen windows on the current Space
    case all            // also minimized windows and windows of hidden apps
}

struct ManagedWindow {
    let element: AXUIElement
    let app: NSRunningApplication
    let appElement: AXUIElement
    let minimized: Bool
    let zRank: Int      // 0 = frontmost; larger = further back
}

enum WindowCollector {
    /// Returns windows grouped by app, ordered back-to-front (the frontmost app/window last),
    /// so cascading in this order leaves the current front window on top.
    static func collect(_ scope: Scope) -> [[ManagedWindow]] {
        let onScreen = onScreenWindowRanks()
        let me = ProcessInfo.processInfo.processIdentifier
        var groups: [[ManagedWindow]] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me {
            if app.isHidden && scope == .visible { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 1.0)
            guard let windows: [AXUIElement] = appElement.attr(kAXWindowsAttribute) else { continue }

            var group: [ManagedWindow] = []
            for window in windows {
                guard (window.attr(kAXRoleAttribute) as String?) == kAXWindowRole,
                      (window.attr(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
                      (window.attr("AXFullScreen") as Bool?) != true else { continue }
                if let size = window.size, size.width < 60 || size.height < 60 { continue }

                let minimized = (window.attr(kAXMinimizedAttribute) as Bool?) ?? false
                if minimized && scope == .visible { continue }

                var rank = Int.max
                if let id = window.windowID {
                    if let r = onScreen[id] {
                        rank = r
                    } else if !minimized && !app.isHidden && !onScreen.isEmpty {
                        continue    // not minimized, not hidden, yet off-screen → lives on another Space
                    }
                }
                group.append(ManagedWindow(element: window, app: app, appElement: appElement,
                                           minimized: minimized, zRank: rank))
            }
            if !group.isEmpty {
                groups.append(group.sorted { $0.zRank > $1.zRank })
            }
        }
        // App whose frontmost window is furthest back goes first.
        return groups.sorted { ($0.map(\.zRank).min() ?? .max) > ($1.map(\.zRank).min() ?? .max) }
    }

    /// CGWindowID → z-order rank among on-screen, normal-layer windows (0 = front).
    private static func onScreenWindowRanks() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var ranks: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() where (entry[kCGWindowLayer as String] as? Int) == 0 {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID { ranks[id] = index }
        }
        return ranks
    }
}

// MARK: - Layout

enum CascadeLayout {
    static let preferredStep: CGFloat = 34   // roughly one title bar
    static let minimumStep: CGFloat = 24     // still leaves a clickable strip
    static let minimumFraction: CGFloat = 0.55
    static let margin: CGFloat = 8

    /// Equal-sized frames stepping diagonally from the top-left of `area` (AX / top-left coordinates).
    /// When there are too many windows to fit, the cascade wraps back to the top-left, as Windows did.
    static func frames(count: Int, in screen: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let area = screen.insetBy(dx: margin, dy: margin)
        let travel = min(area.width, area.height) * (1 - minimumFraction)

        var step = preferredStep
        if count > 1 {
            step = max(minimumStep, min(preferredStep, travel / CGFloat(count - 1)))
        }
        let perCycle = max(1, min(count, Int(travel / step) + 1))
        let size = CGSize(width: area.width - CGFloat(perCycle - 1) * step,
                          height: area.height - CGFloat(perCycle - 1) * step)

        return (0..<count).map { i in
            let k = CGFloat(i % perCycle)
            return CGRect(origin: CGPoint(x: area.minX + k * step, y: area.minY + k * step), size: size)
        }
    }
}

// MARK: - Cascader

final class Cascader {
    private let queue = DispatchQueue(label: "cascade.worker", qos: .userInitiated)

    func cascade(_ scope: Scope) {
        guard Permissions.ensureTrusted() else { return }
        let area = Self.targetAreaAX()
        queue.async { Self.run(scope, area: area) }
    }

    /// Visible frame of the screen under the mouse, converted to AX (top-left origin) coordinates.
    private static func targetAreaAX() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let primaryHeight = NSScreen.screens[0].frame.height
        let vf = screen.visibleFrame
        return CGRect(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
    }

    private static func run(_ scope: Scope, area: CGRect) {
        let groups = WindowCollector.collect(scope)
        let windows = groups.flatMap { $0 }
        guard !windows.isEmpty else { NSSound.beep(); return }

        if scope == .all {
            var restored = false
            for group in groups where group[0].app.isHidden {
                group[0].appElement.set(kAXHiddenAttribute, kCFBooleanFalse)
                restored = true
            }
            for window in windows where window.minimized {
                window.element.set(kAXMinimizedAttribute, kCFBooleanFalse)
                restored = true
            }
            if restored { usleep(350_000) }   // let un-minimize animations settle
        }

        // Electron/Chrome apps animate frame changes while "enhanced UI" is on; turn it off temporarily.
        var enhanced: [AXUIElement] = []
        for group in groups {
            let app = group[0].appElement
            if (app.attr("AXEnhancedUserInterface") as Bool?) == true {
                app.set("AXEnhancedUserInterface", kCFBooleanFalse)
                enhanced.append(app)
            }
        }

        for (window, frame) in zip(windows, CascadeLayout.frames(count: windows.count, in: area)) {
            window.element.setFrame(frame)
        }

        // Stack back-to-front: bring each app forward, then raise its windows in order.
        for group in groups {
            group[0].appElement.set(kAXFrontmostAttribute, kCFBooleanTrue)
            usleep(40_000)
            for window in group {
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                usleep(8_000)
            }
        }
        if let front = windows.last {
            front.element.set(kAXMainAttribute, kCFBooleanTrue)
            front.element.set(kAXFocusedAttribute, kCFBooleanTrue)
        }

        for app in enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }
}

// MARK: - Permissions

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ensureTrusted() -> Bool {
        if isTrusted { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cascade needs Accessibility access"
        alert.informativeText = "Cascade moves and resizes other apps' windows, which macOS only allows "
            + "with Accessibility permission.\n\nOpen System Settings → Privacy & Security → Accessibility, "
            + "enable Cascade, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Global hotkeys (Carbon: no extra permission required)

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                DispatchQueue.main.async { HotKeys.handlers[hotKey.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4353_4344), id: id)   // 'CSCD'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        } else {
            NSLog("Cascade: could not register hotkey \(id) — it may be in use by another app")
        }
    }
}

// MARK: - Status bar icon

enum StatusIcon {
    /// Three cascaded windows with title bars, drawn as a template image so it adapts to the menu bar.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            let size = NSSize(width: 11, height: 9)
            for i in 0..<3 {
                let rect = NSRect(x: 1 + CGFloat(i) * 2.5, y: 1 + CGFloat(i) * 2.5, width: size.width, height: size.height)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
                // Erase whatever is underneath so back windows only show their exposed edges.
                NSGraphicsContext.current?.compositingOperation = .clear
                path.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                NSColor.black.setFill()
                path.lineWidth = 1.2
                path.stroke()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let cascader = Cascader()
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Cascade windows (⌃⌥C)"
        statusItem.menu = buildMenu()

        HotKeys.register(id: 1, keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in
            self?.cascader.cascade(.visible)
        }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            self?.cascader.cascade(.all)
        }

        Permissions.ensureTrusted()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let visible = NSMenuItem(title: "Cascade Visible Windows", action: #selector(cascadeVisible), keyEquivalent: "c")
        visible.keyEquivalentModifierMask = [.control, .option]
        let all = NSMenuItem(title: "Cascade All Windows (incl. Minimized)", action: #selector(cascadeAll), keyEquivalent: "c")
        all.keyEquivalentModifierMask = [.control, .option, .shift]
        [visible, all].forEach { $0.target = self; menu.addItem($0) }

        menu.addItem(.separator())
        permissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cascade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        permissionItem.isHidden = Permissions.isTrusted
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func cascadeVisible() { cascader.cascade(.visible) }
    @objc private func cascadeAll() { cascader.cascade(.all) }
    @objc private func grantAccess() { Permissions.ensureTrusted() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
