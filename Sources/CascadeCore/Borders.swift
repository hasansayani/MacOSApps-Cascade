import Foundation

/// How window borders are colored.
public enum BorderStyle: String, Codable, CaseIterable, Sendable {
    /// Each app's color comes from its icon, kept distinct from other apps in use.
    case natural
    /// Icon colors at full saturation with a glow.
    case vibrant
    /// Icon colors on a dark underlay, readable on any background.
    case highContrast
    /// One color, chosen by the user, for every app.
    case custom
}

/// An sRGB color, stored as 0–1 components.
public struct RGBColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum BorderPalette {
    /// Smallest hue distance (as a fraction of the color wheel) between two apps' borders: 30°.
    public static let minimumSeparation = 1.0 / 12

    /// Circular distance between two hues in 0..<1.
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// Assigns each app a border hue.
    ///
    /// - Parameters:
    ///   - apps: app keys in priority order (earlier apps get first pick), each with the hues found in
    ///     its icon, most dominant first. An empty list means a gray icon.
    ///   - previous: hues assigned last time; apps keep them while they stay distinct, so colors don't
    ///     shuffle as other apps open and close.
    /// - Returns: app key → hue in 0..<1.
    public static func assignHues(apps: [(key: String, candidates: [Double])],
                                  previous: [String: Double] = [:],
                                  minimumSeparation: Double = minimumSeparation) -> [String: Double] {
        var assigned: [String: Double] = [:]
        func isFree(_ hue: Double) -> Bool {
            assigned.values.allSatisfy { hueDistance($0, hue) >= minimumSeparation - 1e-9 }
        }

        // 1. Keep previous hues that are still distinct.
        for app in apps {
            if let hue = previous[app.key], isFree(hue) { assigned[app.key] = hue }
        }
        // 2. Remaining apps: first icon hue that is free; otherwise the free-most hue nearest the icon's color.
        for app in apps where assigned[app.key] == nil {
            if let hue = app.candidates.first(where: isFree) {
                assigned[app.key] = normalized(hue)
                continue
            }
            let preferred = app.candidates.first ?? stableHue(for: app.key)
            assigned[app.key] = bestFreeHue(near: preferred, avoiding: Array(assigned.values))
        }
        return assigned
    }

    /// The hue (sampled every 1°) that maximizes distance to existing hues; ties go to the one nearest `preferred`.
    static func bestFreeHue(near preferred: Double, avoiding taken: [Double]) -> Double {
        guard !taken.isEmpty else { return normalized(preferred) }
        var best = normalized(preferred)
        var bestScore = -1.0
        for step in 0..<360 {
            let hue = Double(step) / 360
            let clearance = taken.map { hueDistance($0, hue) }.min()!
            // Clearance dominates; closeness to the preferred hue breaks ties.
            let score = clearance * 1000 - hueDistance(hue, preferred)
            if score > bestScore { bestScore = score; best = hue }
        }
        return best
    }

    /// A deterministic hue for apps whose icon has no color (FNV-1a hash of the key).
    public static func stableHue(for key: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Double(hash % 360) / 360
    }

    static func normalized(_ hue: Double) -> Double {
        let h = hue.truncatingRemainder(dividingBy: 1)
        return h < 0 ? h + 1 : h
    }
}
