import Cocoa
import ApplicationServices
import CascadeCore
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cascade", category: "cascade")

/// Executes cascades and snaps. All Accessibility work runs on a private serial queue so the
/// menu bar never blocks; requests that arrive while one is running are dropped, not queued.
final class Engine {
    private let queue = DispatchQueue(label: "cascade.engine", qos: .userInitiated)

    // Queue-confined state.
    /// Windows snapped into a group: CGWindowID → group index.
    private var overrides: [CGWindowID: Int] = [:]

    // Main-thread state.
    private var busy = false
    /// Drop targets from the most recent layout of each display, for drag-to-snap.
    private(set) var lastDropTargets: [CGDirectDisplayID: [DropTarget]] = [:]

    // MARK: Public API (main thread)

    func cascade(_ scope: Scope, settings: CascadeSettings) {
        guard Permissions.ensureTrusted() else { return }
        let displays = Display.all()
        guard let pointer = Display.containing(Display.mouseLocation, in: displays) ?? displays.first else { return }
        run { engine in engine.performCascade(scope, settings: settings, displays: displays, pointer: pointer) }
    }

    /// Snaps `window` (or the focused window when nil) into group `group`.
    /// `dropDisplay` is the display a window was dragged onto, if any.
    func snap(_ window: AXUIElement?, toGroup group: Int, settings: CascadeSettings, dropDisplay: Display? = nil) {
        guard Permissions.ensureTrusted() else { return }
        let displays = Display.all()
        guard let pointer = Display.containing(Display.mouseLocation, in: displays) ?? displays.first else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        run { engine in
            guard let target = window ?? frontPID.flatMap(AXUIElement.focusedWindow(of:)) else {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            engine.performSnap(target, group: group, settings: settings, displays: displays,
                               pointer: dropDisplay ?? pointer, dropped: dropDisplay != nil)
        }
    }

    func resetSnaps() {
        queue.async { self.overrides.removeAll() }
    }

    /// Forget layouts (e.g. after settings or display changes) so drop targets are recomputed.
    func invalidateLayouts() {
        lastDropTargets.removeAll()
    }

    // MARK: Execution

    private func run(_ work: @escaping (Engine) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            let start = Date()
            work(self)
            log.debug("operation finished in \(Date().timeIntervalSince(start) * 1000, format: .fixed(precision: 0)) ms")
            DispatchQueue.main.async { self.busy = false }
        }
    }

    private func performCascade(_ scope: Scope, settings: CascadeSettings, displays: [Display], pointer: Display) {
        let windows = WindowSource.collect(scope)
        guard !windows.isEmpty else { DispatchQueue.main.async { NSSound.beep() }; return }
        pruneOverrides()

        let restored = scope == .all ? restore(windows) : []

        let partitions = partition(windows, settings: settings, displays: displays, pointer: pointer)
        var plans: [(display: Display, windows: [LiveWindow], plan: Plan)] = []
        for (display, members) in partitions {
            let plan = Planner.plan(windows: members.map(\.planWindow), area: display.visibleFrame,
                                    settings: settings, overrides: overrides)
            plans.append((display, members, plan))
        }

        var targets: [(window: LiveWindow, frame: CGRect)] = []
        for (_, members, plan) in plans {
            for group in plan.groups {
                for (i, frame) in zip(group.windows, group.frames) { targets.append((members[i], frame)) }
            }
        }
        withEnhancedUIDisabled(windows) {
            for t in targets { t.window.element.setFrame(t.frame, resizable: t.window.resizable) }
            // Just-restored windows can still snap back to their old frame; check and re-apply once.
            if !restored.isEmpty {
                let restoredIDs = Set(restored.compactMap { windows[$0].windowID })
                usleep(150_000)
                for t in targets where t.window.windowID.map(restoredIDs.contains) == true {
                    if let now = t.window.element.frame,
                       abs(now.minX - t.frame.minX) > 2 || abs(now.minY - t.frame.minY) > 2 {
                        t.window.element.setFrame(t.frame, resizable: t.window.resizable)
                    }
                }
            }
        }

        for (_, members, plan) in plans {
            raise(plan.raiseOrder.map { members[$0] })
        }
        // Return focus to the window that was in front before cascading.
        if let front = windows.min(by: { $0.zRank < $1.zRank }) { focus(front) }

        publish(plans.map { ($0.display.id, $0.plan.dropTargets) })
        log.info("cascaded \(windows.count) windows on \(plans.count) display(s)")
    }

    private func performSnap(_ target: AXUIElement, group: Int, settings: CascadeSettings,
                             displays: [Display], pointer: Display, dropped: Bool) {
        guard let targetID = target.windowID else { DispatchQueue.main.async { NSSound.beep() }; return }
        pruneOverrides()

        let all = WindowSource.collect(.visible)
        guard let snapped = all.first(where: { $0.windowID == targetID }) else {
            DispatchQueue.main.async { NSSound.beep() }
            return
        }

        // The display to lay out: where the window was dropped, otherwise where a full cascade would put it.
        let display: Display
        if dropped || settings.displayMode == .pointerScreen {
            display = pointer
        } else {
            display = Self.display(of: snapped, in: displays, fallback: pointer)
        }
        var members = settings.displayMode == .pointerScreen
            ? all
            : all.filter { Self.display(of: $0, in: displays, fallback: pointer).id == display.id }
        if !members.contains(where: { $0.windowID == targetID }) { members.append(snapped) }

        let before = Planner.plan(windows: members.map(\.planWindow), area: display.visibleFrame,
                                  settings: settings, overrides: overrides)
        overrides[targetID] = group
        let after = Planner.plan(windows: members.map(\.planWindow), area: display.visibleFrame,
                                 settings: settings, overrides: overrides)

        // Only re-lay groups whose membership or region changed (always including the target group).
        let previous = Dictionary(uniqueKeysWithValues: before.groups.map { ($0.index, $0) })
        let changed = after.groups.filter { g in
            g.index == group || previous[g.index].map { $0.windows != g.windows || $0.region != g.region } ?? true
        }
        let changedWindows = Set(changed.flatMap(\.windows))

        withEnhancedUIDisabled(members) {
            for g in changed {
                for (i, frame) in zip(g.windows, g.frames) {
                    members[i].element.setFrame(frame, resizable: members[i].resizable)
                }
            }
        }
        raise(after.raiseOrder.filter(changedWindows.contains).map { members[$0] })
        focus(snapped)

        publish([(display.id, after.dropTargets)])
        log.info("snapped window \(targetID) to group \(group + 1)")
    }

    // MARK: Helpers (queue)

    private func partition(_ windows: [LiveWindow], settings: CascadeSettings, displays: [Display],
                           pointer: Display) -> [(Display, [LiveWindow])] {
        guard settings.displayMode == .eachDisplay, displays.count > 1 else { return [(pointer, windows)] }
        var buckets: [CGDirectDisplayID: [LiveWindow]] = [:]
        for w in windows {
            buckets[Self.display(of: w, in: displays, fallback: pointer).id, default: []].append(w)
        }
        return displays.compactMap { d in buckets[d.id].map { (d, $0) } }
    }

    /// The display a window lives on. Minimized and hidden windows keep their last frame, so they
    /// stay with the display they came from instead of jumping to another one.
    private static func display(of window: LiveWindow, in displays: [Display], fallback: Display) -> Display {
        let fallbackIndex = displays.firstIndex(of: fallback) ?? 0
        let i = DisplayAssigner.index(for: window.frame, displays: displays.map(\.frame), fallback: fallbackIndex)
        return displays.indices.contains(i) ? displays[i] : fallback
    }

    /// Un-hides apps and un-minimizes windows, then waits until they have really come back.
    /// Returns the indices of windows that were restored. A fixed delay isn't enough: some apps
    /// (Chrome, Firefox) animate for longer, and a frame set mid-animation is undone when it ends.
    @discardableResult
    private func restore(_ windows: [LiveWindow]) -> [Int] {
        var unhidden = Set<pid_t>()
        for w in windows where w.appHidden && unhidden.insert(w.pid).inserted {
            w.appElement.set(kAXHiddenAttribute, kCFBooleanFalse)
        }
        let restoring = windows.indices.filter { windows[$0].minimized }
        guard !restoring.isEmpty || !unhidden.isEmpty else { return [] }

        func isMinimized(_ i: Int) -> Bool { (windows[i].element.attr(kAXMinimizedAttribute) as Bool?) ?? false }
        func wait(upTo seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { usleep(50_000) }
        }

        for i in restoring { windows[i].element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        wait(upTo: 1.5) { restoring.allSatisfy { !isMinimized($0) } }

        // Some apps only restore a window when they're frontmost, or respond to "raise" instead.
        let stragglers = restoring.filter(isMinimized)
        for i in stragglers {
            windows[i].appElement.set(kAXFrontmostAttribute, kCFBooleanTrue)
            windows[i].element.set(kAXMinimizedAttribute, kCFBooleanFalse)
            windows[i].element.perform(kAXRaiseAction)
        }
        if !stragglers.isEmpty { wait(upTo: 1.5) { stragglers.allSatisfy { !isMinimized($0) } } }

        // Wait for the restore animation to finish: frames stop changing.
        var previous = restoring.map { windows[$0].element.frame }
        wait(upTo: 1.0) {
            usleep(60_000)
            let current = restoring.map { windows[$0].element.frame }
            defer { previous = current }
            return current == previous
        }

        let failed = restoring.filter(isMinimized)
        log.info("restored \(restoring.count - failed.count) of \(restoring.count) minimized windows, unhid \(unhidden.count) apps")
        return restoring.filter { !failed.contains($0) }
    }
    /// Electron/Chrome apps animate frame changes while "enhanced UI" is on; turn it off temporarily.
    private func withEnhancedUIDisabled(_ windows: [LiveWindow], _ body: () -> Void) {
        var seen = Set<pid_t>()
        var disabled: [AXUIElement] = []
        for w in windows where seen.insert(w.pid).inserted {
            if (w.appElement.attr("AXEnhancedUserInterface") as Bool?) == true,
               w.appElement.set("AXEnhancedUserInterface", kCFBooleanFalse) {
                disabled.append(w.appElement)
            }
        }
        body()
        for app in disabled { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    /// Raises windows in order (back to front). Windows are grouped per app, so each app is
    /// brought forward once and its windows are then raised within it.
    private func raise(_ windows: [LiveWindow]) {
        var lastPID: pid_t = 0
        for w in windows {
            if w.pid != lastPID {
                w.appElement.set(kAXFrontmostAttribute, kCFBooleanTrue)
                lastPID = w.pid
                if windows.count > 1 { usleep(30_000) }   // let the activation land before raising
            }
            w.element.perform(kAXRaiseAction)
        }
    }

    private func focus(_ window: LiveWindow) {
        window.appElement.set(kAXFrontmostAttribute, kCFBooleanTrue)
        window.element.perform(kAXRaiseAction)
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
    }

    private func pruneOverrides() {
        guard !overrides.isEmpty else { return }
        let existing = WindowSource.existingWindowIDs()
        overrides = overrides.filter { existing.contains($0.key) }
    }

    private func publish(_ targets: [(CGDirectDisplayID, [DropTarget])]) {
        DispatchQueue.main.async {
            for (id, t) in targets { self.lastDropTargets[id] = t }
        }
    }
}
