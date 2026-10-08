import CryptoKit
import Foundation

/// Claude's OAuth PKCE flow, using the same public client and manual-code
/// redirect that Claude Code uses when it can't open a local callback.
///
/// The user approves in their browser, is shown a `code#state` string, and
/// pastes it back into the app. No custom URL scheme is needed, which matters
/// because redirect URIs are registered against the client ID and we can't
/// add one.
struct OAuthClient {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    /// The token endpoint has moved between hosts and reports disagree on which
    /// currently answers, so try each in order and remember the one that works.
    static let defaultTokenEndpoints = [
        "https://platform.claude.com/v1/oauth/token",
        "https://console.anthropic.com/v1/oauth/token",
        "https://claude.ai/v1/oauth/token",
    ]

    var session: URLSession = .shared
    var defaults: UserDefaults = .standard

    /// One in-progress sign-in: the verifier must survive until the code is pasted.
    struct PendingAuthorization: Sendable {
        let verifier: String
        let url: URL
    }

    static func beginAuthorization() -> PendingAuthorization {
        let verifier = randomURLSafe(bytes: 32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]
        return PendingAuthorization(verifier: verifier, url: components.url!)
    }

    /// Exchange the pasted `code#state` for tokens.
    func exchange(pasted: String, pending: PendingAuthorization, now: Date = Date()) async throws -> OAuthCredential {
        let (code, pastedState) = try Self.parsePasted(pasted)
        let state = pastedState ?? pending.verifier
        guard state == pending.verifier else { throw OAuthError.stateMismatch }

        return try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": pending.verifier,
        ], previousRefreshToken: nil, now: now)
    }

    /// Accepts either the `code#state` string the callback page displays, or
    /// the whole callback URL from the address bar (the page sometimes renders
    /// blank, leaving the URL as the only place the code appears).
    static func parsePasted(_ pasted: String) throws -> (code: String, state: String?) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme != nil,
           let items = components.queryItems {
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw OAuthError.malformedCode
            }
            // The state may arrive as a query item or as a `#state` fragment.
            let state = items.first(where: { $0.name == "state" })?.value ?? components.fragment
            return (code, state)
        }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty, !code.contains(" ") else { throw OAuthError.malformedCode }
        return (code, parts.count > 1 ? parts[1] : nil)
    }

    func refresh(_ credential: OAuthCredential, now: Date = Date()) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken else { throw OAuthError.noRefreshToken }
        return try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ], previousRefreshToken: refreshToken, now: now)
    }

    // MARK: - Token endpoint

    private static let workingEndpointKey = "oauth.workingTokenEndpoint"
    static let overrideEndpointKey = "oauth.tokenEndpointOverride"

    /// Override first, then the last host that worked, then the defaults.
    var tokenEndpoints: [String] {
        var ordered: [String] = []
        for candidate in [defaults.string(forKey: Self.overrideEndpointKey),
                          defaults.string(forKey: Self.workingEndpointKey)]
        + Self.defaultTokenEndpoints.map(Optional.some) {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty, !ordered.contains(c) {
                ordered.append(c)
            }
        }
        return ordered
    }

    private func postToken(_ body: [String: String], previousRefreshToken: String?, now: Date) async throws -> OAuthCredential {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = OAuthError.noEndpointAnswered

        for endpoint in tokenEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("claude-budget-rings/1.0", forHTTPHeaderField: "User-Agent")

            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = OAuthError.transport(error.localizedDescription)
                continue
            }
            guard let http = response as? HTTPURLResponse else { continue }

            switch http.statusCode {
            case 200:
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                defaults.set(endpoint, forKey: Self.workingEndpointKey)
                return OAuthCredential(
                    accessToken: token.access_token,
                    // Some servers don't rotate refresh tokens; keep the old one.
                    refreshToken: token.refresh_token ?? previousRefreshToken,
                    expiresAt: now.addingTimeInterval(TimeInterval(token.expires_in ?? 8 * 3600))
                )
            case 404, 405, 421:
                // This host doesn't serve the token endpoint (any more). Try the next.
                lastError = OAuthError.http(status: http.statusCode, detail: Self.errorDetail(data))
                continue
            case 400, 401, 403:
                // The host answered and refused: the grant is bad. Another host
                // won't change that, and retrying a refresh token can burn it.
                throw OAuthError.rejected(detail: Self.errorDetail(data))
            case 429:
                throw OAuthError.rateLimited
            default:
                lastError = OAuthError.http(status: http.statusCode, detail: Self.errorDetail(data))
                continue
            }
        }
        throw lastError
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    /// Pull a human-readable reason from an error body, never echoing tokens.
    private static func errorDetail(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let desc = obj["error_description"] as? String { return desc }
        if let err = obj["error"] as? String { return err }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        return ""
    }

    // MARK: - PKCE helpers

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthError: Error, LocalizedError, Equatable {
    case malformedCode
    case stateMismatch
    case noRefreshToken
    case rejected(detail: String)
    case rateLimited
    case http(status: Int, detail: String)
    case transport(String)
    case noEndpointAnswered

    var errorDescription: String? {
        switch self {
        case .malformedCode: return "That doesn't look like an authorisation code."
        case .stateMismatch: return "That code belongs to a different sign-in attempt. Start again."
        case .noRefreshToken: return "Session expired. Sign in again."
        case .rejected(let d): return "Anthropic rejected the sign-in" + (d.isEmpty ? "." : ": \(d)")
        case .rateLimited: return "Anthropic is rate-limiting sign-in. Try again in a few minutes."
        case .http(let s, let d): return "Token endpoint returned HTTP \(s)" + (d.isEmpty ? "." : ": \(d)")
        case .transport(let m): return "Network error: \(m)"
        case .noEndpointAnswered: return "No token endpoint answered. Set an override in Settings."
        }
    }
}
