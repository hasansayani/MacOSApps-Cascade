import Cocoa
import ApplicationServices
import CascadeCore

enum Scope {
    /// On-screen windows on the current Space.
    case visible
    /// Also minimized windows and windows of hidden apps.
    case all
}

/// A live window that can be moved, with the facts the planner needs.
struct LiveWindow {
    let element: AXUIElement
    let appElement: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let windowID: CGWindowID?
    let minimized: Bool
    let appHidden: Bool
    let frame: CGRect?
    let resizable: Bool
    /// 0 = frontmost; `Int.max` for minimized/hidden windows.
    let zRank: Int

    var planWindow: PlanWindow {
        PlanWindow(windowID: windowID, appKey: bundleID ?? "pid:\(pid)", bundleID: bundleID, zRank: zRank)
    }

    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }
}

enum WindowSource {
    private struct AppInfo {
        let pid: pid_t
        let bundleID: String?
        let hidden: Bool
    }

    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute,
                                     kAXPositionAttribute, kAXSizeAttribute]

    /// Collects cascadable windows from all regular apps. Apps are queried in parallel, so one slow
    /// or hung app (bounded by a short AX timeout) does not stall the rest.
    static func collect(_ scope: Scope) -> [LiveWindow] {
        let ranks = onScreenWindowRanks()
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .map { AppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, hidden: $0.isHidden) }
            .filter { scope == .all || !$0.hidden }

        var perApp = [[LiveWindow]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = windows(of: apps[i], scope: scope, ranks: ranks)
            lock.lock()
            perApp[i] = found
            lock.unlock()
        }
        return perApp.flatMap { $0 }
    }

    private static func windows(of app: AppInfo, scope: Scope, ranks: [CGWindowID: Int]) -> [LiveWindow] {
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.75)
        guard let elements: [AXUIElement] = appElement.attr(kAXWindowsAttribute) else { return [] }

        var result: [LiveWindow] = []
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.75)
            let v = element.attrs(attributes)
            let minimized = (v[3] as? Bool) ?? false
            guard WindowFilter.isCascadable(role: v[0] as? String, subrole: v[1] as? String,
                                            minimized: minimized, fullScreen: (v[2] as? Bool) == true) else { continue }
            if minimized && scope == .visible { continue }

            let origin = v[4].flatMap(AXUIElement.point)
            let size = v[5].flatMap(AXUIElement.size)
            if let size, size.width < 60 || size.height < 60 { continue }

            let id = element.windowID
            var rank = Int.max
            if let id {
                if let r = ranks[id] {
                    rank = r
                } else if !minimized && !app.hidden && !ranks.isEmpty {
                    continue   // neither minimized nor hidden, yet off-screen → on another Space
                }
            }
            let frame = origin.flatMap { o in size.map { CGRect(origin: o, size: $0) } }
            result.append(LiveWindow(element: element, appElement: appElement, pid: app.pid, bundleID: app.bundleID,
                                     windowID: id, minimized: minimized, appHidden: app.hidden, frame: frame,
                                     resizable: element.isSettable(kAXSizeAttribute), zRank: rank))
        }
        return result
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

    /// IDs of every window that still exists (any Space, minimized or not).
    static func existingWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }
}
