import Foundation

/// Plan metadata Claude Code caches in `~/.claude.json`. Read-only, and only
/// the `oauthAccount` object is touched; the file holds nothing secret there.
struct AccountInfo: Equatable {
    var email: String?
    var organizationType: String?
    var rateLimitTier: String?

    static func load() -> AccountInfo? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return AccountInfo(
            email: account["emailAddress"] as? String,
            organizationType: account["organizationType"] as? String,
            rateLimitTier: account["organizationRateLimitTier"] as? String
        )
    }

    /// "Max 5x", "Max 20x", "Pro", or nil when unknown.
    var planLabel: String? {
        if let tier = rateLimitTier?.lowercased() {
            if let range = tier.range(of: #"max_(\d+)x"#, options: .regularExpression) {
                let n = tier[range].dropFirst(4).dropLast()
                return "Max \(n)×"
            }
            if tier.contains("pro") { return "Pro" }
        }
        switch organizationType {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }
}
