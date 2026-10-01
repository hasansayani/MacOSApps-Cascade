import Cocoa
import ApplicationServices
import CascadeCore

/// Drag-to-snap: while a window is being dragged with the snap modifier held, cascade groups are
/// highlighted; dropping the window over a group snaps it into that group's cascade.
final class DragSnapper {
    private let engine: Engine
    private let settings: () -> CascadeSettings
    private var monitors: [Any] = []
    private let overlay = SnapOverlay()

    private var dragging = false
    private var probed = false
    private var displays: [Display] = []
    private var dragged: (window: AXUIElement, origin: CGPoint)?
    private var hovered: (display: Display, target: DropTarget)?

    init(engine: Engine, settings: @escaping () -> CascadeSettings) {
        self.engine = engine
        self.settings = settings
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func reset() {
        dragging = false
        probed = false
        dragged = nil
        hovered = nil
        overlay.hide()
    }

    private func modifierHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        let required: NSEvent.ModifierFlags
        switch settings().snapModifier {
        case .shift: required = .shift
        case .control: required = .control
        case .option: required = .option
        case .command: required = .command
        }
        return flags.intersection(.deviceIndependentFlagsMask).contains(required)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
        case .leftMouseDragged:
            dragging = true
            updateOverlay(flags: event.modifierFlags)
        case .flagsChanged:
            if dragging { updateOverlay(flags: event.modifierFlags) }
        case .leftMouseUp:
            defer { reset() }
            guard let dragged, let hovered, modifierHeld(event.modifierFlags),
                  let now = dragged.window.frame?.origin, now != dragged.origin else { return }
            engine.snap(dragged.window, toGroup: hovered.target.index, settings: settings(), dropDisplay: hovered.display)
        default:
            break
        }
    }

    /// Identifies the window being dragged. Done lazily, only once the snap modifier is held, so
    /// ordinary drags (text selection, file drags) cost nothing. While a window is dragged the
    /// cursor stays on its title bar, so the window under the cursor is the dragged one.
    private func probeDraggedWindow() {
        guard !probed else { return }
        probed = true
        guard Permissions.isTrusted, let window = AXUIElement.window(at: Display.mouseLocation),
              window.pid != ProcessInfo.processInfo.processIdentifier,
              (window.attr(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              let origin = window.frame?.origin else { return }
        dragged = (window, origin)
        displays = Display.all()
    }

    private func updateOverlay(flags: NSEvent.ModifierFlags) {
        if modifierHeld(flags) { probeDraggedWindow() }
        guard dragged != nil, modifierHeld(flags) else {
            hovered = nil
            overlay.hide()
            return
        }
        let mouse = Display.mouseLocation
        guard let display = Display.containing(mouse, in: displays) else { overlay.hide(); return }
        let targets = engine.lastDropTargets[display.id]
            ?? Planner.plan(windows: [], area: display.visibleFrame, settings: settings()).dropTargets
        let target = targets.first { $0.region.contains(mouse) }
        hovered = target.map { (display, $0) }
        overlay.show(on: display, targets: targets, highlighted: target?.index)
    }
}

/// A click-through window that outlines cascade groups and highlights the drop target.
final class SnapOverlay {
    private var window: NSWindow?
    private let view = OverlayView()

    func show(on display: Display, targets: [DropTarget], highlighted: Int?) {
        let window = self.window ?? makeWindow()
        let frame = Display.cocoaRect(display.frame)
        if window.frame != frame { window.setFrame(frame, display: false) }
        view.update(origin: display.frame.origin, targets: targets, highlighted: highlighted)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = view
        window = w
        return w
    }
}

private final class OverlayView: NSView {
    private var origin = CGPoint.zero
    private var targets: [DropTarget] = []
    private var highlighted: Int?

    override var isFlipped: Bool { true }   // match AX top-left coordinates

    func update(origin: CGPoint, targets: [DropTarget], highlighted: Int?) {
        guard origin != self.origin || targets != self.targets || highlighted != self.highlighted else { return }
        self.origin = origin
        self.targets = targets
        self.highlighted = highlighted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for target in targets {
            let rect = target.region.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let isHot = target.index == highlighted
            NSColor.controlAccentColor.withAlphaComponent(isHot ? 0.22 : 0.06).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(isHot ? 0.9 : 0.35).setStroke()
            path.lineWidth = isHot ? 3 : 1.5
            path.stroke()

            let label = "Group \(target.index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isHot ? 22 : 15, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(isHot ? 1 : 0.6),
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
