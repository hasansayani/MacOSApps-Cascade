import CoreGraphics

// All rects here are in top-left-origin ("AX") screen coordinates.

public enum GroupGrid {
    /// Automatic column count: one cascade group per ~1280pt of width (1 on laptops, 2–4 on large displays).
    public static func autoColumns(forWidth width: CGFloat) -> Int {
        min(max(Int(width / 1280), 1), CascadeSettings.maxColumns)
    }

    public static func dimensions(for area: CGRect, settings: CascadeSettings) -> (columns: Int, rows: Int) {
        let columns = settings.columns == 0 ? autoColumns(forWidth: area.width) : settings.columns
        return (max(columns, 1), max(settings.rows, 1))
    }

    /// Splits `area` into `count` regions laid out row-major on a grid at most `columns` wide.
    /// The last row's regions stretch to fill the full width.
    public static func regions(count: Int, columns: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = max(1, min(columns, count))
        let rows = (count + columns - 1) / columns
        let rowHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var result: [CGRect] = []
        for row in 0..<rows {
            let inRow = min(columns, count - row * columns)
            let width = (area.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            for col in 0..<inRow {
                result.append(CGRect(x: area.minX + CGFloat(col) * (width + gap),
                                     y: area.minY + CGFloat(row) * (rowHeight + gap),
                                     width: width, height: rowHeight).integral)
            }
        }
        return result
    }
}

public enum CascadeLayout {
    /// In auto size mode windows never shrink below this fraction of their region.
    public static let minimumAutoFraction: CGFloat = 0.5
    /// Smallest window the layout will produce.
    public static let minimumSize = CGSize(width: 240, height: 160)
    /// Smallest step used when a very large stack has to be compressed to stay exposed.
    public static let minimumStep: CGFloat = 8

    /// Equal-sized frames stepping diagonally down/right inside `region`, first frame at the back.
    ///
    /// When the stack is taller than the region allows, it continues in additional passes, each starting
    /// to the right of the previous pass's diagonal so that every window keeps an exposed corner.
    public static func frames(count: Int, in region: CGRect, settings: CascadeSettings) -> [CGRect] {
        guard count > 0, region.width > 0, region.height > 0 else { return [] }
        var stepX = CGFloat(settings.revealLeft)
        let stepY = CGFloat(settings.revealTop)
        let steps = CGFloat(count - 1)

        var size: CGSize
        switch settings.sizeMode {
        case .auto:
            size = CGSize(width: max(region.width - steps * stepX, region.width * minimumAutoFraction),
                          height: max(region.height - steps * stepY, region.height * minimumAutoFraction))
        case .custom:
            size = CGSize(width: region.width * CGFloat(settings.widthPercent) / 100,
                          height: region.height * CGFloat(settings.heightPercent) / 100)
        }
        size = clamp(size, to: region.size)

        // How many windows fit down the diagonal.
        func fit(_ room: CGFloat, _ step: CGFloat) -> Int { step <= 0 ? count : Int((room / step).rounded(.down)) + 1 }
        let perPass = max(1, min(count, fit(region.height - size.height, stepY), fit(region.width - size.width, stepX)))
        let passes = (count + perPass - 1) / perPass
        var passShift: CGFloat = 0

        if passes > 1 {
            // Each pass starts one step past the previous pass's last window, keeping its corner exposed.
            func extentWidth(_ step: CGFloat) -> CGFloat { CGFloat((passes - 1) * perPass + perPass - 1) * step }
            let minWidth = min(minimumSize.width, region.width)
            size.width = min(size.width, max(minWidth, region.width - extentWidth(stepX)))
            if extentWidth(stepX) + size.width > region.width {
                // Still too wide: compress the horizontal step.
                stepX = max(minimumStep, (region.width - size.width) / CGFloat(passes * perPass - 1))
            }
            passShift = CGFloat(perPass) * stepX
        }

        // Center the whole stack inside the region (matters for custom sizes and short stacks).
        let extent = CGSize(width: size.width + CGFloat(perPass - 1) * stepX + CGFloat(passes - 1) * passShift,
                            height: size.height + CGFloat(perPass - 1) * stepY)
        let origin = CGPoint(x: region.minX + max(0, (region.width - extent.width) / 2),
                             y: region.minY + max(0, (region.height - extent.height) / 2))

        // Round each origin, not the rect, so every window keeps exactly the same size.
        let finalSize = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        return (0..<count).map { i in
            let k = CGFloat(i % perPass)
            let pass = CGFloat(i / perPass)
            return CGRect(origin: CGPoint(x: (origin.x + pass * passShift + k * stepX).rounded(.down),
                                          y: (origin.y + k * stepY).rounded(.down)),
                          size: finalSize)
        }
    }

    private static func clamp(_ size: CGSize, to bounds: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, min(minimumSize.width, bounds.width)), bounds.width),
               height: min(max(size.height, min(minimumSize.height, bounds.height)), bounds.height))
    }
}
