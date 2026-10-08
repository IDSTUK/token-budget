import AppKit
import Combine
import Foundation
import os

let log = Logger(subsystem: "com.domkits.claude-budget-rings", category: "usage")

/// Owns sign-in, polling, and the latest reading. Everything the UI shows comes
/// from here.
@MainActor
final class UsageController: ObservableObject {
    enum AuthState: Equatable {
        case signedOut
        case awaitingCode
        case signedIn
    }

    enum Status: Equatable {
        case idle
        case fetching
        case rateLimited(until: Date)
        case failed(String)
    }

    @Published private(set) var auth: AuthState = .signedOut
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var nextPoll: Date?
    @Published private(set) var authError: String?
    /// Ticks every few seconds so pace (which moves with the clock) redraws.
    @Published private(set) var now = Date()
    @Published private(set) var account = AccountInfo.load()

    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: Self.intervalKey); scheduleJitter() }
    }

    static let intervalChoices: [TimeInterval] = [3, 5, 10, 15].map { $0 * 60 }
    /// Poll this often even with no Claude Code activity, because claude.ai in
    /// a browser and desktop chat draw on the same windows invisibly to us.
    static let idleHeartbeat: TimeInterval = 30 * 60
    /// On popover open, refetch if the reading is older than this.
    static let freshOnOpen: TimeInterval = 90
    private static let intervalKey = "pollInterval"

    let learner = WindowLengthLearner()
    private let keychain = KeychainStore.standard
    private let oauth = OAuthClient()
    private let api = UsageAPI()

    private var credential: OAuthCredential?
    private var pending: OAuthClient.PendingAuthorization?
    private var gate = FetchGate()
    private var jitter: TimeInterval = 0
    private var forceNext = false
    private var paused = false
    private var consecutiveUnauthorized = 0
    private var timer: Timer?
    private var watcher: ActivityWatcher?
    private var lastFetchStartedActivityMark: Date?

    /// Debug: answer every fetch with a synthetic 429, no network.
    private let simulate429 = CommandLine.arguments.contains("--simulate-429")
        || UserDefaults.standard.bool(forKey: "debugSimulate429")

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        pollInterval = Self.intervalChoices.contains(stored) ? stored : 5 * 60
        credential = keychain.load()
        auth = credential == nil ? .signedOut : .signedIn
        scheduleJitter()
    }

    func start() {
        watcher = ActivityWatcher { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        watcher?.start()

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 5

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.paused = true }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.paused = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }

        forceNext = true
        tick()
    }

    private func resume() {
        paused = false
        forceNext = true
        tick()
    }

    /// The popover opened: make sure what it shows is recent.
    func popoverOpened() {
        now = Date()
        account = AccountInfo.load()
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Self.freshOnOpen { return }
        forceNext = true
        tick()
    }

    /// Manual refresh from the popover. Still goes through the gate.
    func refreshNow() {
        forceNext = true
        tick()
    }

    // MARK: - Scheduling

    private func scheduleJitter() {
        jitter = Double.random(in: -20...20)
    }

    private func tick() {
        now = Date()
        guard !paused, auth == .signedIn, status != .fetching else {
            nextPoll = nil
            return
        }
        let due = dueDate()
        switch gate.verdict(now: now) {
        case .wait(let until, _):
            nextPoll = max(until, due ?? until)
            return
        case .allowed:
            break
        }
        guard let due else { nextPoll = nil; return }
        nextPoll = due
        if now >= due { Task { await fetch() } }
    }

    /// When the next poll is due, ignoring the gate. Nil means "not until
    /// something happens" — which only applies while idle with a heartbeat
    /// that hasn't come round yet, so in practice it's always a date.
    private func dueDate() -> Date? {
        guard let snapshot, !forceNext else { return now }
        let last = lastAttempt ?? snapshot.fetchedAt

        // A window rolled over: its utilisation is now stale in a known way.
        for kind in WindowKind.displayed {
            if let r = snapshot[kind]?.resetsAt, r <= now, r > last { return max(r.addingTimeInterval(30), last) }
        }

        let active: Bool = {
            guard let activity = watcher?.lastActivityDate else { return false }
            return activity > (lastFetchStartedActivityMark ?? .distantPast)
        }()
        let failed: Bool = { if case .failed = status { return true } else { return false } }()
        let interval = (active || failed) ? pollInterval + jitter : Self.idleHeartbeat + jitter * 3
        return last.addingTimeInterval(interval)
    }

    // MARK: - Fetching

    private func fetch() async {
        guard var credential, status != .fetching else { return }
        forceNext = false
        status = .fetching
        let started = Date()
        lastAttempt = started
        lastFetchStartedActivityMark = started

        // Refresh first, never after: a call with an expired token is what
        // earns the long 429s.
        if credential.needsRefresh(now: started) {
            do {
                log.info("Refreshing access token")
                credential = try await oauth.refresh(credential, now: started)
                try keychain.save(credential)
                self.credential = credential
            } catch OAuthError.rejected(let detail) {
                log.error("Refresh rejected: \(detail, privacy: .public)")
                signOut(reason: "Your session expired. Sign in again.")
                return
            } catch {
                log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                status = .failed((error as? LocalizedError)?.errorDescription ?? "Token refresh failed.")
                return
            }
        }

        gate.recordRequest(at: started)
        log.info("Polling usage endpoint")
        do {
            let result: UsageSnapshot
            if simulate429 {
                throw UsageAPIError.rateLimited(retryAfter: nil)
            } else {
                result = try await api.fetch(accessToken: credential.accessToken, now: started).0
            }
            gate.recordSuccess()
            consecutiveUnauthorized = 0
            for reading in result.windows.values { learner.observe(reading) }
            snapshot = result
            status = .idle
        } catch UsageAPIError.rateLimited(let retryAfter) {
            let until = gate.recordRateLimit(retryAfter: retryAfter, now: Date())
            log.notice("Rate limited; backing off until \(until, privacy: .public)")
            status = .rateLimited(until: until)
        } catch UsageAPIError.unauthorized {
            consecutiveUnauthorized += 1
            if consecutiveUnauthorized >= 2 {
                signOut(reason: "Anthropic no longer accepts this sign-in. Sign in again.")
                return
            }
            // Force a refresh before the next attempt; the gate spaces it out.
            credential.expiresAt = .distantPast
            self.credential = credential
            status = .failed("Session needs renewing…")
        } catch UsageAPIError.unrecognisedShape {
            status = .failed("Anthropic changed the usage format. Update the app.")
        } catch UsageAPIError.http(let code) {
            status = .failed("Usage endpoint returned HTTP \(code).")
        } catch UsageAPIError.transport(let message) {
            status = .failed("Offline: \(message)")
        } catch {
            status = .failed(error.localizedDescription)
        }
        scheduleJitter()
        tick()
    }

    // MARK: - Sign-in

    func beginSignIn() -> URL {
        let p = OAuthClient.beginAuthorization()
        pending = p
        authError = nil
        auth = .awaitingCode
        return p.url
    }

    func completeSignIn(pastedCode: String) async {
        guard let pending else { return }
        authError = nil
        do {
            let cred = try await oauth.exchange(pasted: pastedCode, pending: pending)
            try keychain.save(cred)
            credential = cred
            self.pending = nil
            auth = .signedIn
            consecutiveUnauthorized = 0
            forceNext = true
            tick()
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelSignIn() {
        pending = nil
        authError = nil
        auth = credential == nil ? .signedOut : .signedIn
    }

    func signOut(reason: String? = nil) {
        keychain.delete()
        credential = nil
        pending = nil
        snapshot = nil
        auth = .signedOut
        status = .idle
        authError = reason
        nextPoll = nil
    }

    // MARK: - Derived

    func pace(for kind: WindowKind) -> Pace? {
        guard let reading = snapshot?[kind] else { return nil }
        // Past the reset, the reading describes a closed window. Show an empty
        // fresh one until the next poll confirms the new window's numbers.
        if reading.resetsAt <= now {
            let (length, provisional) = reading.length(using: learner)
            return Pace(utilization: 0, ideal: 0, elapsed: 0, length: length, remaining: length, isProvisional: provisional)
        }
        let (length, provisional) = reading.length(using: learner)
        return Pace.compute(reading, length: length, isProvisional: provisional, now: now)
    }

    /// Reading is old enough that the rings shouldn't pretend to be live.
    var isStale: Bool {
        guard let snapshot else { return true }
        if case .rateLimited = status { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) > max(pollInterval * 3, Self.idleHeartbeat + 300)
    }
}
