import Foundation
import os

/// Prepaid API accounts whose balance (or spend) the panel can show. Each is
/// opt-in: it appears once you save a key for it.
enum CreditProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI, kimi, deepSeek

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: return "OpenAI (Codex)"
        case .kimi: return "Kimi"
        case .deepSeek: return "DeepSeek"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openAI: return "Admin key (sk-admin-…)"
        case .kimi: return "API key (platform.kimi.ai)"
        case .deepSeek: return "API key"
        }
    }

    var keychain: KeychainStore {
        KeychainStore(service: "com.domkits.claude-budget-rings", account: "api.\(rawValue)")
    }
}

/// One provider's latest numbers, already phrased for display.
struct CreditReading: Equatable, Sendable {
    /// The big number: a balance, or for OpenAI this month's spend.
    let headline: String
    let detail: String
    /// Balance gone (or nearly): shown in orange.
    let isLow: Bool
}

enum CreditFetchError: Error, CustomStringConvertible {
    case rejectedKey, needsAdminKey, http(Int), unexpectedFormat

    var description: String {
        switch self {
        case .rejectedKey: return "Key rejected. Check it's still valid."
        case .needsAdminKey: return "Needs an admin key (sk-admin-…) from platform.openai.com → Admin keys."
        case .http(let code): return "The service answered \(code). Try again later."
        case .unexpectedFormat: return "The service changed its response format."
        }
    }
}

enum CreditsAPI {
    static func fetch(_ provider: CreditProvider, key: String) async throws -> CreditReading {
        // The costs endpoint only accepts organisation admin keys.
        if provider == .openAI && !key.hasPrefix("sk-admin-") { throw CreditFetchError.needsAdminKey }
        switch provider {
        case .deepSeek: return try await deepSeek(key)
        case .kimi: return try await kimi(key)
        case .openAI: return try await openAI(key)
        }
    }

    // GET https://api.deepseek.com/user/balance
    // {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"110.00",
    //   "granted_balance":"10.00","topped_up_balance":"100.00"}]}
    private static func deepSeek(_ key: String) async throws -> CreditReading {
        struct Response: Decodable {
            struct Info: Decodable {
                let currency: String
                let total_balance: String
                let granted_balance: String
                let topped_up_balance: String
            }
            let is_available: Bool
            let balance_infos: [Info]
        }
        let r: Response = try await get("https://api.deepseek.com/user/balance", key: key)
        guard let info = r.balance_infos.first(where: { $0.currency == "USD" }) ?? r.balance_infos.first,
              let total = Double(info.total_balance)
        else { throw CreditFetchError.unexpectedFormat }
        let granted = Double(info.granted_balance) ?? 0
        let topped = Double(info.topped_up_balance) ?? 0
        return CreditReading(
            headline: money(total, info.currency),
            detail: "\(money(topped, info.currency)) topped up · \(money(granted, info.currency)) granted",
            isLow: !r.is_available || total < 1)
    }

    // GET https://api.moonshot.ai/v1/users/me/balance
    // {"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3.0},"status":true}
    private static func kimi(_ key: String) async throws -> CreditReading {
        struct Response: Decodable {
            struct Balance: Decodable {
                let available_balance: Double
                let voucher_balance: Double
                let cash_balance: Double
            }
            let code: Int
            let data: Balance?
        }
        let r: Response = try await get("https://api.moonshot.ai/v1/users/me/balance", key: key)
        guard r.code == 0, let b = r.data else { throw CreditFetchError.unexpectedFormat }
        return CreditReading(
            headline: money(b.available_balance, "USD"),
            detail: "\(money(b.cash_balance, "USD")) cash · \(money(b.voucher_balance, "USD")) voucher",
            isLow: b.available_balance < 1)
    }

    // OpenAI has no balance endpoint for API keys; the Costs API (admin keys
    // only) gives spend, so show this month's spend instead.
    // GET https://api.openai.com/v1/organization/costs?start_time=…&bucket_width=1d&limit=31
    private static func openAI(_ key: String) async throws -> CreditReading {
        struct Page: Decodable {
            struct Bucket: Decodable {
                struct Result: Decodable {
                    struct Amount: Decodable { let value: Double; let currency: String }
                    let amount: Amount?
                }
                let results: [Result]
            }
            let data: [Bucket]
            let has_more: Bool?
            let next_page: String?
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        var total = 0.0, currency = "usd"
        var page: String?
        for _ in 0..<5 {
            var url = "https://api.openai.com/v1/organization/costs?start_time=\(Int(monthStart.timeIntervalSince1970))&bucket_width=1d&limit=31"
            if let page { url += "&page=\(page)" }
            let p: Page = try await get(url, key: key)
            for result in p.data.flatMap(\.results) {
                if let amount = result.amount {
                    total += amount.value
                    currency = amount.currency
                }
            }
            guard p.has_more == true, let next = p.next_page else { break }
            page = next
        }
        let month = monthStart.formatted(.dateTime.month(.wide))
        return CreditReading(headline: money(total, currency),
                             detail: "Spent in \(month). OpenAI doesn't share the remaining balance.",
                             isLow: false)
    }

    private static func get<T: Decodable>(_ url: String, key: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CreditFetchError.rejectedKey }
        guard status == 200 else { throw CreditFetchError.http(status) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CreditFetchError.unexpectedFormat }
    }

    static func money(_ value: Double, _ currency: String) -> String {
        value.formatted(.currency(code: currency.uppercased()).precision(.fractionLength(2)))
    }
}

/// Keeps every configured provider's reading fresh: on launch, when the panel
/// opens (at most every 5 min), and every 30 min.
@MainActor
final class CreditsController: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(CreditReading, Date)
        case failed(String)
    }

    @Published private(set) var configured: [CreditProvider] = []
    @Published private(set) var states: [CreditProvider: State] = [:]

    private var lastRefresh = Date.distantPast
    private var timer: Timer?
    private let log = Logger(subsystem: "com.domkits.claude-budget-rings", category: "credits")

    init() {
        configured = CreditProvider.allCases.filter { $0.keychain.loadString() != nil }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func panelOpened() {
        if Date().timeIntervalSince(lastRefresh) > 5 * 60 { refresh() }
    }

    func save(key: String, for provider: CreditProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try provider.keychain.saveString(key)
            if !configured.contains(provider) {
                configured = CreditProvider.allCases.filter { $0 == provider || configured.contains($0) }
            }
            refresh(only: provider)
        } catch {
            states[provider] = .failed("Couldn't save the key: \(error)")
        }
    }

    func remove(_ provider: CreditProvider) {
        provider.keychain.delete()
        configured.removeAll { $0 == provider }
        states[provider] = nil
    }

    func refresh(only provider: CreditProvider? = nil) {
        if provider == nil { lastRefresh = Date() }
        for p in configured where provider == nil || p == provider {
            guard let key = p.keychain.loadString() else { continue }
            if case .loaded = states[p] {} else { states[p] = .loading }
            Task {
                do {
                    let reading = try await CreditsAPI.fetch(p, key: key)
                    states[p] = .loaded(reading, Date())
                } catch {
                    log.error("\(p.rawValue, privacy: .public) credits failed: \(String(describing: error), privacy: .public)")
                    states[p] = .failed((error as? CreditFetchError)?.description ?? "Couldn't reach \(p.name).")
                }
            }
        }
    }
}
