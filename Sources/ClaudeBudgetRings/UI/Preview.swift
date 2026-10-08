import AppKit

/// `--preview out.png`: renders sample rings in light and dark appearances so
/// the visuals can be checked without signing in or touching the network.
enum Preview {
    static func render(to url: URL) {
        func pace(_ u: Double, elapsed: Double = 0.5) -> Pace {
            let length: TimeInterval = 5 * 3600
            let r = WindowReading(kind: .fiveHour, utilization: u,
                                  resetsAt: Date().addingTimeInterval(length * (1 - elapsed)))
            return Pace.compute(r, length: length, isProvisional: false, now: Date())
        }
        let samples: [(String, Pace?, Bool)] = [
            ("25% behind", pace(25), false),
            ("6% behind", pace(44), false),
            ("on pace", pace(50), false),
            ("8% ahead", pace(58), false),
            ("30% ahead", pace(80), false),
            ("stale", pace(40), true),
            ("no data", nil, false),
        ]

        let cell: CGFloat = 260, big: CGFloat = 110
        let width = cell * CGFloat(samples.count)
        let height: CGFloat = 2 * 225
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        for (row, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let appearance = NSAppearance(named: appearanceName)!
            appearance.performAsCurrentDrawingAppearance {
                let y0 = height - CGFloat(row + 1) * 225
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: y0, width: width, height: 225).fill()
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * cell
                    RingRenderer.image(pace: sample.1, stale: sample.2,
                                       diameter: big, style: RingRenderer.popover)
                        .draw(in: NSRect(x: x + (cell - big) / 2, y: y0 + 100, width: big, height: big))
                    // Menu-bar-size pair, as it would sit in the bar, in each layout.
                    for (j, layout) in RingRenderer.MenuBarLayout.allCases.enumerated() {
                        let bar = RingRenderer.menuBarImage(items: [("5H", sample.1), ("7D", pace(30, elapsed: 0.4))],
                                                            stale: sample.2, layout: layout)
                        bar.draw(in: NSRect(x: x + (cell - bar.size.width) / 2, y: y0 + 64 - CGFloat(j) * 28,
                                            width: bar.size.width, height: bar.size.height))
                    }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.labelColor,
                    ]
                    let label = NSAttributedString(string: sample.0, attributes: attrs)
                    label.draw(at: NSPoint(x: x + (cell - label.size().width) / 2, y: y0 + 8))
                }
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { print("render failed"); exit(1) }
        try! png.write(to: url)
        print("wrote \(url.path)")
    }
}
