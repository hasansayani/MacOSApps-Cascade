import Cocoa
import ApplicationServices

// Private but long-stable API (used by Rectangle, AltTab, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)   // hit-testing runs on the main thread
        return element
    }()

    func attr<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Fetches several attributes in one IPC round trip. Missing attributes come back as nil.
    func attrs(_ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let array = values as? [CFTypeRef], array.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return array.map { value in
            // Per-attribute failures are returned as AXValues of type .axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    var frame: CGRect? {
        let values = attrs([kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = values[0].flatMap(AXUIElement.point), let size = values[1].flatMap(AXUIElement.size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func point(_ value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    func setFrame(_ frame: CGRect, resizable: Bool) {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position → size → position: moving first avoids the size being clamped by the old
        // display, and re-positioning fixes apps that shift the origin while resizing.
        set(kAXPositionAttribute, pos)
        if resizable {
            set(kAXSizeAttribute, sz)
            set(kAXPositionAttribute, pos)
        }
    }

    /// The top-level window containing this element (or the element itself if it is a window).
    var containingWindow: AXUIElement? {
        if (attr(kAXRoleAttribute) as String?) == kAXWindowRole { return self }
        if let window: AXUIElement = attr(kAXWindowAttribute) { return window }
        var element: AXUIElement? = attr(kAXParentAttribute)
        for _ in 0..<32 {
            guard let current = element else { return nil }
            if (current.attr(kAXRoleAttribute) as String?) == kAXWindowRole { return current }
            element = current.attr(kAXParentAttribute)
        }
        return nil
    }

    /// The window at a point in AX (top-left origin) coordinates.
    static func window(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element?.containingWindow
    }

    /// The focused (or main) window of the application with this pid.
    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element.attr(kAXFocusedWindowAttribute) ?? element.attr(kAXMainWindowAttribute)
    }
}

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The system prompt is shown at most once per launch; repeating it never helps and is what
    /// made a stale grant look like an endless permission loop.
    private static var systemPromptShown = false

    /// Returns true if trusted; otherwise prompts once, then explains what to do.
    @discardableResult
    static func ensureTrusted(explain: Bool = true) -> Bool {
        if isTrusted { return true }
        if !systemPromptShown {
            systemPromptShown = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) { return true }
            return false   // the system dialog is up; don't stack our own alert on top of it
        }
        guard explain else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cascade needs Accessibility access"
        alert.informativeText = """
            Cascade moves and resizes other apps' windows, which macOS only allows with Accessibility permission.

            Open System Settings → Privacy & Security → Accessibility and turn on Cascade.

            If Cascade is already turned on but this message keeps appearing, the entry belongs to an \
            older copy of the app: select Cascade, remove it with the – button, then add \
            \(Bundle.main.bundlePath) again with +.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Screen geometry in AX (top-left origin) coordinates. Must be created on the main thread.
struct Display: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect

    static func all() -> [Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Display(id: id, frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame))
        }
    }

    /// Mouse location in AX coordinates.
    static var mouseLocation: CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: (NSScreen.screens.first?.frame.height ?? 0) - m.y)
    }

    static func containing(_ point: CGPoint, in displays: [Display]) -> Display? {
        displays.first { $0.frame.contains(point) }
    }

    /// Converts an AX rect to Cocoa (bottom-left origin) coordinates.
    static func cocoaRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
