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
        statusItem.button?.image = StatusIcon.make()
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
        statusItem.button?.toolTip = "Cascade windows" + (settings.cascadeVisibleShortcut.map { " (\($0.displayString))" } ?? "")
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
        guard group < currentGroupCount() else { NSSound.beep(); return }
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

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Cascade Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
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

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
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
