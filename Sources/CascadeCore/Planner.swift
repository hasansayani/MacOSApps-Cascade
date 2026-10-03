import CoreGraphics

/// A window as seen by the planner.
public struct PlanWindow: Equatable, Sendable {
    /// Stable identity used by snap overrides (CGWindowID), if known.
    public var windowID: UInt32?
    /// Groups windows of the same application (bundle identifier, or pid when there is none).
    public var appKey: String
    /// Bundle identifier used by manual app rules.
    public var bundleID: String?
    /// Z-order: 0 is frontmost; larger is further back. Minimized/hidden windows use `Int.max`.
    public var zRank: Int

    public init(windowID: UInt32?, appKey: String, bundleID: String?, zRank: Int) {
        self.windowID = windowID
        self.appKey = appKey
        self.bundleID = bundleID
        self.zRank = zRank
    }
}

public struct PlannedGroup: Equatable, Sendable {
    /// Configured group index (0-based) — what snap hotkeys and app rules refer to.
    public var index: Int
    public var region: CGRect
    /// Indices into the input window array, back-to-front.
    public var windows: [Int]
    /// Target frame for each entry in `windows`.
    public var frames: [CGRect]
}

public struct DropTarget: Equatable, Sendable {
    public var index: Int
    public var region: CGRect
    public init(index: Int, region: CGRect) { self.index = index; self.region = region }
}

public struct Plan: Equatable, Sendable {
    public var groups: [PlannedGroup]
    /// Indices into the input window array, in the order they should be raised (back-to-front,
    /// contiguous per application) so the original front window ends on top.
    public var raiseOrder: [Int]
    /// Every drop target for drag-to-snap, including empty groups.
    public var dropTargets: [DropTarget]

    /// Group index → frame for a given window index.
    public func frame(ofWindow index: Int) -> (group: Int, frame: CGRect)? {
        for g in groups {
            if let i = g.windows.firstIndex(of: index) { return (g.index, g.frames[i]) }
        }
        return nil
    }
}

public enum Planner {
    /// Plans one display: assigns windows to groups, lays out group regions and cascade frames.
    /// - Parameters:
    ///   - overrides: windowID → group index from snapping; takes precedence over everything.
    public static func plan(windows: [PlanWindow], area: CGRect, settings: CascadeSettings,
                            overrides: [UInt32: Int] = [:]) -> Plan {
        let (columns, rows) = GroupGrid.dimensions(for: area, settings: settings)
        let slotCount = columns * rows
        let allRegions = GroupGrid.regions(count: slotCount, columns: columns, in: area,
                                           gap: CGFloat(settings.groupGap))
        let allTargets = allRegions.enumerated().map { DropTarget(index: $0.offset, region: $0.element) }
        guard !windows.isEmpty else { return Plan(groups: [], raiseOrder: [], dropTargets: allTargets) }

        // Apps ordered back-to-front by their frontmost window; windows within an app back-to-front.
        let appOrder = orderedApps(windows)
        let appRank = Dictionary(uniqueKeysWithValues: appOrder.enumerated().map { ($0.element, $0.offset) })
        let sorted = windows.indices.sorted {
            let a = windows[$0], b = windows[$1]
            if a.appKey != b.appKey { return appRank[a.appKey]! < appRank[b.appKey]! }
            if a.zRank != b.zRank { return a.zRank > b.zRank }
            return $0 < $1
        }

        let assignment = assign(windows: windows, appOrder: appOrder, slotCount: slotCount,
                                settings: settings, overrides: overrides)

        // Collapse unused groups in application mode so the used ones get the space.
        var used = Array(Set(assignment)).sorted()
        var regions: [Int: CGRect]
        var targets = allTargets
        if settings.groupingMode == .application && settings.collapseEmptyGroups && used.count < slotCount {
            let compact = GroupGrid.regions(count: used.count, columns: min(columns, used.count), in: area,
                                            gap: CGFloat(settings.groupGap))
            regions = Dictionary(uniqueKeysWithValues: zip(used, compact))
            targets = zip(used, compact).map { DropTarget(index: $0.0, region: $0.1) }
        } else {
            regions = Dictionary(uniqueKeysWithValues: allRegions.enumerated().map { ($0.offset, $0.element) })
            used = used.filter { regions[$0] != nil }
        }

        let groups: [PlannedGroup] = used.map { slot in
            let members = sorted.filter { assignment[$0] == slot }
            let region = regions[slot]!
            return PlannedGroup(index: slot, region: region, windows: members,
                                frames: CascadeLayout.frames(count: members.count, in: region, settings: settings))
        }
        return Plan(groups: groups, raiseOrder: sorted, dropTargets: targets)
    }

    static func orderedApps(_ windows: [PlanWindow]) -> [String] {
        var front: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, w) in windows.enumerated() {
            front[w.appKey] = min(front[w.appKey] ?? .max, w.zRank)
            if firstSeen[w.appKey] == nil { firstSeen[w.appKey] = i }
        }
        return front.keys.sorted {
            front[$0]! != front[$1]! ? front[$0]! > front[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
    }

    /// Group index for each window.
    static func assign(windows: [PlanWindow], appOrder: [String], slotCount: Int,
                       settings: CascadeSettings, overrides: [UInt32: Int]) -> [Int] {
        var result = [Int?](repeating: nil, count: windows.count)
        var load = [Int](repeating: 0, count: slotCount)

        // 1. Per-window snaps.
        for (i, w) in windows.enumerated() {
            if let id = w.windowID, let slot = overrides[id], slot < slotCount {
                result[i] = slot
                load[slot] += 1
            }
        }
        // 2. Manual app rules.
        if settings.groupingMode == .manual {
            for (i, w) in windows.enumerated() where result[i] == nil {
                if let bundle = w.bundleID, let slot = settings.appGroups[bundle], slot < slotCount {
                    result[i] = slot
                    load[slot] += 1
                }
            }
        }
        // 3. Remaining windows, kept together per app, largest apps first onto the least-loaded group.
        var remaining: [String: [Int]] = [:]
        for (i, w) in windows.enumerated() where result[i] == nil { remaining[w.appKey, default: []].append(i) }
        let appRank = Dictionary(uniqueKeysWithValues: appOrder.enumerated().map { ($0.element, $0.offset) })
        let apps = remaining.keys.sorted {
            remaining[$0]!.count != remaining[$1]!.count
                ? remaining[$0]!.count > remaining[$1]!.count
                : appRank[$0]! > appRank[$1]!   // ties: frontmost app gets the first group
        }
        for app in apps {
            let slot = load.indices.min { load[$0] != load[$1] ? load[$0] < load[$1] : $0 < $1 }!
            for i in remaining[app]! { result[i] = slot }
            load[slot] += remaining[app]!.count
        }
        return result.map { $0 ?? 0 }
    }
}

public enum WindowFilter {
    /// Whether an Accessibility window should be cascaded.
    ///
    /// Normal windows report the subrole `AXStandardWindow`. While a window is minimized, current
    /// macOS reports it as `AXDialog` instead, so minimized dialogs-by-subrole must be accepted or
    /// "Cascade All" would silently skip every minimized window. Real dialogs can't be minimized.
    public static func isCascadable(role: String?, subrole: String?, minimized: Bool, fullScreen: Bool) -> Bool {
        guard role == "AXWindow", !fullScreen else { return false }
        if subrole == "AXStandardWindow" { return true }
        return minimized && subrole == "AXDialog"
    }
}
