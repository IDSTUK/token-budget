import Foundation

/// Decides whether a request to the usage endpoint may go out right now.
///
/// Every path that wants a fetch — the timer, opening the popover, waking from
/// sleep — asks this one gate, so the floor and backoff can't be bypassed by a
/// trigger someone adds later. Pure value type: time is passed in, which keeps
/// it testable.
struct FetchGate: Equatable {
    /// Never two requests closer together than this.
    static let minimumSpacing: TimeInterval = 60
    /// Never more than this many requests in any rolling hour.
    static let hourlyCap = 20
    /// Backoff ladder for a 429 without a usable Retry-After.
    static let backoffLadder: [TimeInterval] = [10, 20, 40, 60].map { $0 * 60 }

    private(set) var recentRequests: [Date] = []
    private(set) var blockedUntil: Date?
    private(set) var consecutiveRateLimits = 0

    enum Verdict: Equatable {
        case allowed
        case wait(until: Date, reason: Reason)
    }

    enum Reason: Equatable {
        case spacing, hourlyCap, rateLimited
    }

    func verdict(now: Date) -> Verdict {
        if let blockedUntil, now < blockedUntil {
            return .wait(until: blockedUntil, reason: .rateLimited)
        }
        if let last = recentRequests.last, now.timeIntervalSince(last) < Self.minimumSpacing {
            return .wait(until: last.addingTimeInterval(Self.minimumSpacing), reason: .spacing)
        }
        let hourAgo = now.addingTimeInterval(-3600)
        let inLastHour = recentRequests.filter { $0 > hourAgo }
        if inLastHour.count >= Self.hourlyCap, let oldest = inLastHour.first {
            return .wait(until: oldest.addingTimeInterval(3600), reason: .hourlyCap)
        }
        return .allowed
    }

    mutating func recordRequest(at now: Date) {
        let hourAgo = now.addingTimeInterval(-3600)
        recentRequests.removeAll { $0 <= hourAgo }
        recentRequests.append(now)
    }

    mutating func recordSuccess() {
        consecutiveRateLimits = 0
        blockedUntil = nil
    }

    /// Returns when the next attempt may go out.
    @discardableResult
    mutating func recordRateLimit(retryAfter: TimeInterval?, now: Date) -> Date {
        let ladder = Self.backoffLadder[min(consecutiveRateLimits, Self.backoffLadder.count - 1)]
        consecutiveRateLimits += 1
        // Trust the server's hint, but never retry sooner than the spacing floor
        // and never wait less than the ladder says once we've been hit twice.
        let wait: TimeInterval
        if let retryAfter {
            wait = max(retryAfter, Self.minimumSpacing, consecutiveRateLimits > 1 ? ladder : 0)
        } else {
            wait = ladder
        }
        let until = now.addingTimeInterval(wait)
        blockedUntil = until
        return until
    }
}
