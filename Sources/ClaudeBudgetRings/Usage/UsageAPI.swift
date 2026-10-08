import Foundation

/// A full reading of every window the endpoint returned.
struct UsageSnapshot: Equatable, Sendable {
    let windows: [WindowKind: WindowReading]
    let fetchedAt: Date

    subscript(kind: WindowKind) -> WindowReading? { windows[kind] }
}

enum UsageAPIError: Error, Equatable {
    /// HTTP 429. `retryAfter` is the server's hint in seconds, if it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// HTTP 401/403: the token is no longer accepted.
    case unauthorized
    case http(status: Int)
    /// The body parsed as JSON but contained none of the windows we display.
    case unrecognisedShape
    case transport(String)
}

/// Client for the undocumented `/api/oauth/usage` endpoint that Claude Code's
/// own `/usage` command reads.
struct UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    var session: URLSession = .shared

    /// Fetch and decode. Returns the raw body alongside for `--probe --raw`.
    func fetch(accessToken: String, now: Date = Date()) async throws -> (UsageSnapshot, Data) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-budget-rings/1.0", forHTTPHeaderField: "User-Agent")
        // Never serve a cached reading; the poller owns freshness.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.transport("Non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return (try Self.decode(data, fetchedAt: now), data)
        case 429:
            throw UsageAPIError.rateLimited(retryAfter: Self.retryAfter(from: http, now: now))
        case 401, 403:
            throw UsageAPIError.unauthorized
        default:
            throw UsageAPIError.http(status: http.statusCode)
        }
    }

    /// Decode defensively: any top-level key whose value looks like
    /// `{utilization, resets_at}` and names a known window is kept; everything
    /// else (`extra_usage`, future additions, nulls) is ignored.
    static func decode(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw UsageAPIError.unrecognisedShape
        }
        var windows: [WindowKind: WindowReading] = [:]
        for (key, payload) in envelope.windows {
            guard let kind = WindowKind(rawValue: key),
                  let resetsAt = LenientISO8601.date(from: payload.resets_at)
            else { continue }
            windows[kind] = WindowReading(kind: kind, utilization: payload.utilization, resetsAt: resetsAt)
        }
        if let started = envelope.sevenDayStartedAt.flatMap(LenientISO8601.date(from:)),
           let weekly = windows[.sevenDay] {
            windows[.sevenDay] = WindowReading(kind: .sevenDay, utilization: weekly.utilization,
                                               resetsAt: weekly.resetsAt, startsAt: started)
        }
        guard WindowKind.displayed.contains(where: { windows[$0] != nil }) else {
            throw UsageAPIError.unrecognisedShape
        }
        return UsageSnapshot(windows: windows, fetchedAt: fetchedAt)
    }

    static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        // HTTP-date form.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    private struct WindowPayload: Decodable {
        let utilization: Double
        let resets_at: String
    }

    private struct Breakdown: Decodable {
        let window_started_at: String?
    }

    private struct Envelope: Decodable {
        var windows: [String: WindowPayload] = [:]
        var sevenDayStartedAt: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            for key in container.allKeys {
                if let payload = try? container.decode(WindowPayload.self, forKey: key) {
                    windows[key.stringValue] = payload
                }
            }
            if let key = AnyKey(stringValue: "seven_day_breakdown"),
               let breakdown = try? container.decode(Breakdown.self, forKey: key) {
                sevenDayStartedAt = breakdown.window_started_at
            }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// ISO-8601 parsing that tolerates the endpoint's microsecond precision
/// (`2026-04-11T07:00:00.528743+00:00`), which `ISO8601DateFormatter` rejects.
enum LenientISO8601 {
    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: string) { return d }

        // Trim the fraction to milliseconds and retry.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string.index(after: dot)
        let fractionEnd = string[afterDot...].firstIndex(where: { !$0.isNumber }) ?? string.endIndex
        let digits = string[afterDot..<fractionEnd]
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let trimmed = String(string[..<afterDot]) + millis + String(string[fractionEnd...])
        return withFraction.date(from: trimmed)
    }
}
