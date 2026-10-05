// Cascade — a menu bar utility that arranges windows in a classic Windows-style cascade.

import Cocoa
import SwiftUI
import Combine
import CascadeCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore.shared
    private let engine = Engine()
    private lazy var dragSnapper = DragSnapper(engine: engine) { [store] in store.settings }
    let borders = BorderController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    private var settings: CascadeSettings { store.settings }

    private enum HotKeyID {
        static let cascadeVisible: UInt32 = 1
        static let cascadeAll: UInt32 = 2
        static let snapBase: UInt32 = 10   // + group number 1…9
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }
        log.info("launched from \(Bundle.main.bundlePath, privacy: .public); accessibility trusted: \(Permissions.isTrusted)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcons.image(for: settings)
        statusItem.button?.setAccessibilityLabel("Cascade")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Re-apply hotkeys and snapping whenever settings change.
        store.$settings
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        // Pause global hotkeys while a shortcut is being recorded so the old one doesn't fire.
        NotificationCenter.default.publisher(for: .shortcutRecording)
            .sink { [weak self] note in
                if (note.object as? Bool) == true { HotKeys.unregisterAll() } else { self?.registerHotKeys() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: CustomIconStore.didChange)
            .sink { [weak self] _ in self?.applyIcons() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.engine.invalidateLayouts() }
            .store(in: &cancellables)

        if !Permissions.ensureTrusted(explain: false) { waitForAccessibility() }
    }

    /// Launching the app again (Finder, Spotlight, Launchpad) opens Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Settings

    private func applySettings() {
        registerHotKeys()
        engine.invalidateLayouts()
        if settings.dragToSnap { dragSnapper.start() } else { dragSnapper.stop() }
        borders.apply(settings)
        statusItem.button?.toolTip = "Cascade windows" + (settings.cascadeVisibleShortcut.map { " (\($0.displayString))" } ?? "")
        applyIcons()
    }

    private func applyIcons() {
        statusItem.button?.image = MenuBarIcons.image(for: settings)
        // Shown in About, Settings and alerts. (Finder keeps the bundled icon: changing it would
        // modify the signed app bundle.)
        NSApp.applicationIconImage = AppIconRenderer.image(settings.appIcon)
    }

    private func registerHotKeys() {
        HotKeys.unregisterAll()
        if let s = settings.cascadeVisibleShortcut {
            HotKeys.register(id: HotKeyID.cascadeVisible, s) { [weak self] in self?.cascade(.visible) }
        }
        if let s = settings.cascadeAllShortcut {
            HotKeys.register(id: HotKeyID.cascadeAll, s) { [weak self] in self?.cascade(.all) }
        }
        if settings.snapHotkeys {
            for n in 1...9 {
                let shortcut = Shortcut(keyCode: Self.digitKeyCodes[n - 1], modifiers: Shortcut.controlKey | Shortcut.optionKey,
                                        key: "\(n)")
                HotKeys.register(id: HotKeyID.snapBase + UInt32(n), shortcut) { [weak self] in self?.snapFocused(to: n - 1) }
            }
        }
    }

    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // kVK_ANSI_1 … kVK_ANSI_9

    // MARK: Actions

    private func cascade(_ scope: Scope) { engine.cascade(scope, settings: settings) }

    private func snapFocused(to group: Int) {
        // The focused window may be on any display, so accept a group that exists on at least one.
        // (The planner ignores a snap to a group its display doesn't have.)
        let maxGroups = Display.all().map { d -> Int in
            let (columns, rows) = GroupGrid.dimensions(for: d.visibleFrame, settings: settings)
            return columns * rows
        }.max() ?? 1
        guard group < maxGroups else { NSSound.beep(); return }
        engine.snap(nil, toGroup: group, settings: settings)
    }

    /// Group count on the display under the pointer with the current grid.
    private func currentGroupCount() -> Int {
        let displays = Display.all()
        guard let display = Display.containing(Display.mouseLocation, in: displays) ?? displays.first else { return 1 }
        let (columns, rows) = GroupGrid.dimensions(for: display.visibleFrame, settings: settings)
        return columns * rows
    }

    @objc private func cascadeVisible() { cascade(.visible) }
    @objc private func cascadeAll() { cascade(.all) }
    @objc private func snapItem(_ sender: NSMenuItem) { snapFocused(to: sender.tag) }
    @objc private func resetSnaps() { engine.resetSnaps() }
    @objc private func grantAccess() { Permissions.ensureTrusted() }

    @objc private func setColumns(_ sender: NSMenuItem) {
        store.settings.columns = sender.tag
        store.settings.rows = 1
    }

    @objc private func setGrid2x2() {
        store.settings.columns = 2
        store.settings.rows = 2
    }

    @objc private func setGrouping(_ sender: NSMenuItem) {
        store.settings.groupingMode = sender.tag == 0 ? .application : .manual
    }

    @objc private func toggleBorders() {
        store.settings.bordersEnabled.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    private static let repoURL = URL(string: "https://github.com/hasansayani/MacOSApps-Cascade")!

    /// Standard About window (icon, name, version, copyright from Info.plist) plus a description and links.
    @objc private func showAbout() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: center,
                                                   .foregroundColor: NSColor.labelColor]
        let credits = NSMutableAttributedString(
            string: "Arranges windows in a classic cascade, grouped by application.\n", attributes: base)
        let links: [(String, String)] = [("GitHub", ""), ("Releases", "/releases"), ("Report an issue", "/issues")]
        for (index, (title, path)) in links.enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            var attrs = base
            attrs[.link] = Self.repoURL.appendingPathComponent(path)
            credits.append(NSAttributedString(string: title, attributes: attrs))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Cascade Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: store, borders: borders))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("CascadeSettings")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(grantAccess)))
            menu.addItem(.separator())
        }

        let visible = item("Cascade Visible Windows", #selector(cascadeVisible))
        visible.setShortcut(settings.cascadeVisibleShortcut)
        let all = item("Cascade All Windows (incl. Minimized)", #selector(cascadeAll))
        all.setShortcut(settings.cascadeAllShortcut)
        menu.addItem(visible)
        menu.addItem(all)

        let snapMenu = NSMenu()
        for g in 0..<min(currentGroupCount(), 9) {
            let snap = item("Group \(g + 1)", #selector(snapItem(_:)), tag: g)
            if settings.snapHotkeys {
                snap.keyEquivalent = "\(g + 1)"
                snap.keyEquivalentModifierMask = [.control, .option]
            }
            snapMenu.addItem(snap)
        }
        snapMenu.addItem(.separator())
        snapMenu.addItem(item("Reset Snapped Windows", #selector(resetSnaps)))
        let snapRoot = NSMenuItem(title: "Snap Focused Window To", action: nil, keyEquivalent: "")
        snapRoot.submenu = snapMenu
        menu.addItem(snapRoot)

        menu.addItem(.separator())

        let groupsMenu = NSMenu()
        let options: [(String, Int)] = [("Single Cascade", 1), ("2 Columns", 2), ("3 Columns", 3), ("4 Columns", 4),
                                        ("Automatic Columns", 0)]
        for (title, columns) in options {
            let option = item(title, #selector(setColumns(_:)), tag: columns)
            option.state = settings.columns == columns && settings.rows == 1 ? .on : .off
            groupsMenu.addItem(option)
        }
        let grid = item("2 × 2 Grid", #selector(setGrid2x2))
        grid.state = settings.columns == 2 && settings.rows == 2 ? .on : .off
        groupsMenu.addItem(grid)
        groupsMenu.addItem(.separator())
        let byApp = item("Group by Application", #selector(setGrouping(_:)), tag: 0)
        byApp.state = settings.groupingMode == .application ? .on : .off
        let manual = item("Group Manually", #selector(setGrouping(_:)), tag: 1)
        manual.state = settings.groupingMode == .manual ? .on : .off
        groupsMenu.addItem(byApp)
        groupsMenu.addItem(manual)
        let groupsRoot = NSMenuItem(title: "Cascade Groups", action: nil, keyEquivalent: "")
        groupsRoot.submenu = groupsMenu
        menu.addItem(groupsRoot)

        let bordersItem = item("Show Window Borders", #selector(toggleBorders))
        bordersItem.state = settings.bordersEnabled ? .on : .off
        menu.addItem(bordersItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item("About Cascade", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Quit Cascade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    // MARK: Lifecycle helpers

    /// Polls until Accessibility is granted so drag-to-snap and the menu update without a relaunch.
    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Permissions.isTrusted else { return }
            timer.invalidate()
            log.info("accessibility access granted")
            self?.applySettings()
        }
    }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }
}

// `Cascade --render-icon out.png [style]` writes a 1024 px app icon (used by build.sh for AppIcon.icns).
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    let style = (i + 2 < CommandLine.arguments.count ? AppIconStyle(rawValue: CommandLine.arguments[i + 2]) : nil) ?? .ocean
    do {
        try AppIconRenderer.writePNG(style, pixels: 1024, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-icon failed: \(error)\n".utf8))
        exit(1)
    }
}

// `Cascade --diagnose` lists the windows a "cascade all" would arrange, as JSON lines. Moves nothing.
if CommandLine.arguments.contains("--diagnose") {
    guard Permissions.isTrusted else {
        FileHandle.standardError.write(Data("diagnose needs Accessibility access\n".utf8))
        exit(2)
    }
    for w in WindowSource.collect(.all) {
        let f = w.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
        let app = w.bundleID ?? "pid \(w.pid)"
        print(#"{"app": "\#(app)", "id": \#(w.windowID ?? 0), "minimized": \#(w.minimized), "hidden": \#(w.appHidden), "z": \#(w.zRank == .max ? -1 : w.zRank), "frame": "\#(f)"}"#)
    }
    exit(0)
}

// `Cascade --benchmark [runs]` times a full window scan + layout plan (nothing is moved) and prints JSON.
// Used by scripts/repo_report.py for the App Facts label. Needs Accessibility access.
if let i = CommandLine.arguments.firstIndex(of: "--benchmark") {
    guard Permissions.isTrusted else {
        FileHandle.standardError.write(Data("benchmark needs Accessibility access\n".utf8))
        exit(2)
    }
    let runs = (i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) : nil) ?? 25
    let settings = CascadeSettings()
    let area = Display.all().first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 920)
    var samples: [Double] = []
    var windowCount = 0
    var appCount = 0
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        let windows = WindowSource.collect(.visible)
        _ = Planner.plan(windows: windows.map(\.planWindow), area: area, settings: settings)
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        windowCount = windows.count
        appCount = Set(windows.map(\.pid)).count
    }
    samples.sort()
    let median = samples[samples.count / 2]
    let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    print(#"{"runs": \#(runs), "windows": \#(windowCount), "apps": \#(appCount), "median_ms": \#(String(format: "%.1f", median)), "p95_ms": \#(String(format: "%.1f", p95))}"#)
    exit(0)
}

#if DEBUG
// Debug-only: `Cascade --test-cascade-all <bundleID>` runs "Cascade All" on that app's windows only.
if let i = CommandLine.arguments.firstIndex(of: "--test-cascade-all"), i + 1 < CommandLine.arguments.count {
    Engine().cascadeForTesting(.all, settings: CascadeSettings(), onlyBundleID: CommandLine.arguments[i + 1])
    exit(0)
}

// Debug-only: `Cascade --render-borders out.png [natural|vibrant|highContrast|custom]`
if let i = CommandLine.arguments.firstIndex(of: "--render-borders"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    var settings = CascadeSettings()
    if i + 2 < CommandLine.arguments.count, let style = BorderStyle(rawValue: CommandLine.arguments[i + 2]) {
        settings.borderStyle = style
    }
    settings.borderWidth = 4
    BorderController().renderSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), settings: settings)
    exit(0)
}

if CommandLine.arguments.contains("--time-borders") {
    _ = NSApplication.shared
    BorderController().timeRefresh()
    exit(0)
}

// Debug-only: `Cascade --probe` prints raw Accessibility results per app.
if CommandLine.arguments.contains("--probe") {
    print("trusted:", AXIsProcessTrusted())
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value)
        let wins = (value as? [AXUIElement]) ?? []
        print(app.bundleIdentifier ?? "?", "windows err:", err.rawValue, "count:", wins.count)
        for w in wins.prefix(4) {
            let v = w.attrs([kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute])
            var single: CFTypeRef?
            let roleErr = AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &single)
            print("   multi:", v.map { $0.map { "\($0)".prefix(30) } ?? "nil" }, "| single role err:", roleErr.rawValue, single as? String ?? "-", "| id:", w.windowID ?? 0)
        }
    }
    exit(0)
}

// Debug-only: `Cascade --minimize <bundleID>` minimizes that app's first window.
if let i = CommandLine.arguments.firstIndex(of: "--minimize"), i + 1 < CommandLine.arguments.count,
   let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first,
   let windows: [AXUIElement] = AXUIElementCreateApplication(app.processIdentifier).attr(kAXWindowsAttribute),
   let window = windows.first {
    window.set(kAXMinimizedAttribute, kCFBooleanTrue)
    usleep(1_000_000)
    exit(0)
}

// Debug-only: `Cascade --test-restore <bundleID>` minimizes that app's first window, then replays the
// cascade-all restore sequence (unminimize, wait 350 ms, set frame) and samples where the window ends up.
if let i = CommandLine.arguments.firstIndex(of: "--test-restore"), i + 1 < CommandLine.arguments.count {
    guard Permissions.isTrusted,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first,
          let windows: [AXUIElement] = AXUIElementCreateApplication(app.processIdentifier).attr(kAXWindowsAttribute),
          let window = windows.first else { print("no trust or no window"); exit(2) }
    func state(_ label: String) {
        let f = window.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
        print(label, "minimized:", (window.attr(kAXMinimizedAttribute) as Bool?) ?? false, "frame:", f)
    }
    window.set(kAXMinimizedAttribute, kCFBooleanTrue)
    usleep(1_200_000)
    state("after minimize       ")
    let target = CGRect(x: 100, y: 150, width: 700, height: 500)
    window.set(kAXMinimizedAttribute, kCFBooleanFalse)
    usleep(350_000)
    window.setFrame(target, resizable: true)
    state("right after setFrame ")
    for t in 1...8 { usleep(250_000); state("t+\(t * 250) ms".padding(toLength: 21, withPad: " ", startingAt: 0)) }
    exit(0)
}

// Debug-only: `Cascade --render-menubar-icons out.png` draws every menu bar icon at 8x on light and dark strips.
if let i = CommandLine.arguments.firstIndex(of: "--render-menubar-icons"), i + 1 < CommandLine.arguments.count {
    let styles = MenuBarIconStyle.allCases.filter { $0 != .custom }
    let scale: CGFloat = 8, cell = NSSize(width: 26, height: 22)
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(styles.count) * scale, height: cell.height * 2 * scale), flipped: false) { _ in
        for (row, dark) in [(0, true), (1, false)] {
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: CGFloat(row) * cell.height * scale, width: cell.width * CGFloat(styles.count) * scale, height: cell.height * scale).fill()
            for (col, style) in styles.enumerated() {
                let icon = MenuBarIcons.image(style)
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                tinted.draw(in: NSRect(x: (CGFloat(col) * cell.width + (cell.width - icon.size.width) / 2) * scale,
                                       y: (CGFloat(row) * cell.height + (cell.height - icon.size.height) / 2) * scale,
                                       width: size.width, height: size.height))
            }
        }
        return true
    }
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// Debug-only: `Cascade --render-settings out.png` snapshots the settings UI without screen recording permission.
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let view = NSHostingView(rootView: SettingsView(store: .shared))
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
