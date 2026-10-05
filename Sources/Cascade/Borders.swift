import Cocoa
import ApplicationServices
import CascadeCore

// MARK: - Icon colors

/// The colors that stand out in an app's icon.
struct IconColors {
    /// Dominant hues (0..<1), most prominent first. Empty for a gray or monochrome icon.
    let hues: [Double]
    let saturation: Double
    let brightness: Double

    /// Samples the icon at 32×32 and histograms the hue of its colorful pixels.
    static func sample(_ icon: NSImage) -> IconColors {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return IconColors(hues: [], saturation: 0, brightness: 0)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sinSum = [Double](repeating: 0, count: bins)
        var cosSum = [Double](repeating: 0, count: bins)
        var satSum = 0.0, briSum = 0.0, total = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard s > 0.28, b > 0.3 else { continue }   // ignore grays, whites and shadows
                let w = Double(s * b)
                let bin = min(Int(h * CGFloat(bins)), bins - 1)
                weight[bin] += w
                sinSum[bin] += w * sin(Double(h) * 2 * .pi)
                cosSum[bin] += w * cos(Double(h) * 2 * .pi)
                satSum += w * Double(s); briSum += w * Double(b); total += w
            }
        }
        // Colorful pixels must cover a meaningful part of the icon.
        guard total > 6 else { return IconColors(hues: [], saturation: 0, brightness: 0) }
        let strongest = weight.max() ?? 0
        let hues = weight.indices
            .filter { weight[$0] >= strongest * 0.15 }
            .sorted { weight[$0] > weight[$1] }
            .map { i -> Double in
                let angle = atan2(sinSum[i], cosSum[i]) / (2 * .pi)
                return angle < 0 ? angle + 1 : angle
            }
        return IconColors(hues: hues, saturation: satSum / total, brightness: briSum / total)
    }
}

// MARK: - Controller

/// Draws a colored outline around every app window, colored per app.
///
/// One click-through overlay per display paints all borders. Windows are painted back to front, and each
/// window first erases what is behind it, so a border never shows on top of a window in front of it.
/// Updates are event driven (Accessibility notifications, app and Space changes, dragging), with a slow
/// safety refresh for changes macOS doesn't announce.
final class BorderController {
    private var settings = CascadeSettings()
    private var running = false
    private var overlays: [CGDirectDisplayID: BorderOverlay] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var safetyTimer: Timer?
    private var dragTimer: Timer?
    private var refreshPending = false

    /// Regular (Dock) apps by pid, and the Dock's pid. Cached: querying NSRunningApplication properties
    /// is a LaunchServices round trip, far too slow to repeat on every refresh.
    private struct AppInfo {
        let key: String
        let name: String
        let app: NSRunningApplication
    }
    private var regularApps: [pid_t: AppInfo] = [:]
    private var dockPID: pid_t?

    private var iconColors: [String: IconColors] = [:]
    private var hues: [String: Double] = [:]
    /// Last computed app colors, for the Settings swatches.
    private(set) var currentColors: [(name: String, color: NSColor)] = []
    static let colorsDidChange = Notification.Name("CascadeBorderColorsChanged")

    func apply(_ settings: CascadeSettings) {
        let styleChanged = settings.borderStyle != self.settings.borderStyle
        self.settings = settings
        if settings.bordersEnabled && Permissions.isTrusted { start() } else { stop() }
        if styleChanged { hues.removeAll() }
        refreshSoon()
    }

    // MARK: Lifecycle

    private func start() {
        guard !running else { return }
        running = true
        rebuildOverlays()
        let center = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in workspaceEvents {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSoon(followUps: true)
            })
        }
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observe(app) }
            self?.reloadApps()
            self?.refreshSoon(followUps: true)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observers.removeValue(forKey: app.processIdentifier).map(Self.detach)
            }
            self?.reloadApps()
            self?.refreshSoon()
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
            self?.refreshSoon()
        })
        reloadApps()
        NSWorkspace.shared.runningApplications.forEach(observe)

        // Follow windows smoothly while anything is dragged; stop shortly after the mouse is released.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            event.type == .leftMouseDragged ? self?.beginDragTracking() : self?.endDragTracking()
        }
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        safetyTimer?.tolerance = 0.5
        refresh()
    }

    private func stop() {
        guard running else { return }
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        observers.values.forEach(Self.detach)
        observers.removeAll()
        mouseMonitor.map(NSEvent.removeMonitor)
        mouseMonitor = nil
        safetyTimer?.invalidate()
        dragTimer?.invalidate()
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        currentColors = []
        NotificationCenter.default.post(name: Self.colorsDidChange, object: nil)
    }

    private func reloadApps() {
        let apps = NSWorkspace.shared.runningApplications
        regularApps = Dictionary(apps.filter { $0.activationPolicy == .regular }.map { app in
            (app.processIdentifier, AppInfo(key: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                            name: app.localizedName ?? "App", app: app))
        }, uniquingKeysWith: { a, _ in a })
        dockPID = apps.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
    }

    private func rebuildOverlays() {
        let displays = Display.all()
        for (id, overlay) in overlays where !displays.contains(where: { $0.id == id }) {
            overlay.close()
            overlays[id] = nil
        }
        for display in displays {
            let overlay = overlays[display.id] ?? BorderOverlay()
            overlay.place(on: display)
            overlays[display.id] = overlay
        }
    }

    // MARK: Accessibility notifications

    private static let notifications = [
        kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<BorderController>.fromOpaque(refcon).takeUnretainedValue().refreshSoon(followUps: true)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private static func detach(_ observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: Refresh scheduling

    /// Coalesces bursts of events into one refresh on the next run loop pass. Window animations
    /// (open, minimize, restore) end after the event fires, so `followUps` re-checks shortly after.
    func refreshSoon(followUps: Bool = false) {
        guard running else { return }
        if !refreshPending {
            refreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.refreshPending = false
                self?.refresh()
            }
        }
        if followUps {
            for delay in [0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
            }
        }
    }

    private func beginDragTracking() {
        guard running, dragTimer == nil else { return }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Stop on our own if the mouse-up was missed (e.g. released over Cascade's own windows).
            guard NSEvent.pressedMouseButtons & 1 != 0 else { self?.endDragTracking(); return }
            self?.refresh()
        }
    }

    private func endDragTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
        refreshSoon(followUps: true)
    }

    // MARK: Painting

    private struct WindowInfo {
        let pid: pid_t
        let frame: CGRect
        let isTarget: Bool
    }

    private func refresh() {
        guard running else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = regularApps
        let dock = dockPID

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        let displays = Display.all()
        var windows: [WindowInfo] = []   // front to back
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me, pid != dock,
                  let layer = entry[kCGWindowLayer as String] as? Int, (0..<25).contains(layer),
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05 else { continue }
            // Skip transparent full-screen overlays from other utilities; they would erase every border.
            if layer > 0, displays.contains(where: { $0.frame.intersection(frame).area >= $0.frame.area * 0.95 }) { continue }
            let isTarget = layer == 0 && regular[pid] != nil && frame.width >= 60 && frame.height >= 60
            windows.append(WindowInfo(pid: pid, frame: frame, isTarget: isTarget))
        }

        let colors = colorsForApps(in: windows, regular: regular)
        let backToFront = Array(windows.reversed())
        for display in displays {
            guard let overlay = overlays[display.id] else { continue }
            let items = backToFront.filter { $0.frame.intersects(display.frame.insetBy(dx: -20, dy: -20)) }
                .map { BorderOverlay.Item(frame: $0.frame, color: $0.isTarget ? colors[$0.pid] : nil) }
            overlay.update(items: items, style: settings.borderStyle, width: CGFloat(settings.borderWidth))
        }
    }

    /// pid → border color, distinct per app among the apps that currently have windows.
    private func colorsForApps(in windows: [WindowInfo], regular: [pid_t: AppInfo]) -> [pid_t: NSColor] {
        // Front-most apps first: they get first pick of their icon colors.
        var order: [pid_t] = []
        for w in windows where w.isTarget && !order.contains(w.pid) { order.append(w.pid) }

        var result: [pid_t: NSColor] = [:]
        if settings.borderStyle == .custom {
            let c = settings.borderCustomColor
            let color = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
            order.forEach { result[$0] = color }
        } else {
            func key(_ pid: pid_t) -> String { regular[pid]?.key ?? "pid:\(pid)" }
            let candidates = order.map { pid -> (key: String, candidates: [Double]) in
                let k = key(pid)
                if iconColors[k] == nil { iconColors[k] = IconColors.sample(regular[pid]?.app.icon ?? NSImage()) }
                return (k, iconColors[k]!.hues)
            }
            hues = BorderPalette.assignHues(apps: candidates, previous: hues)
            for pid in order {
                let hue = hues[key(pid)] ?? 0
                let sampled = iconColors[key(pid)]
                switch settings.borderStyle {
                case .natural:
                    let s = min(max(sampled?.saturation ?? 0.7, 0.55), 0.9)
                    let b = min(max(sampled?.brightness ?? 0.9, 0.75), 0.95)
                    result[pid] = NSColor(hue: hue, saturation: s, brightness: b, alpha: 1)
                case .vibrant, .highContrast:
                    result[pid] = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
                case .custom:
                    break
                }
            }
        }

        let swatches = order.compactMap { pid in
            result[pid].map { (name: regular[pid]?.name ?? "App", color: $0) }
        }
        if swatches.map(\.name) != currentColors.map(\.name) || zip(swatches, currentColors).contains(where: { $0.color != $1.color }) {
            currentColors = swatches
            NotificationCenter.default.post(name: Self.colorsDidChange, object: nil)
        }
        return result
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

#if DEBUG
extension BorderController {
    /// Debug-only: renders the borders for the current window layout of the main display to a PNG
    /// (windows drawn as gray boxes underneath), and prints each app's sampled and assigned color.
    func renderSnapshot(to url: URL, settings: CascadeSettings) {
        var s = settings
        s.bordersEnabled = true
        self.settings = s
        running = true
        reloadApps()
        let display = Display.all()[0]
        let overlay = BorderOverlay()
        overlays[display.id] = overlay
        refresh()
        for (k, c) in iconColors.sorted(by: { $0.key < $1.key }) {
            print(k, "icon hues:", c.hues.prefix(3).map { Int($0 * 360) }, "→ assigned:", hues[k].map { Int($0 * 360) } ?? -1)
        }
        overlay.snapshot(size: display.frame.size, to: url)
    }

    /// Debug-only: average cost of the steps of one refresh.
    func timeRefresh() {
        running = true
        reloadApps()
        func ms(_ n: Int = 200, _ body: () -> Void) -> String {
            let t = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { body() }
            return String(format: "%.3f ms", Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 / Double(n))
        }
        print("CGWindowListCopyWindowInfo:", ms { _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) })
        print("runningApplications+filter:", ms { _ = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier) })
        print("Display.all:", ms { _ = Display.all() })
        print("full refresh:", ms { refresh() })
    }
}

extension BorderOverlay {
    func snapshot(size: CGSize, to url: URL) {
        let view = window.contentView!
        view.frame = CGRect(origin: .zero, size: size)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        // Paint a desktop-like background and gray windows under the borders for context.
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.55, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
            return true
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let borders = NSImage(size: size)
        borders.addRepresentation(rep)
        let final = NSImage(size: size, flipped: false) { r in
            image.draw(in: r)
            (view as? BorderView)?.drawWindowsForSnapshot(height: size.height)
            borders.draw(in: r)
            return true
        }
        let out = NSBitmapImageRep(data: final.tiffRepresentation!)!
        try? out.representation(using: .png, properties: [:])!.write(to: url)
    }
}
#endif

// MARK: - Overlay

/// A transparent, click-through window covering one display.
final class BorderOverlay {
    struct Item: Equatable {
        let frame: CGRect      // global top-left coordinates
        let color: NSColor?    // nil: an occluding window without a border
    }

    fileprivate let window: NSWindow
    private let view = BorderView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .none   // keep borders out of screenshots and screen recordings
        window.contentView = view
    }

    func place(on display: Display) {
        view.origin = display.frame.origin
        window.setFrame(Display.cocoaRect(display.frame), display: false)
        window.orderFrontRegardless()
    }

    func update(items: [Item], style: BorderStyle, width: CGFloat) {
        view.update(items: items, style: style, width: width)
    }

    func close() {
        window.orderOut(nil)
    }
}

private final class BorderView: NSView {
    var origin = CGPoint.zero
    private var items: [BorderOverlay.Item] = []
    private var style = BorderStyle.natural
    private var width: CGFloat = 3

    /// Window corner radius: macOS 26 (Tahoe) and later round window corners more.
    private static let cornerRadius: CGFloat =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10

    override var isFlipped: Bool { true }

    #if DEBUG
    /// Draws the windows as light boxes (back to front), in unflipped coordinates of `height`.
    func drawWindowsForSnapshot(height: CGFloat) {
        for item in items {
            let r = item.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let flipped = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
            NSColor(white: item.color == nil ? 0.8 : 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: flipped, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: flipped.minX, y: flipped.maxY - 28, width: flipped.width, height: 28)).fill()
        }
    }
    #endif

    func update(items: [BorderOverlay.Item], style: BorderStyle, width: CGFloat) {
        guard items != self.items || style != self.style || width != self.width else { return }
        defer {
            self.items = items
            self.style = style
            self.width = width
        }
        // A style change, or windows changing stacking order, can affect everything.
        let added = items.filter { !self.items.contains($0) }
        let removed = self.items.filter { !items.contains($0) }
        guard style == self.style, width == self.width, !(added.isEmpty && removed.isEmpty) else {
            needsDisplay = true
            return
        }
        // Otherwise only the areas around windows that moved, appeared, vanished or changed color.
        let margin = width * 4 + 4   // border, high-contrast band and glow
        for item in added + removed {
            setNeedsDisplay(item.frame.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -margin, dy: -margin))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        ctx.clip(to: dirtyRect)
        for item in items {   // back to front
            let rect = item.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            // Erase borders of windows behind this one.
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            if let color = item.color { drawBorder(around: rect, color: color, in: ctx) }
        }
    }

    /// Strokes just outside the window edge so the border never covers window content.
    private func drawBorder(around rect: CGRect, color: NSColor, in ctx: CGContext) {
        func outline(_ w: CGFloat) -> CGPath {
            let r = rect.insetBy(dx: -w / 2, dy: -w / 2)
            let radius = Self.cornerRadius + w / 2
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        ctx.saveGState()
        switch style {
        case .highContrast:
            // Dark band outside, bright color inside: readable on light and dark backgrounds alike.
            ctx.addPath(outline(width * 2 + 2))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(width + 2)
            ctx.strokePath()
            ctx.addPath(outline(width))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        case .vibrant:
            ctx.setShadow(offset: .zero, blur: width * 3, color: color.cgColor)
            ctx.addPath(outline(width))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        case .natural, .custom:
            ctx.addPath(outline(width))
            ctx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
