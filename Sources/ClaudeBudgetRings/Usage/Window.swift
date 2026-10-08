import Foundation

/// The rolling limit windows the usage endpoint reports. Raw values are the
/// JSON keys in the `/api/oauth/usage` response.
enum WindowKind: String, CaseIterable, Codable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"

    /// The two windows shown as rings. Sonnet is decoded but not displayed.
    static let displayed: [WindowKind] = [.fiveHour, .sevenDay]

    var nominalLength: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay, .sevenDaySonnet: return 7 * 24 * 3600
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .sevenDaySonnet: return "7d S"
        }
    }

    /// Whether the true length is learned from observed resets (see
    /// `WindowLengthLearner`) rather than taken as nominal.
    var isLearnable: Bool { self != .fiveHour }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .sevenDay: return "7-day window"
        case .sevenDaySonnet: return "7-day Sonnet"
        }
    }
}

/// One authoritative reading from the API.
struct WindowReading: Equatable, Sendable {
    let kind: WindowKind
    /// Percentage of the window's budget used, 0–100 (can exceed 100 with overage).
    let utilization: Double
    let resetsAt: Date
    /// The window's start, when the API states it (the weekly window does, via
    /// `seven_day_breakdown.window_started_at`). Beats any learned length.
    var startsAt: Date? = nil

    /// Length and provisional flag: the stated start if we have one, else the
    /// learner's best estimate.
    func length(using learner: WindowLengthLearner) -> (length: TimeInterval, isProvisional: Bool) {
        if let startsAt {
            let stated = resetsAt.timeIntervalSince(startsAt)
            if stated >= 3600 { return (stated, false) }
        }
        return learner.length(for: kind)
    }
}

/// Where a window stands against a straight-line burn that lands on exactly
/// 100% at the reset instant.
struct Pace: Equatable, Sendable {
    let utilization: Double
    /// Where utilisation "should" be right now for a perfectly even burn, 0–100.
    let ideal: Double
    /// Fraction of the window elapsed, 0–1.
    let elapsed: Double
    let length: TimeInterval
    let remaining: TimeInterval
    /// True while the window length is a nominal guess rather than observed.
    let isProvisional: Bool

    /// How far utilisation is past (+) or short of (−) the ideal line. The goal
    /// is to finish at exactly 100%, so zero is the target in both directions:
    /// ahead means ease off before the limit bites, behind means budget is going
    /// unused.
    var delta: Double { utilization - ideal }
    /// Burning faster than an even pace.
    var isAhead: Bool { delta > 0 }

    /// Budget still available before the reset.
    var leftToUse: Double { max(0, 100 - utilization) }

    /// Where utilisation lands at reset if the current average rate holds.
    /// Nil early in a window, where a handful of requests would extrapolate wildly.
    var projectedAtReset: Double? {
        guard elapsed >= Pace.minElapsedForProjection else { return nil }
        return utilization / elapsed
    }

    /// Seconds until 100% at the current average rate, or nil if that falls
    /// after the reset (or nothing has been used yet).
    var timeToExhaustion: TimeInterval? {
        guard elapsed >= Pace.minElapsedForProjection, utilization > 0 else { return nil }
        if utilization >= 100 { return 0 }
        let ratePerSecond = utilization / (elapsed * length)
        let t = (100 - utilization) / ratePerSecond
        return t < remaining ? t : nil
    }

    static let minElapsedForProjection = 0.05

    static func compute(
        _ reading: WindowReading,
        length: TimeInterval,
        isProvisional: Bool,
        now: Date
    ) -> Pace {
        let start = reading.resetsAt.addingTimeInterval(-length)
        let raw = now.timeIntervalSince(start) / length
        let elapsed = min(max(raw, 0), 1)
        return Pace(
            utilization: reading.utilization,
            ideal: elapsed * 100,
            elapsed: elapsed,
            length: length,
            remaining: max(0, reading.resetsAt.timeIntervalSince(now)),
            isProvisional: isProvisional
        )
    }
}

/// Learns the weekly windows' true length from consecutive `resets_at` values.
///
/// The "7-day" window has been reported to reset on shorter cycles for some
/// accounts, so rather than trust the name we watch `resets_at` jump and record
/// the gap. A window only opens on first use after the previous one closed, so
/// a gap is an upper bound on the length, not the length itself: we keep the
/// smallest gap seen, which converges as soon as two windows abut. Until one
/// jump has been seen, the nominal length is used and the pace is marked
/// provisional.
///
/// The 5-hour window is not learned. Its length is reliable, and because idle
/// time between sessions is routine its gaps would teach nothing but noise.
struct WindowLengthLearner {
    private let defaults: UserDefaults
    private let prefix = "windowLength."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func length(for kind: WindowKind) -> (length: TimeInterval, isProvisional: Bool) {
        guard kind.isLearnable else { return (kind.nominalLength, false) }
        let learned = defaults.double(forKey: prefix + kind.rawValue + ".learned")
        if learned > 0 { return (learned, false) }
        return (kind.nominalLength, true)
    }

    /// Record a fresh reading. Returns the newly learned length if this reading
    /// revealed a reset boundary.
    @discardableResult
    func observe(_ reading: WindowReading) -> TimeInterval? {
        guard reading.kind.isLearnable else { return nil }
        let key = prefix + reading.kind.rawValue + ".lastResetsAt"
        let new = reading.resetsAt.timeIntervalSince1970
        let previous = defaults.double(forKey: key)
        defaults.set(new, forKey: key)

        guard previous > 0 else { return nil }
        let gap = new - previous
        // `resets_at` jitters by fractions of a second between polls within one
        // window; only a jump of at least an hour is a real rollover. The name
        // is an upper bound on the length, so a gap beyond it means we missed
        // whole windows and can't tell how many: it teaches nothing.
        guard gap >= 3600, gap <= reading.kind.nominalLength + 3600 else { return nil }

        // Round to the nearest hour: the real boundaries are on the hour and
        // the fractional-second jitter shouldn't leak into the learned value.
        let rounded = (gap / 3600).rounded() * 3600
        let learnedKey = prefix + reading.kind.rawValue + ".learned"
        let existing = defaults.double(forKey: learnedKey)
        let best = existing > 0 ? min(existing, rounded) : rounded
        defaults.set(best, forKey: learnedKey)
        return best
    }

    func reset() {
        for kind in WindowKind.allCases {
            for suffix in [".learned", ".lastResetsAt"] {
                defaults.removeObject(forKey: prefix + kind.rawValue + suffix)
            }
        }
    }
}
