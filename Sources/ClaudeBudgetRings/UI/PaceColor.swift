import AppKit
import SwiftUI

/// Maps pace delta (percent ahead of or behind ideal) to a colour.
///
/// The aim is to land on exactly 100% at the reset, so on pace is the good
/// state (green). Behind drifts to blue: budget is going unused, use more.
/// Ahead drifts to amber then red: you'll hit the limit early, ease off.
/// Colour carries pace only; how full the window is shows as arc length.
/// Anchors are interpolated so the ring drifts smoothly rather than jumping.
enum PaceColor {
    /// (delta in %, heat in −1…1). Negative heat is cool = behind pace.
    static let heatAnchors: [(Double, Double)] = [
        (-10, -1), (-3, -0.35), (0, 0), (3, 0.35), (12, 1),
    ]

    static func heat(delta: Double) -> Double {
        interpolate(delta, heatAnchors)
    }

    /// (heat, r, g, b) stops.
    private static let stops: [(Double, Double, Double, Double)] = [
        (-1.00, 0.30, 0.45, 0.98), // blue   – well behind: use more
        (-0.35, 0.28, 0.72, 0.86), // teal   – a little behind
        ( 0.00, 0.20, 0.78, 0.40), // green  – on pace
        ( 0.35, 0.98, 0.70, 0.18), // amber  – a little ahead
        ( 1.00, 0.95, 0.28, 0.26), // red    – well ahead: ease off
    ]

    static func nsColor(delta: Double) -> NSColor {
        let h = heat(delta: delta)
        let s = stops
        let r = interpolate(h, s.map { ($0.0, $0.1) })
        let g = interpolate(h, s.map { ($0.0, $0.2) })
        let b = interpolate(h, s.map { ($0.0, $0.3) })
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func color(delta: Double) -> Color {
        Color(nsColor: nsColor(delta: delta))
    }

    /// Human phrasing of where a delta sits.
    static func verdict(delta: Double) -> String {
        switch delta {
        case ..<(-10): return "Well behind: use more"
        case ..<(-3): return "Behind: pick it up"
        case ...3: return "On pace"
        case ...12: return "Ahead: ease off a little"
        default: return "Well ahead: ease off"
        }
    }

    /// Piecewise-linear interpolation, clamped at both ends.
    static func interpolate(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
            let t = (x - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * t
        }
        return last.1
    }
}
