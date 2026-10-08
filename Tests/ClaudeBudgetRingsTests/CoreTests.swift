import XCTest
@testable import ClaudeBudgetRings

final class PaceTests: XCTestCase {
    let reset = Date(timeIntervalSince1970: 1_800_000_000)
    let fiveHours: TimeInterval = 5 * 3600

    func reading(_ u: Double, kind: WindowKind = .fiveHour) -> WindowReading {
        WindowReading(kind: kind, utilization: u, resetsAt: reset)
    }

    func testMidWindowUnderPaceIsBehind() {
        // 2.5h into a 5h window: ideal is 50%.
        let now = reset.addingTimeInterval(-2.5 * 3600)
        let p = Pace.compute(reading(30), length: fiveHours, isProvisional: false, now: now)
        XCTAssertEqual(p.elapsed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.ideal, 50, accuracy: 1e-9)
        XCTAssertEqual(p.delta, -20, accuracy: 1e-9)
        XCTAssertFalse(p.isAhead)
        XCTAssertEqual(p.leftToUse, 70)
        XCTAssertEqual(p.remaining, 2.5 * 3600, accuracy: 1e-6)
        XCTAssertEqual(p.projectedAtReset!, 60, accuracy: 1e-9)
        XCTAssertNil(p.timeToExhaustion, "60% at reset never hits 100%")
    }

    func testOverPaceProjectsExhaustionBeforeReset() {
        // 1h in (20% elapsed), 40% used: rate 40%/h, so 60% more takes 1.5h, before the 4h remaining.
        let now = reset.addingTimeInterval(-4 * 3600)
        let p = Pace.compute(reading(40), length: fiveHours, isProvisional: false, now: now)
        XCTAssertEqual(p.delta, 20, accuracy: 1e-9)
        XCTAssertTrue(p.isAhead)
        XCTAssertEqual(p.timeToExhaustion!, 1.5 * 3600, accuracy: 1e-6)
        XCTAssertEqual(p.projectedAtReset!, 200, accuracy: 1e-9)
    }

    func testClampsOutsideWindow() {
        let before = Pace.compute(reading(0), length: fiveHours, isProvisional: false,
                                  now: reset.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(before.elapsed, 0)
        XCTAssertEqual(before.ideal, 0)
        let after = Pace.compute(reading(80), length: fiveHours, isProvisional: false,
                                 now: reset.addingTimeInterval(60))
        XCTAssertEqual(after.elapsed, 1)
        XCTAssertEqual(after.remaining, 0)
    }

    func testNoProjectionEarlyInWindow() {
        // 3% elapsed: two requests would extrapolate to nonsense.
        let now = reset.addingTimeInterval(-fiveHours * 0.97)
        let p = Pace.compute(reading(5), length: fiveHours, isProvisional: false, now: now)
        XCTAssertNil(p.projectedAtReset)
        XCTAssertNil(p.timeToExhaustion)
    }

    func testAtLimitExhaustionIsNow() {
        let now = reset.addingTimeInterval(-3600)
        let p = Pace.compute(reading(100), length: fiveHours, isProvisional: false, now: now)
        XCTAssertEqual(p.timeToExhaustion, 0)
    }
}

final class LearnerTests: XCTestCase {
    var defaults: UserDefaults!
    var learner: WindowLengthLearner!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        learner = WindowLengthLearner(defaults: defaults)
    }

    func testFiveHourIsNeverLearnedOrProvisional() {
        learner.observe(WindowReading(kind: .fiveHour, utilization: 1, resetsAt: t0))
        learner.observe(WindowReading(kind: .fiveHour, utilization: 1, resetsAt: t0.addingTimeInterval(8 * 3600)))
        let (len, prov) = learner.length(for: .fiveHour)
        XCTAssertEqual(len, 5 * 3600)
        XCTAssertFalse(prov)
    }

    func testWeeklyIsProvisionalUntilAResetIsSeen() {
        XCTAssertEqual(learner.length(for: .sevenDay).isProvisional, true)
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t0))
        // Sub-second jitter within one window teaches nothing.
        learner.observe(WindowReading(kind: .sevenDay, utilization: 2, resetsAt: t0.addingTimeInterval(0.4)))
        XCTAssertEqual(learner.length(for: .sevenDay).isProvisional, true)
    }

    func testWeeklyLearnsShortestGapRoundedToHour() {
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t0))
        // A 96h gap (a window opened a day late) then a true 72h gap.
        let t1 = t0.addingTimeInterval(96 * 3600 + 0.7)
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t1))
        XCTAssertEqual(learner.length(for: .sevenDay).length, 96 * 3600)
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t1.addingTimeInterval(72 * 3600 - 0.3)))
        let (len, prov) = learner.length(for: .sevenDay)
        XCTAssertEqual(len, 72 * 3600)
        XCTAssertFalse(prov)
        // A later longer gap doesn't undo it.
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1,
                                      resetsAt: t1.addingTimeInterval(72 * 3600 + 100 * 3600)))
        XCTAssertEqual(learner.length(for: .sevenDay).length, 72 * 3600)
    }

    func testGapLongerThanNominalIsIgnored() {
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t0))
        learner.observe(WindowReading(kind: .sevenDay, utilization: 1, resetsAt: t0.addingTimeInterval(14 * 86_400)))
        XCTAssertTrue(learner.length(for: .sevenDay).isProvisional)
    }
}

final class DecodeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecodesResearchedShape() throws {
        let json = """
        {
          "five_hour": { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
          "seven_day": { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
          "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-04-16T03:00:00.951719+00:00" },
          "seven_day_opus": null,
          "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 0, "utilization": null },
          "some_future_field": [1, 2, 3]
        }
        """
        let s = try UsageAPI.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(s[.fiveHour]?.utilization, 33)
        XCTAssertEqual(s[.sevenDay]?.utilization, 13)
        XCTAssertEqual(s[.sevenDaySonnet]?.utilization, 1)
        let expected = ISO8601DateFormatter().date(from: "2026-04-11T07:00:00Z")!
        XCTAssertEqual(s[.fiveHour]!.resetsAt.timeIntervalSince(expected), 0.528, accuracy: 0.001)
    }

    func testWeeklyStartFromBreakdownMakesLengthExact() throws {
        let json = """
        {
          "five_hour": { "utilization": 14, "resets_at": "2026-09-22T23:39:59.880690+00:00" },
          "seven_day": { "utilization": 6, "resets_at": "2026-09-24T19:00:00.130548+00:00", "used_dollars": null },
          "seven_day_breakdown": { "as_of": "2026-09-22T22:53:48+00:00", "rows": [],
                                   "window_started_at": "2026-09-17T19:00:00.130548+00:00" },
          "limits": [{ "kind": "session", "percent": 14 }]
        }
        """
        let s = try UsageAPI.decode(Data(json.utf8), fetchedAt: now)
        let learner = WindowLengthLearner(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let (len, prov) = s[.sevenDay]!.length(using: learner)
        XCTAssertEqual(len, 7 * 86_400, accuracy: 0.001)
        XCTAssertFalse(prov)
        XCTAssertNil(s[.fiveHour]!.startsAt)
    }

    func testIntegerUtilisationAndZuluDates() throws {
        let json = #"{"five_hour":{"utilization":7,"resets_at":"2026-04-11T07:00:00Z"}}"#
        let s = try UsageAPI.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(s[.fiveHour]?.utilization, 7)
        XCTAssertNil(s[.sevenDay])
    }

    func testShapeChangeIsReportedNotCrashed() {
        let json = #"{"limits":[{"type":"five_hour","used":0.3}]}"#
        XCTAssertThrowsError(try UsageAPI.decode(Data(json.utf8), fetchedAt: now)) {
            XCTAssertEqual($0 as? UsageAPIError, .unrecognisedShape)
        }
        XCTAssertThrowsError(try UsageAPI.decode(Data("not json".utf8), fetchedAt: now))
    }

    func testRetryAfterForms() {
        func response(_ v: String) -> HTTPURLResponse {
            HTTPURLResponse(url: UsageAPI.endpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": v])!
        }
        XCTAssertEqual(UsageAPI.retryAfter(from: response("120"), now: now), 120)
        let httpDate = "Fri, 15 Jan 2027 08:00:00 GMT"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let target = f.date(from: httpDate)!
        XCTAssertEqual(UsageAPI.retryAfter(from: response(httpDate), now: target.addingTimeInterval(-300)), 300)
    }
}

final class FetchGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSpacingFloor() {
        var gate = FetchGate()
        XCTAssertEqual(gate.verdict(now: t0), .allowed)
        gate.recordRequest(at: t0)
        XCTAssertEqual(gate.verdict(now: t0.addingTimeInterval(30)),
                       .wait(until: t0.addingTimeInterval(60), reason: .spacing))
        XCTAssertEqual(gate.verdict(now: t0.addingTimeInterval(60)), .allowed)
    }

    func testHourlyCap() {
        var gate = FetchGate()
        for i in 0..<FetchGate.hourlyCap { gate.recordRequest(at: t0.addingTimeInterval(Double(i) * 61)) }
        let later = t0.addingTimeInterval(Double(FetchGate.hourlyCap) * 61)
        XCTAssertEqual(gate.verdict(now: later), .wait(until: t0.addingTimeInterval(3600), reason: .hourlyCap))
        XCTAssertEqual(gate.verdict(now: t0.addingTimeInterval(3601)), .allowed)
    }

    func testBackoffLadderWithoutRetryAfter() {
        var gate = FetchGate()
        var now = t0
        for expectedMinutes in [10.0, 20, 40, 60, 60] {
            let until = gate.recordRateLimit(retryAfter: nil, now: now)
            XCTAssertEqual(until.timeIntervalSince(now), expectedMinutes * 60)
            XCTAssertEqual(gate.verdict(now: now.addingTimeInterval(1)), .wait(until: until, reason: .rateLimited))
            now = until
        }
        gate.recordSuccess()
        XCTAssertEqual(gate.recordRateLimit(retryAfter: nil, now: now).timeIntervalSince(now), 600)
    }

    func testRetryAfterHonouredButFloored() {
        var gate = FetchGate()
        XCTAssertEqual(gate.recordRateLimit(retryAfter: 5, now: t0).timeIntervalSince(t0), 60,
                       "never sooner than the spacing floor")
        var fresh = FetchGate()
        XCTAssertEqual(fresh.recordRateLimit(retryAfter: 1800, now: t0).timeIntervalSince(t0), 1800)
        // Second consecutive hit: a short Retry-After can't undercut the ladder.
        XCTAssertEqual(fresh.recordRateLimit(retryAfter: 30, now: t0).timeIntervalSince(t0), 20 * 60)
    }
}

final class ColourAndMiscTests: XCTestCase {
    func testHeatAnchorsAndClamping() {
        XCTAssertEqual(PaceColor.heat(delta: -50), -1)
        XCTAssertEqual(PaceColor.heat(delta: -10), -1)
        XCTAssertEqual(PaceColor.heat(delta: 0), 0)
        XCTAssertEqual(PaceColor.heat(delta: 1.5), 0.175, accuracy: 1e-9)
        XCTAssertEqual(PaceColor.heat(delta: 12), 1)
        XCTAssertEqual(PaceColor.heat(delta: 99), 1)
    }

    func testVerdicts() {
        XCTAssertEqual(PaceColor.verdict(delta: -20), "Well behind: use more")
        XCTAssertEqual(PaceColor.verdict(delta: -5), "Behind: pick it up")
        XCTAssertEqual(PaceColor.verdict(delta: 2), "On pace")
        XCTAssertEqual(PaceColor.verdict(delta: 8), "Ahead: ease off a little")
        XCTAssertEqual(PaceColor.verdict(delta: 30), "Well ahead: ease off")
    }

    func testPlanLabel() {
        XCTAssertEqual(AccountInfo(rateLimitTier: "default_claude_max_5x").planLabel, "Max 5×")
        XCTAssertEqual(AccountInfo(rateLimitTier: "default_claude_max_20x").planLabel, "Max 20×")
        XCTAssertEqual(AccountInfo(organizationType: "claude_pro").planLabel, "Pro")
        XCTAssertNil(AccountInfo().planLabel)
    }

    func testPKCEChallengeIsURLSafeS256() {
        let pending = OAuthClient.beginAuthorization()
        let items = URLComponents(url: pending.url, resolvingAgainstBaseURL: false)!.queryItems!
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"]?.count, 43)
        XCTAssertNil(q["code_challenge"]?.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(q["state"], pending.verifier)
        XCTAssertEqual(q["client_id"], OAuthClient.clientID)
    }

    func testPastedCodeForms() throws {
        XCTAssertEqual(try OAuthClient.parsePasted("abc#xyz").code, "abc")
        XCTAssertEqual(try OAuthClient.parsePasted(" abc#xyz\n").state, "xyz")
        XCTAssertNil(try OAuthClient.parsePasted("abc").state)
        let url = "https://platform.claude.com/oauth/code/callback?code=C0DE&state=ST-ATE_1"
        XCTAssertEqual(try OAuthClient.parsePasted(url).code, "C0DE")
        XCTAssertEqual(try OAuthClient.parsePasted(url).state, "ST-ATE_1")
        XCTAssertThrowsError(try OAuthClient.parsePasted("https://example.com/cb?nope=1"))
        XCTAssertThrowsError(try OAuthClient.parsePasted(""))
    }

    func testDurationPhrases() {
        XCTAssertEqual(Duration.phrase(30), "<1m")
        XCTAssertEqual(Duration.phrase(47 * 60), "47m")
        XCTAssertEqual(Duration.phrase(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(Duration.phrase(3 * 86_400 + 4 * 3600), "3d 4h")
    }
}
