// Assertion checks for CascadeCore. Run with `swift run CascadeSelfTest` (no Xcode/XCTest needed).
import CascadeCore
import CoreGraphics
import Foundation

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("✗ line \(line): \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

let laptop = CGRect(x: 0, y: 25, width: 1512, height: 920)
let wide = CGRect(x: 0, y: 25, width: 5120, height: 1400)

func windows(_ apps: [(String, Int)]) -> [PlanWindow] {
    var result: [PlanWindow] = []
    var z = 0
    var id: UInt32 = 100
    for (app, count) in apps {
        for _ in 0..<count {
            result.append(PlanWindow(windowID: id, appKey: app, bundleID: app, zRank: z))
            z += 1
            id += 1
        }
    }
    return result
}

/// Every window must keep a visible, clickable strip: no later window may cover its top-left corner area.
func everyWindowExposed(_ frames: [CGRect], minStrip: CGFloat) -> Bool {
    for (i, f) in frames.enumerated() {
        let corner = CGRect(x: f.minX, y: f.minY, width: minStrip, height: minStrip)
        if frames[(i + 1)...].contains(where: { $0.contains(corner) }) { return false }
    }
    return true
}

test("auto size: equal sizes, diagonal steps, inside region") {
    let s = CascadeSettings()
    let frames = CascadeLayout.frames(count: 6, in: laptop, settings: s)
    check(frames.count == 6, "count")
    check(frames.allSatisfy { $0.size == frames[0].size }, "all same size")
    for i in 1..<frames.count {
        check(frames[i].minX - frames[i - 1].minX == 34 && frames[i].minY - frames[i - 1].minY == 34, "step \(i)")
    }
    check(frames.allSatisfy { laptop.contains($0) }, "inside region")
    check(everyWindowExposed(frames, minStrip: 20), "exposed strips")
}

test("custom size and reveal are honored") {
    var s = CascadeSettings()
    s.sizeMode = .custom
    s.widthPercent = 50
    s.heightPercent = 60
    s.revealTop = 50
    s.revealLeft = 10
    let frames = CascadeLayout.frames(count: 4, in: laptop, settings: s)
    check(frames[0].width == (laptop.width * 0.5).rounded(), "width \(frames[0].width)")
    check(abs(frames[0].height - laptop.height * 0.6) <= 1, "height \(frames[0].height)")
    check(frames[1].minY - frames[0].minY == 50, "top reveal")
    check(frames[1].minX - frames[0].minX == 10, "left reveal")
    check(frames.allSatisfy { laptop.contains($0) }, "inside region")
}

test("many windows wrap but stay exposed and on screen") {
    let s = CascadeSettings()
    for n in [1, 2, 13, 14, 30, 60] {
        let frames = CascadeLayout.frames(count: n, in: laptop, settings: s)
        check(frames.count == n, "count \(n)")
        check(frames.allSatisfy { laptop.insetBy(dx: -1, dy: -1).contains($0) }, "inside region n=\(n)")
        check(frames.allSatisfy { $0.size == frames[0].size }, "equal size n=\(n)")
        check(everyWindowExposed(frames, minStrip: n <= 30 ? 20 : 8), "exposed n=\(n)")
    }
}

test("zero reveal does not crash") {
    var s = CascadeSettings()
    s.revealTop = 0
    s.revealLeft = 0
    check(CascadeLayout.frames(count: 5, in: laptop, settings: s).count == 5, "count")
}

test("tiny region clamps sizes") {
    let frames = CascadeLayout.frames(count: 3, in: CGRect(x: 0, y: 0, width: 200, height: 120), settings: CascadeSettings())
    check(frames.allSatisfy { $0.width <= 200 && $0.height <= 120 }, "clamped")
}

test("grid regions tile without overlap") {
    let r = GroupGrid.regions(count: 5, columns: 3, in: wide, gap: 10)
    check(r.count == 5, "count")
    check(r[3].width > r[0].width, "last row stretches")
    for i in r.indices { for j in r.indices where i < j { check(!r[i].intersects(r[j]), "overlap \(i),\(j)") } }
    check(r.allSatisfy { wide.contains($0) }, "inside")
    check(GroupGrid.autoColumns(forWidth: 1512) == 1 && GroupGrid.autoColumns(forWidth: 5120) == 4, "auto columns")
}

test("single group keeps apps contiguous and front app last") {
    let w = windows([("front", 2), ("middle", 3), ("back", 1)])
    let plan = Planner.plan(windows: w, area: laptop, settings: CascadeSettings())
    check(plan.groups.count == 1, "one group")
    let apps = plan.raiseOrder.map { w[$0].appKey }
    check(apps == ["back", "middle", "middle", "middle", "front", "front"], "order \(apps)")
    check(plan.raiseOrder.last == 0, "front window raised last")
}

test("application grouping balances apps across columns") {
    var s = CascadeSettings()
    s.columns = 3
    let w = windows([("a", 4), ("b", 3), ("c", 2), ("d", 1)])
    let plan = Planner.plan(windows: w, area: wide, settings: s)
    check(plan.groups.count == 3, "three groups")
    for g in plan.groups {
        check(Set(g.windows.map { w[$0].appKey }).count >= 1, "non-empty")
        for app in Set(g.windows.map { w[$0].appKey }) {
            check(plan.groups.filter { $0.windows.contains { w[$0].appKey == app } }.count == 1, "\(app) in one group")
        }
    }
    let loads = plan.groups.map(\.windows.count).sorted()
    check(loads == [3, 3, 4], "balanced \(loads)")
}

test("empty groups collapse in application mode, not in manual mode") {
    var s = CascadeSettings()
    s.columns = 4
    let w = windows([("a", 2), ("b", 2)])
    let collapsed = Planner.plan(windows: w, area: wide, settings: s)
    check(collapsed.groups.count == 2 && collapsed.groups[0].region.width > wide.width / 3, "collapsed to halves")
    s.groupingMode = .manual
    let fixed = Planner.plan(windows: w, area: wide, settings: s)
    check(fixed.dropTargets.count == 4, "manual keeps all drop targets")
    check(fixed.groups.allSatisfy { $0.region.width < wide.width / 3 }, "manual keeps quarter widths")
}

test("manual rules and snap overrides") {
    var s = CascadeSettings()
    s.columns = 3
    s.groupingMode = .manual
    s.appGroups = ["b": 2]
    let w = windows([("a", 2), ("b", 2), ("c", 1)])
    var plan = Planner.plan(windows: w, area: wide, settings: s)
    let groupOfB = plan.groups.first { $0.windows.contains(2) }!.index
    check(groupOfB == 2, "rule pins b to group 3")
    // Snap one window of app a (id 100) into group 2.
    plan = Planner.plan(windows: w, area: wide, settings: s, overrides: [100: 2])
    check(plan.frame(ofWindow: 0)?.group == 2, "override wins")
    check(plan.frame(ofWindow: 1)?.group != 2, "other a window not dragged along")
    // Overrides beyond the grid are ignored.
    plan = Planner.plan(windows: w, area: wide, settings: s, overrides: [100: 9])
    check(plan.frame(ofWindow: 0) != nil && plan.frame(ofWindow: 0)!.group < 3, "out-of-range override ignored")
}

test("settings round-trip and tolerate missing keys") {
    var s = CascadeSettings()
    s.revealTop = 48
    s.cascadeAllShortcut = nil
    s.appGroups = ["com.apple.Safari": 1]
    let data = try! JSONEncoder().encode(s)
    let back = try! JSONDecoder().decode(CascadeSettings.self, from: data)
    check(back == s, "round trip")
    let partial = try! JSONDecoder().decode(CascadeSettings.self, from: Data(#"{"revealTop": 60}"#.utf8))
    check(partial.revealTop == 60 && partial.cascadeVisibleShortcut == .defaultCascadeVisible, "partial decode")
    var wild = CascadeSettings()
    wild.revealTop = 9999
    wild.columns = -3
    wild.widthPercent = 1
    let clean = wild.sanitized()
    check(clean.revealTop == 200 && clean.columns == 0 && clean.widthPercent == 20, "sanitized")
    check(Shortcut.defaultCascadeAll.displayString == "⌃⌥⇧C", "display string")
    var icons = CascadeSettings()
    icons.menuBarIcon = .symbolLayers
    icons.appIcon = .sunset
    icons.customIconIsTemplate = false
    let iconsBack = try! JSONDecoder().decode(CascadeSettings.self, from: try! JSONEncoder().encode(icons))
    check(iconsBack == icons, "icon choices round trip")
    let unknown = try! JSONDecoder().decode(CascadeSettings.self, from: Data(#"{"menuBarIcon": "rainbow"}"#.utf8))
    check(unknown.menuBarIcon == .cascade, "unknown icon falls back to default")
}

test("windows are assigned to the display they are on") {
    // Built-in display on the left, a 4K display to its right, and one above the built-in display.
    let builtIn = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let external = CGRect(x: 1800, y: -400, width: 3840, height: 2160)
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    let displays = [builtIn, external, above]
    func on(_ r: CGRect?) -> Int { DisplayAssigner.index(for: r, displays: displays, fallback: 0) }
    check(on(CGRect(x: 2500, y: 200, width: 1200, height: 800)) == 1, "inside external")
    check(on(CGRect(x: 100, y: -900, width: 800, height: 600)) == 2, "inside display above")
    check(on(CGRect(x: 1500, y: 100, width: 1000, height: 600)) == 1, "straddling: most area wins")
    check(on(CGRect(x: 1500, y: 100, width: 500, height: 600)) == 0, "straddling: most area wins (other way)")
    check(on(CGRect(x: 9000, y: 300, width: 400, height: 300)) == 1, "off-screen: nearest display")
    check(on(nil) == 0, "unknown frame: fallback")
    check(DisplayAssigner.index(for: .zero, displays: [], fallback: 4) == 4, "no displays: fallback")
}

test("each display gets its own plan sized to that display") {
    let s = CascadeSettings()
    check(s.displayMode == .eachDisplay, "windows stay on their display by default")
    let external = CGRect(x: 1800, y: -400, width: 3840, height: 2135)
    let plan = Planner.plan(windows: windows([("a", 3)]), area: external, settings: s)
    check(plan.groups.flatMap(\.frames).allSatisfy { external.contains($0) }, "frames stay on the external display")
}

test("minimized windows are cascadable even though macOS calls them dialogs") {
    func ok(_ role: String?, _ subrole: String?, minimized: Bool = false, fullScreen: Bool = false) -> Bool {
        WindowFilter.isCascadable(role: role, subrole: subrole, minimized: minimized, fullScreen: fullScreen)
    }
    check(ok("AXWindow", "AXStandardWindow"), "normal window")
    check(ok("AXWindow", "AXStandardWindow", minimized: true), "minimized standard window")
    check(ok("AXWindow", "AXDialog", minimized: true), "minimized window reported as dialog")
    check(!ok("AXWindow", "AXDialog"), "real dialog is skipped")
    check(!ok("AXWindow", "AXFloatingWindow"), "panel is skipped")
    check(!ok("AXWindow", "AXStandardWindow", fullScreen: true), "full-screen window is skipped")
    check(!ok("AXScrollArea", nil), "Finder desktop is skipped")
    check(!ok("AXHelpTag", "AXUnknown"), "tooltip is skipped")
}

test("border colors come from icons and stay distinct between apps") {
    let sep = BorderPalette.minimumSeparation
    func distinct(_ hues: [String: Double]) -> Bool {
        let v = Array(hues.values)
        for i in v.indices { for j in v.indices where i < j { if BorderPalette.hueDistance(v[i], v[j]) < sep - 1e-9 { return false } } }
        return true
    }
    // Firefox (orange), Chrome (red/yellow/green/blue), Safari (blue), Mail (blue): blue clashes.
    let apps: [(key: String, candidates: [Double])] = [
        ("firefox", [0.07, 0.75]), ("chrome", [0.0, 0.14, 0.33, 0.6]),
        ("safari", [0.58]), ("mail", [0.6, 0.0]), ("terminal", []),
    ]
    let hues = BorderPalette.assignHues(apps: apps)
    check(hues.count == 5, "every app gets a color")
    check(distinct(hues), "all colors at least 30° apart: \(hues)")
    check(hues["firefox"] == 0.07, "first app keeps its icon color")
    check(hues["safari"] == 0.58, "safari keeps blue")
    check(BorderPalette.hueDistance(hues["mail"]!, 0.58) >= sep, "mail moved off safari's blue")
    // Stable: re-running with the previous result changes nothing.
    check(BorderPalette.assignHues(apps: apps, previous: hues) == hues, "stable across refreshes")
    // A newly opened app adapts; existing apps keep their colors.
    let more = BorderPalette.assignHues(apps: apps + [("maps", [0.07])], previous: hues)
    check(apps.allSatisfy { more[$0.key] == hues[$0.key] }, "existing apps keep colors when another opens")
    check(distinct(more), "new app still distinct")
    // Gray icons get a deterministic hue.
    check(BorderPalette.stableHue(for: "terminal") == BorderPalette.stableHue(for: "terminal"), "stable gray hue")
    // Many apps: never crashes, spreads hues as far as possible.
    let many = (0..<20).map { (key: "app\($0)", candidates: [0.6]) }
    let spread = BorderPalette.assignHues(apps: many)
    check(spread.count == 20 && Set(spread.values.map { Int($0 * 360) }).count == 20, "20 apps get 20 different hues")
}

test("border settings round trip and clamp") {
    var b = CascadeSettings()
    check(b.bordersEnabled && b.borderStyle == .natural, "borders on with icon colors by default")
    b.borderStyle = .custom
    b.borderCustomColor = RGBColor(red: 0.2, green: 0.4, blue: 0.6)
    b.borderWidth = 5
    let back = try! JSONDecoder().decode(CascadeSettings.self, from: try! JSONEncoder().encode(b))
    check(back == b, "round trip")
    b.borderWidth = 50
    check(b.sanitized().borderWidth == 8, "width clamped")
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
