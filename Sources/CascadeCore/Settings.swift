import Foundation

/// How cascaded windows are sized.
public enum SizeMode: String, Codable, CaseIterable, Sendable {
    /// Windows grow to fill their group region, shrinking as more windows join the stack.
    case auto
    /// Windows use a fixed percentage of their group region.
    case custom
}

/// How windows are distributed across cascade groups.
public enum GroupingMode: String, Codable, CaseIterable, Sendable {
    /// Each application's windows stay together; apps are balanced across groups.
    case application
    /// Apps are pinned to groups by rules you set; unassigned apps are balanced automatically.
    case manual
}

/// Which display(s) a cascade arranges.
public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    /// Cascade each display's windows on that display (default).
    case eachDisplay
    /// Gather every window onto the display under the pointer.
    case pointerScreen
}

/// Modifier held while dropping a dragged window to snap it into a cascade group.
public enum SnapModifier: String, Codable, CaseIterable, Sendable {
    case shift, control, option, command
}

/// A global keyboard shortcut. `modifiers` uses Carbon modifier flags (cmdKey, optionKey, …).
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Printable key label captured at record time, e.g. "C".
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    // Carbon modifier bits (from HIToolbox/Events.h), duplicated so the core stays AppKit/Carbon-free.
    public static let cmdKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    public var displayString: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "⌃" }
        if modifiers & Self.optionKey != 0 { s += "⌥" }
        if modifiers & Self.shiftKey != 0 { s += "⇧" }
        if modifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + key
    }

    static let keyC: UInt32 = 8   // kVK_ANSI_C
    public static let defaultCascadeVisible = Shortcut(keyCode: keyC, modifiers: controlKey | optionKey, key: "C")
    public static let defaultCascadeAll = Shortcut(keyCode: keyC, modifiers: controlKey | optionKey | shiftKey, key: "C")
}

public struct CascadeSettings: Codable, Equatable, Sendable {
    // Window size
    public var sizeMode: SizeMode = .auto
    /// Percent of the group region, used when `sizeMode == .custom`.
    public var widthPercent: Double = 70
    public var heightPercent: Double = 75

    // How much of each window underneath stays visible.
    /// Visible strip along the top of each covered window (the title bar), in points.
    public var revealTop: Double = 34
    /// Visible strip along the left of each covered window, in points.
    public var revealLeft: Double = 34

    // Groups
    /// Group columns per display; 0 means automatic (based on display width).
    public var columns: Int = 1
    public var rows: Int = 1
    public var groupGap: Double = 12
    public var groupingMode: GroupingMode = .application
    /// In application mode, give the space of unused groups to the groups that have windows.
    public var collapseEmptyGroups: Bool = true
    /// Manual mode rules: bundle identifier → group index (0-based).
    public var appGroups: [String: Int] = [:]

    // Displays
    public var displayMode: DisplayMode = .eachDisplay

    // Snapping
    public var dragToSnap: Bool = true
    public var snapModifier: SnapModifier = .shift
    /// ⌃⌥1…⌃⌥9 snap the focused window to group 1…9.
    public var snapHotkeys: Bool = true

    // Shortcuts
    public var cascadeVisibleShortcut: Shortcut? = .defaultCascadeVisible
    public var cascadeAllShortcut: Shortcut? = .defaultCascadeAll

    public init() {}

    public static let revealRange: ClosedRange<Double> = 0...200
    public static let percentRange: ClosedRange<Double> = 20...100
    public static let maxColumns = 6
    public static let maxRows = 4

    /// Clamp values loaded from disk or edited in the UI into supported ranges.
    public func sanitized() -> CascadeSettings {
        var s = self
        s.widthPercent = s.widthPercent.clamped(to: Self.percentRange)
        s.heightPercent = s.heightPercent.clamped(to: Self.percentRange)
        s.revealTop = s.revealTop.clamped(to: Self.revealRange)
        s.revealLeft = s.revealLeft.clamped(to: Self.revealRange)
        s.columns = min(max(s.columns, 0), Self.maxColumns)
        s.rows = min(max(s.rows, 1), Self.maxRows)
        s.groupGap = s.groupGap.clamped(to: 0...100)
        s.appGroups = s.appGroups.filter { $0.value >= 0 && $0.value < Self.maxColumns * Self.maxRows }
        return s
    }

    // Decode field-by-field so settings saved by older versions (missing keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CascadeSettings()
        sizeMode = (try? c.decode(SizeMode.self, forKey: .sizeMode)) ?? d.sizeMode
        widthPercent = (try? c.decode(Double.self, forKey: .widthPercent)) ?? d.widthPercent
        heightPercent = (try? c.decode(Double.self, forKey: .heightPercent)) ?? d.heightPercent
        revealTop = (try? c.decode(Double.self, forKey: .revealTop)) ?? d.revealTop
        revealLeft = (try? c.decode(Double.self, forKey: .revealLeft)) ?? d.revealLeft
        columns = (try? c.decode(Int.self, forKey: .columns)) ?? d.columns
        rows = (try? c.decode(Int.self, forKey: .rows)) ?? d.rows
        groupGap = (try? c.decode(Double.self, forKey: .groupGap)) ?? d.groupGap
        groupingMode = (try? c.decode(GroupingMode.self, forKey: .groupingMode)) ?? d.groupingMode
        collapseEmptyGroups = (try? c.decode(Bool.self, forKey: .collapseEmptyGroups)) ?? d.collapseEmptyGroups
        appGroups = (try? c.decode([String: Int].self, forKey: .appGroups)) ?? d.appGroups
        displayMode = (try? c.decode(DisplayMode.self, forKey: .displayMode)) ?? d.displayMode
        dragToSnap = (try? c.decode(Bool.self, forKey: .dragToSnap)) ?? d.dragToSnap
        snapModifier = (try? c.decode(SnapModifier.self, forKey: .snapModifier)) ?? d.snapModifier
        snapHotkeys = (try? c.decode(Bool.self, forKey: .snapHotkeys)) ?? d.snapHotkeys
        cascadeVisibleShortcut = c.contains(.cascadeVisibleShortcut)
            ? try? c.decodeIfPresent(Shortcut.self, forKey: .cascadeVisibleShortcut) : d.cascadeVisibleShortcut
        cascadeAllShortcut = c.contains(.cascadeAllShortcut)
            ? try? c.decodeIfPresent(Shortcut.self, forKey: .cascadeAllShortcut) : d.cascadeAllShortcut
    }

    // Shortcuts encode explicitly as null when cleared so "no shortcut" survives a reload.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sizeMode, forKey: .sizeMode)
        try c.encode(widthPercent, forKey: .widthPercent)
        try c.encode(heightPercent, forKey: .heightPercent)
        try c.encode(revealTop, forKey: .revealTop)
        try c.encode(revealLeft, forKey: .revealLeft)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(groupGap, forKey: .groupGap)
        try c.encode(groupingMode, forKey: .groupingMode)
        try c.encode(collapseEmptyGroups, forKey: .collapseEmptyGroups)
        try c.encode(appGroups, forKey: .appGroups)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(dragToSnap, forKey: .dragToSnap)
        try c.encode(snapModifier, forKey: .snapModifier)
        try c.encode(snapHotkeys, forKey: .snapHotkeys)
        try c.encode(cascadeVisibleShortcut, forKey: .cascadeVisibleShortcut)
        try c.encode(cascadeAllShortcut, forKey: .cascadeAllShortcut)
    }

    private enum CodingKeys: String, CodingKey {
        case sizeMode, widthPercent, heightPercent, revealTop, revealLeft, columns, rows, groupGap,
             groupingMode, collapseEmptyGroups, appGroups, displayMode, dragToSnap, snapModifier,
             snapHotkeys, cascadeVisibleShortcut, cascadeAllShortcut
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
