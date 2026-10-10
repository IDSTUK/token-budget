import AppKit

/// Draws the budget gauges: rings in the popover, bars in the menu bar.
///
/// Rendered through `NSImage(size:flipped:drawingHandler:)`, so the handler
/// runs at draw time in the destination's appearance. The rings use
/// `labelColor`; the menu bar bars use `Chrome.menuBarInk`, which matches the
/// template icons beside them (the menu bar resolves `labelColor` to grey).
enum RingRenderer {
    struct Style {
        var lineWidth: CGFloat
        /// How far the pace tick overhangs the ring on each side.
        var tickOverhang: CGFloat
        var tickWidth: CGFloat
        var label: String?
        var labelSize: CGFloat
    }

    static let popover = Style(lineWidth: 11, tickOverhang: 5, tickWidth: 3, label: nil, labelSize: 0)

    static func image(pace: Pace?, stale: Bool, diameter: CGFloat, style: Style) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect, pace: pace, stale: stale, style: style)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(in ctx: CGContext, rect: CGRect, pace: Pace?, stale: Bool, style: Style) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Leave room for the tick to overhang without clipping.
        let radius = min(rect.width, rect.height) / 2 - style.lineWidth / 2 - style.tickOverhang
        guard radius > 0 else { return }

        // Angles: 12 o'clock is the start, running clockwise.
        func angle(_ fraction: Double) -> CGFloat { .pi / 2 - CGFloat(fraction) * 2 * .pi }

        ctx.setLineCap(.round)

        // Track.
        ctx.setLineWidth(style.lineWidth)
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(pace == nil ? 0.35 : 0.18).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        guard let pace else { return }

        // Utilisation arc.
        let used = min(max(pace.utilization / 100, 0), 1)
        if used > 0.001 {
            let colour = stale
                ? NSColor.labelColor.withAlphaComponent(0.4)
                : PaceColor.nsColor(delta: pace.delta)
            ctx.setStrokeColor(colour.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(used), clockwise: true)
            ctx.strokePath()
        }

        // Pace tick: where an even burn would be now.
        let a = angle(min(max(pace.ideal / 100, 0), 1))
        let inner = radius - style.lineWidth / 2 - style.tickOverhang
        let outer = radius + style.lineWidth / 2 + style.tickOverhang
        let p0 = CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner)
        let p1 = CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer)

        // Punch a transparent gap either side of the tick so it stays legible
        // where it crosses the coloured arc, whatever the menu bar is showing
        // behind it. Every caller draws into its own image, so clearing only
        // ever erases the ring itself.
        ctx.setLineCap(.butt)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(style.tickWidth + max(1.2, style.tickWidth * 0.9))
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(style.tickWidth)
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
    }

    /// How the menu bar arranges the windows: thin bars stacked one above the
    /// other, or full-height bars side by side.
    enum MenuBarLayout: String, CaseIterable {
        case stacked, sideBySide
        static let key = "menuBarLayout"
        static var current: MenuBarLayout {
            UserDefaults.standard.string(forKey: key).flatMap(MenuBarLayout.init) ?? .stacked
        }
        var title: String { self == .stacked ? "Stacked" : "Side by side" }
    }

    private struct Metrics {
        var fontSize: CGFloat
        var barWidth: CGFloat
        var barHeight: CGFloat
        var tickWidth: CGFloat
        var gap: CGFloat
    }

    /// The status item image: for each window a label ("5H"), a horizontal
    /// square-ended bar like the panel's, then the percentage used. Fill is how
    /// much is used, its colour is pace, and the tick marks the ideal level.
    static func menuBarImage(items: [(label: String, pace: Pace?)], stale: Bool,
                             layout: MenuBarLayout = .current) -> NSImage {
        let m = layout == .stacked
            ? Metrics(fontSize: 8, barWidth: 46, barHeight: 5, tickWidth: 1.5, gap: 3)
            : Metrics(fontSize: 11, barWidth: 56, barHeight: 13, tickWidth: 2, gap: 4)
        let attrs = labelAttributes(size: m.fontSize)
        let height: CGFloat = 22
        // One space character, so the two windows read like a sentence.
        let itemGap = NSAttributedString(string: " ", attributes: attrs).size().width
        let labelWidth = ceil(items.map { NSAttributedString(string: $0.label, attributes: attrs).size().width }.max() ?? 0)
        let percents = items.map { item in
            item.pace.map { "\(Int(min(max($0.utilization, 0), 100).rounded()))%" } ?? "–"
        }
        // Each percentage takes only its own width, so no dead space pads the
        // gap after it. Stacked rows share the widest, to keep them aligned.
        var percentWidths = percents.map { ceil(NSAttributedString(string: $0, attributes: attrs).size().width) }
        if layout == .stacked { percentWidths = percentWidths.map { _ in percentWidths.max() ?? 0 } }
        let itemWidths = percentWidths.map { labelWidth + m.gap + m.barWidth + m.gap + $0 }
        let rows = layout == .stacked ? items.count : 1
        let rowHeight = height / CGFloat(max(rows, 1))
        let width = layout == .stacked
            ? itemWidths.max() ?? 0
            : itemWidths.reduce(0, +) + CGFloat(max(0, items.count - 1)) * itemGap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Resolve the ink here, in the menu bar's appearance; `attrs` above is only for measuring.
            let attrs = labelAttributes(size: m.fontSize)
            var x: CGFloat = 0
            for (i, item) in items.enumerated() {
                // Stacked: first item on top. Side by side: first on the left.
                let row = layout == .stacked ? i : 0
                let cell = CGRect(x: x, y: height - CGFloat(row + 1) * rowHeight, width: itemWidths[i], height: rowHeight)
                if layout == .sideBySide { x += itemWidths[i] + itemGap }
                drawLabel(item.label, attrs: attrs,
                          in: CGRect(x: cell.minX, y: cell.minY, width: labelWidth, height: cell.height))
                let bar = CGRect(x: cell.minX + labelWidth + m.gap, y: cell.midY - m.barHeight / 2,
                                 width: m.barWidth, height: m.barHeight)
                drawBar(in: ctx, rect: bar, pace: item.pace, stale: stale, tickWidth: m.tickWidth)
                drawLabel(percents[i], attrs: attrs,
                          in: CGRect(x: bar.maxX + m.gap, y: cell.minY, width: percentWidths[i], height: cell.height),
                          alignRight: false)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func labelAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold), .foregroundColor: Chrome.menuBarInk()]
    }

    /// Bold text hugging its bar, centred on the row.
    private static func drawLabel(_ text: String, attrs: [NSAttributedString.Key: Any], in rect: CGRect,
                                  alignRight: Bool = true) {
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let x = alignRight ? rect.maxX - size.width : rect.minX
        s.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
    }

    /// Square-ended track with a pace-coloured fill and an even-burn tick, matching
    /// the panel's `BurnBar`.
    static func drawBar(in ctx: CGContext, rect: CGRect, pace: Pace?, stale: Bool, tickWidth: CGFloat) {
        // Barely rounded: square ends read more precisely than a capsule.
        let radius = min(1, rect.height / 2)
        ctx.setFillColor(Chrome.menuBarInk(opacity: pace == nil ? 0.35 : 0.22).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        guard let pace else { return }

        let used = min(max(pace.utilization / 100, 0), 1)
        if used > 0.001 {
            let colour = stale
                ? Chrome.menuBarInk(opacity: 0.4)
                : PaceColor.nsColor(delta: pace.delta)
            ctx.setFillColor(colour.cgColor)
            // Never narrower than a sliver, so a few percent still shows.
            let w = max(1.5, rect.width * CGFloat(used))
            ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        // Even-burn tick, overhanging the bar, with a transparent gap either
        // side so it reads over the fill whatever is behind the menu bar.
        let overhang: CGFloat = 2
        let ideal = CGFloat(min(max(pace.ideal / 100, 0), 1))
        let x = min(max(rect.minX + rect.width * ideal, rect.minX + tickWidth / 2), rect.maxX - tickWidth / 2)
        let tick = CGRect(x: x - tickWidth / 2, y: rect.minY - overhang, width: tickWidth, height: rect.height + 2 * overhang)

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(tick.insetBy(dx: -1, dy: 0))
        ctx.restoreGState()

        ctx.setFillColor(Chrome.menuBarInk().cgColor)
        ctx.addPath(CGPath(roundedRect: tick, cornerWidth: tickWidth / 2, cornerHeight: tickWidth / 2, transform: nil))
        ctx.fillPath()
    }
}
