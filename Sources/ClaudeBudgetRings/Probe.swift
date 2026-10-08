import Foundation

/// Headless modes for verifying the live endpoint without the GUI.
///
///   --login         sign in from the terminal (prints URL, reads the code)
///   --probe         one authenticated fetch, prints parsed windows and pace
///   --probe --raw   also prints the raw JSON body
///
/// Tokens are never printed. The probe makes exactly one usage request and
/// refuses to make one with an expired token.
enum Probe {
    static func run(raw: Bool) {
        blocking {
            let keychain = KeychainStore.standard
            guard var cred = keychain.load() else {
                print("Not signed in. Run with --login first, or sign in from the menu bar.")
                exit(1)
            }
            if cred.needsRefresh() {
                print("Access token near expiry; refreshing first…")
                do {
                    cred = try await OAuthClient().refresh(cred)
                    try keychain.save(cred)
                } catch {
                    print("Refresh failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                    exit(1)
                }
            }
            print("Token: <redacted>, expires \(cred.expiresAt.formatted(date: .abbreviated, time: .shortened))")
            do {
                let now = Date()
                let (snapshot, body) = try await UsageAPI().fetch(accessToken: cred.accessToken, now: now)
                if raw {
                    print("\n--- raw body ---")
                    if let obj = try? JSONSerialization.jsonObject(with: body),
                       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                        print(String(decoding: pretty, as: UTF8.self))
                    } else {
                        print(String(decoding: body, as: UTF8.self))
                    }
                    print("--- end ---\n")
                }
                let learner = WindowLengthLearner()
                for kind in WindowKind.allCases {
                    guard let r = snapshot[kind] else { print("\(kind.rawValue): absent"); continue }
                    learner.observe(r)
                    let (len, prov) = r.length(using: learner)
                    let p = Pace.compute(r, length: len, isProvisional: prov, now: now)
                    print(String(format: "%-17@ used %5.1f%%  ideal %5.1f%%  delta %+6.1f%%  %@  resets in %@%@",
                                 kind.rawValue as NSString, p.utilization, p.ideal, p.delta,
                                 PaceColor.verdict(delta: p.delta) as NSString,
                                 Duration.phrase(p.remaining) as NSString,
                                 (prov ? "  (length provisional)" : "") as NSString))
                }
            } catch UsageAPIError.rateLimited(let retryAfter) {
                print("429 rate limited. Retry-After: \(retryAfter.map { "\(Int($0))s" } ?? "none"). Wait before probing again.")
                exit(2)
            } catch {
                print("Fetch failed: \(error)")
                exit(1)
            }
        }
    }

    static func login() {
        blocking {
            let pending = OAuthClient.beginAuthorization()
            print("Open this URL, approve, then paste the code shown:\n\n\(pending.url.absoluteString)\n")
            print("Code: ", terminator: "")
            guard let line = readLine(), !line.isEmpty else { print("No code entered."); exit(1) }
            do {
                let cred = try await OAuthClient().exchange(pasted: line, pending: pending)
                try KeychainStore.standard.save(cred)
                print("Signed in. Token stored in Keychain, expires \(cred.expiresAt.formatted()).")
            } catch {
                print("Sign-in failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                exit(1)
            }
        }
    }

    private static func blocking(_ work: @escaping () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task { await work(); done.signal() }
        done.wait()
    }
}
