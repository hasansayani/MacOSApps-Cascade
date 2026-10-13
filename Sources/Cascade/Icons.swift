import Cocoa
import CascadeCore
import UniformTypeIdentifiers

// MARK: - Menu bar icon

enum MenuBarIcons {
    static let size = NSSize(width: 18, height: 16)

    static func title(_ style: MenuBarIconStyle) -> String {
        switch style {
        case .cascade: return "Cascade"
        case .outline: return "Outline"
        case .cards: return "Cards"
        case .groups: return "Groups"
        case .solid: return "Solid"
        case .symbolStack: return "Stack"
        case .symbolLayers: return "Layers"
        case .symbolWindows: return "Windows"
        case .custom: return "Custom"
        }
    }

    private static let symbolNames: [MenuBarIconStyle: String] = [
        .symbolStack: "square.stack.3d.down.right",
        .symbolLayers: "square.3.layers.3d.down.right",
        .symbolWindows: "macwindow.on.rectangle",
    ]

    /// The icon to show for the given settings. Falls back to the default design if a custom image is missing.
    static func image(for settings: CascadeSettings) -> NSImage {
        image(settings.menuBarIcon, color: settings.menuBarIconColor, theme: settings.appIcon,
              customColor: settings.menuBarIconCustomColor, customTemplate: settings.customIconIsTemplate)
    }

    static func image(_ style: MenuBarIconStyle, color: MenuBarIconColor = .monochrome, theme: AppIconStyle = .ocean,
                      customColor: CascadeCore.RGBColor = CascadeSettings().menuBarIconCustomColor,
                      customTemplate: Bool = true) -> NSImage {
        let palette = Palette.make(color, theme: theme, custom: customColor)
        switch style {
        case .custom:
            guard let custom = CustomIconStore.load() else { return drawn(.cascade, palette: palette) }
            custom.isTemplate = customTemplate
            return custom
        case .symbolStack, .symbolLayers, .symbolWindows:
            var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            // Symbol layers run front to back: the front window gets the front color, as in the drawn designs.
            if let palette {
                config = config.applying(NSImage.SymbolConfiguration(paletteColors: Array(palette.accents.prefix(3).reversed())))
            }
            guard let symbol = NSImage(systemSymbolName: symbolNames[style]!, accessibilityDescription: "Cascade")?
                .withSymbolConfiguration(config) else { return drawn(.cascade, palette: palette) }
            symbol.isTemplate = palette == nil
            return symbol
        default:
            return drawn(style, palette: palette)
        }
    }

    static func title(_ color: MenuBarIconColor) -> String {
        switch color {
        case .multicolor: return "Multicolor"
        case .bright: return "Bright"
        case .dark: return "Dark"
        case .highContrast: return "High contrast"
        case .appTheme: return "App icon"
        case .custom: return "Custom"
        case .monochrome: return "Monochrome"
        }
    }

    /// How a colored icon is painted. nil (from `make`) means a monochrome template icon.
    struct Palette {
        /// Window colors, back to front (title bars, and outlines unless `outline` is set).
        let accents: [NSColor]
        /// Fixed outline color for every window (high contrast), instead of the accent.
        var outline: NSColor? = nil
        /// A thin edge around each window so dark or pale colors still read on any menu bar.
        var halo: NSColor? = nil

        private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }

        static func make(_ color: MenuBarIconColor, theme: AppIconStyle, custom: CascadeCore.RGBColor) -> Palette? {
            switch color {
            case .monochrome:
                return nil
            case .multicolor:
                // Saturated mid-tones that read on both light and dark menu bars.
                return Palette(accents: [rgb(0.20, 0.78, 0.35), rgb(0.04, 0.52, 1.00), rgb(1.00, 0.58, 0.00), rgb(1.00, 0.22, 0.37)])
            case .bright:
                // Neon; a soft dark edge keeps the pale ones visible on light menu bars.
                return Palette(accents: [rgb(0.25, 1.00, 0.30), rgb(0.00, 0.90, 1.00), rgb(1.00, 0.15, 0.85), rgb(1.00, 0.92, 0.00)],
                               halo: NSColor(white: 0, alpha: 0.22))
            case .dark:
                // Deep tones; a light edge keeps them visible on dark menu bars.
                return Palette(accents: [rgb(0.05, 0.42, 0.20), rgb(0.08, 0.20, 0.58), rgb(0.62, 0.08, 0.15), rgb(0.40, 0.10, 0.55)],
                               halo: NSColor(white: 1, alpha: 0.75))
            case .highContrast:
                return Palette(accents: [rgb(1.00, 0.84, 0.00), rgb(0.00, 0.85, 1.00), rgb(1.00, 0.10, 0.70), rgb(0.30, 1.00, 0.20)],
                               outline: .black, halo: .white)
            case .appTheme:
                return Palette(accents: AppIconRenderer.accentColors(theme))
            case .custom:
                return shades(of: rgb(custom.red, custom.green, custom.blue))
            }
        }

        /// Back-to-front shades of one color (lighter behind, the picked color in front), so the windows
        /// stay distinguishable. Very dark or very light picks get an edge so they read on any menu bar.
        static func shades(of color: NSColor) -> Palette {
            let c = color.usingColorSpace(.sRGB) ?? color
            let front = c
            let back = c.blended(withFraction: 0.45, of: .white) ?? c
            let middle = c.blended(withFraction: 0.22, of: .white) ?? c
            let deep = c.blended(withFraction: 0.3, of: .black) ?? c
            let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            let halo: NSColor? = luminance < 0.25 ? NSColor(white: 1, alpha: 0.75)
                : luminance > 0.8 ? NSColor(white: 0, alpha: 0.35) : nil
            return Palette(accents: [back, middle, front, deep], halo: halo)
        }
    }

    /// Hand-drawn designs. With no palette they are template images (drawn in black; macOS tints them to
    /// match the menu bar). With a palette, each window gets a white body and a colored outline and title bar.
    private static func drawn(_ style: MenuBarIconStyle, palette: Palette? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            func paint(_ i: Int) -> WindowPaint? {
                palette.map { WindowPaint(accent: $0.accents[i % $0.accents.count], outline: $0.outline, halo: $0.halo) }
            }
            switch style {
            case .outline:
                for i in 0..<3 {
                    window(NSRect(x: 1 + CGFloat(i) * 3, y: 1 + CGFloat(i) * 2.5, width: 10, height: 8.5), titleBar: false,
                           paint: paint(i))
                }
            case .cards:
                // A vertical stack: each card further back is narrower, like a deck seen from the front.
                for i in 0..<3 {
                    let inset = CGFloat(2 - i) * 1.5
                    window(NSRect(x: 2 + inset, y: 1 + CGFloat(i) * 3, width: 14 - inset * 2, height: 8.5), titleBar: true,
                           paint: paint(i))
                }
            case .groups:
                // Two small cascades side by side: cascade groups.
                for column in 0..<2 {
                    for i in 0..<2 {
                        let x = 0.75 + CGFloat(column) * 8.75 + CGFloat(i) * 2.5
                        window(NSRect(x: x, y: 2 + CGFloat(i) * 3, width: 5.5, height: 7), titleBar: true, radius: 1,
                               paint: paint(column * 2 + i))
                    }
                }
            case .solid:
                for i in 0..<3 {
                    let rect = NSRect(x: 1 + CGFloat(i) * 2.5, y: 1 + CGFloat(i) * 2.5, width: 11, height: 9)
                    window(rect, titleBar: i < 2, paint: paint(i), solid: i == 2)
                }
            default:   // .cascade
                for i in 0..<3 {
                    window(NSRect(x: 1 + CGFloat(i) * 2.5, y: 1 + CGFloat(i) * 2.5, width: 11, height: 9), titleBar: true,
                           paint: paint(i))
                }
            }
            return true
        }
        image.isTemplate = palette == nil
        image.accessibilityDescription = "Cascade"
        return image
    }

    private struct WindowPaint {
        let accent: NSColor
        let outline: NSColor?
        let halo: NSColor?
    }

    /// One window. Whatever is underneath is erased first, so back windows show only their exposed edges.
    private static func window(_ rect: NSRect, titleBar: Bool, radius: CGFloat = 1.5, paint: WindowPaint? = nil,
                               solid: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.current?.compositingOperation = .clear
        path.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        path.lineWidth = 1.2
        guard let paint else {
            // Template: black, tinted by macOS.
            NSColor.black.setStroke()
            NSColor.black.setFill()
            path.stroke()
            if solid { path.fill() }
            if titleBar { NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2.2)).fill() }
            return
        }
        if let halo = paint.halo {
            let edge = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            edge.lineWidth = 2.6
            halo.setStroke()
            edge.stroke()
        }
        (solid ? paint.accent : NSColor.white).setFill()
        path.fill()
        (paint.outline ?? paint.accent).setStroke()
        path.stroke()
        if titleBar {
            paint.accent.setFill()
            // Taller with a black outline, which otherwise covers most of the color.
            let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: paint.outline == nil ? 2.2 : 3.4)
            NSBezierPath(rect: bar).fill()
            if let outline = paint.outline {
                // Keep the outline crisp over the colored title bar.
                outline.setStroke()
                path.stroke()
            }
        }
    }
}

/// Stores the user's custom menu bar image, normalized to a small PNG in Application Support.
enum CustomIconStore {
    static let didChange = Notification.Name("CascadeCustomIconChanged")

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cascade", isDirectory: true).appendingPathComponent("menubar-icon.png")
    }

    static let allowedTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .pdf, .svg, .icns, .gif, .bmp]

    /// Loads the stored icon sized for the menu bar (18 pt tall, up to 24 pt wide).
    static func load() -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(18 / image.size.height, 24 / image.size.width)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return image
    }

    /// Lets the user pick an image and stores it. Returns false if they cancelled or it couldn't be read.
    @discardableResult
    static func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a Menu Bar Icon"
        panel.message = "Pick an image. Simple, single-color artwork on a transparent background works best."
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return false }
        do {
            try importImage(from: source)
            NotificationCenter.default.post(name: didChange, object: nil)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't use that image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    /// Re-renders any supported image (including PDF/SVG) into a 64 px tall PNG so the menu bar never
    /// has to decode a large or unusual file.
    static func importImage(from source: URL) throws {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let height: CGFloat = 64
        let width = min(max(height * image.size.width / image.size.height, 1), height * 4 / 3)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Fit (aspect-preserving) and center.
        let scale = min(width / image.size.width, height / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (width - drawn.width) / 2, y: (height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }
}

// MARK: - App icon

enum AppIconRenderer {
    static func title(_ style: AppIconStyle) -> String {
        switch style {
        case .ocean: return "Ocean"
        case .graphite: return "Graphite"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .grape: return "Grape"
        }
    }

    private struct Palette {
        let top: NSColor
        let bottom: NSColor
        let titleBars: [NSColor]
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    private static func palette(_ style: AppIconStyle) -> Palette {
        switch style {
        case .ocean:
            return Palette(top: rgb(0.16, 0.42, 0.95), bottom: rgb(0.08, 0.20, 0.55),
                           titleBars: [rgb(0.55, 0.70, 1.0), rgb(0.40, 0.60, 1.0), rgb(0.26, 0.50, 1.0)])
        case .graphite:
            return Palette(top: rgb(0.40, 0.42, 0.46), bottom: rgb(0.13, 0.14, 0.16),
                           titleBars: [rgb(0.80, 0.82, 0.86), rgb(0.64, 0.67, 0.72), rgb(0.47, 0.50, 0.56)])
        case .sunset:
            return Palette(top: rgb(1.0, 0.58, 0.25), bottom: rgb(0.80, 0.18, 0.32),
                           titleBars: [rgb(1.0, 0.86, 0.55), rgb(1.0, 0.72, 0.42), rgb(1.0, 0.56, 0.36)])
        case .forest:
            return Palette(top: rgb(0.22, 0.74, 0.46), bottom: rgb(0.05, 0.34, 0.25),
                           titleBars: [rgb(0.72, 0.93, 0.76), rgb(0.52, 0.86, 0.62), rgb(0.32, 0.76, 0.52)])
        case .grape:
            return Palette(top: rgb(0.64, 0.38, 0.96), bottom: rgb(0.30, 0.12, 0.56),
                           titleBars: [rgb(0.86, 0.77, 1.0), rgb(0.76, 0.62, 1.0), rgb(0.63, 0.47, 1.0)])
        }
    }

    /// Strong versions of a theme's colors (back to front) for the menu bar icon: saturated and bright
    /// enough to read on light and dark menu bars. Graphite stays gray on purpose.
    static func accentColors(_ style: AppIconStyle) -> [NSColor] {
        let p = palette(style)
        return [p.top, p.titleBars[1], p.titleBars[2], p.bottom].map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if style == .graphite { return NSColor(hue: h, saturation: s, brightness: min(max(b, 0.45), 0.6), alpha: 1) }
            return NSColor(hue: h, saturation: max(s, 0.75), brightness: min(max(b, 0.8), 0.95), alpha: 1)
        }
    }

    /// The app icon at any size. Drawn in a 1024-point space: a gradient squircle with three cascaded windows.
    static func image(_ style: AppIconStyle, size: CGFloat = 512) -> NSImage {
        let colors = palette(style)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let scale = size / 1024
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()

            let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                          xRadius: 185, yRadius: 185)
            NSGradient(starting: colors.top, ending: colors.bottom)?.draw(in: background, angle: 90)

            for i in 0..<3 {
                let offset = CGFloat(i) * 110
                let rect = NSRect(x: 215 + offset, y: 230 + offset, width: 380, height: 330)
                let window = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 30 * scale
                shadow.shadowColor = .black.withAlphaComponent(0.35)
                shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
                shadow.set()
                NSColor.white.setFill()
                window.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSGraphicsContext.saveGraphicsState()
                window.addClip()
                colors.titleBars[i].setFill()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 70)).fill()
                NSGraphicsContext.restoreGraphicsState()

                for (j, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.minX + 26 + CGFloat(j) * 38, y: rect.minY + 22,
                                                width: 26, height: 26)).fill()
                }
            }
            return true
        }
    }

    /// Writes a PNG of the icon (used by build.sh to make the bundle's AppIcon.icns).
    static func writePNG(_ style: AppIconStyle, pixels: Int, to url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(style, size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
