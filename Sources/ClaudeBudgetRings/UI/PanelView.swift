import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var controller: UsageController
    @ObservedObject var credits: CreditsController
    @State private var showingSettings = false

    var body: some View {
        PanelHeader(title: "Token Budget", status: headerStatus) {
            if controller.auth == .signedIn {
                Button { controller.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                    .disabled(controller.status == .fetching)
            }
        }

        Divider()

        switch controller.auth {
        case .signedOut, .awaitingCode:
            SignInView(controller: controller)
        case .signedIn:
            ForEach(WindowKind.displayed, id: \.self) { kind in
                WindowBar(kind: kind, pace: controller.pace(for: kind), stale: controller.isStale)
            }
        }

        if !credits.configured.isEmpty {
            Divider()
            SectionHeader("API credits")
            ForEach(credits.configured) { provider in
                CreditRow(provider: provider, state: credits.states[provider])
            }
        }

        Divider()
        DisclosureGroup("Settings", isExpanded: $showingSettings) {
            SettingsView(controller: controller, credits: credits).padding(.top, 8)
        }
        PanelFooter()
    }

    /// Plan and freshness, or what's wrong, in one line.
    private var headerStatus: String {
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        guard controller.auth == .signedIn else { return "Not signed in" }
        switch controller.status {
        case .fetching: return "Checking…"
        case .rateLimited(let until): return "Rate-limited · retrying at \(until.formatted(t))"
        case .failed(let message): return message
        case .idle: break
        }
        let updated = controller.snapshot.map { "Updated \($0.fetchedAt.formatted(t))" } ?? "No reading yet"
        let parts = [controller.account?.planLabel, controller.isStale ? "Out of date" : updated]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// One limit window: name and percentage, a bar, and one line of verdict.
/// Fill is how much is used, the tick is where an even burn would be now,
/// and the colour is pace.
private struct WindowBar: View {
    let kind: WindowKind
    let pace: Pace?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title)
                Spacer()
                Text(pace.map { "\(Int($0.utilization.rounded()))%" } ?? "–")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            BurnBar(pace: pace, stale: stale).frame(height: 6).padding(.vertical, 4)
            HStack(spacing: 5) {
                if let pace {
                    Circle()
                        .fill(stale ? Color.secondary : PaceColor.color(delta: pace.delta))
                        .frame(width: 6, height: 6)
                }
                Text(summary)
                    .foregroundStyle(pace?.timeToExhaustion != nil ? Color.orange : Color.secondary)
            }
            .font(Chrome.captionFont)
            .monospacedDigit()
        }
        .help("Colour shows pace, not fullness. The tick marks where an even burn would be now.")
    }

    private var summary: String {
        guard let pace else { return "No data" }
        if pace.utilization >= 100 { return "Limit reached · resets in \(Duration.phrase(pace.remaining))" }
        let verdict = PaceColor.verdict(delta: pace.delta)
        if let t = pace.timeToExhaustion { return "\(verdict) · hits the limit in \(Duration.phrase(t))" }
        return "\(verdict) · resets in \(Duration.phrase(pace.remaining))"
    }
}

private struct BurnBar: View {
    let pace: Pace?
    let stale: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1))
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(stale ? Color.secondary : PaceColor.color(delta: pace.delta))
                        .frame(width: max(2, width * min(pace.utilization, 100) / 100))
                        .opacity(pace.utilization > 0 ? 1 : 0)
                    // The even-burn tick, with a halo so it reads over the fill.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary)
                        .frame(width: 3, height: geo.size.height + 8)
                        .overlay(RoundedRectangle(cornerRadius: 1.5)
                            .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: min(max(width * min(pace.ideal, 100) / 100 - 1.5, 0), width - 3))
                }
            }
        }
    }
}

enum Duration {
    /// "2h 14m", "47m", "3d 4h", "<1m".
    static func phrase(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }
}

private struct SignInView: View {
    @ObservedObject var controller: UsageController
    @State private var code = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your Claude account")
                .font(.subheadline.weight(.semibold))
            Text("This reads your 5-hour and 7-day usage from Anthropic. Sign-in happens on claude.ai; this app only keeps the resulting token, in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.auth == .awaitingCode {
                Text("After approving, paste the code shown — or, if the page is blank, the whole URL from the address bar:")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Paste code or callback URL", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(connect)
                HStack {
                    Button("Cancel") { controller.cancelSignIn(); code = "" }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            } else {
                Button("Sign in with Claude…") {
                    NSWorkspace.shared.open(controller.beginSignIn())
                }
                .keyboardShortcut(.defaultAction)
            }

            if let error = controller.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        guard !working else { return }
        working = true
        Task {
            await controller.completeSignIn(pastedCode: code)
            working = false
            if controller.auth == .signedIn { code = "" }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: UsageController
    @ObservedObject var credits: CreditsController
    @AppStorage(OAuthClient.overrideEndpointKey) private var endpointOverride = ""
    @AppStorage(RingRenderer.MenuBarLayout.key) private var menuBarLayout = RingRenderer.MenuBarLayout.stacked.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.spacing) {
            PickerRow(title: "Check every", selection: $controller.pollInterval,
                      options: UsageController.intervalChoices.map { ("\(Int($0 / 60)) min", $0) })
            PickerRow(title: "Menu bar", selection: $menuBarLayout,
                      options: RingRenderer.MenuBarLayout.allCases.map { ($0.title, $0.rawValue) })

            SectionHeader("API keys")
            ForEach(CreditProvider.allCases) { provider in
                KeyRow(provider: provider, credits: credits)
            }

            SectionHeader("Token endpoint override")
            TextField("Automatic", text: $endpointOverride)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

            HStack {
                Button("Forget Window Lengths") { controller.learner.reset() }
                    .help("Re-learn the weekly window length from the next observed reset")
                Spacer()
                if controller.auth == .signedIn {
                    Button("Sign Out") { controller.signOut() }
                }
            }
            .controlSize(.small)
        }
    }
}

private struct CreditRow: View {
    let provider: CreditProvider
    let state: CreditsController.State?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.name)
                Spacer()
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(isWarning ? Color.orange : Color.primary)
            }
            // Only a failure earns a second line; details are in the tooltip.
            if case .failed(let message) = state {
                Text(message)
                    .font(Chrome.captionFont)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(detail)
    }

    private var value: String {
        switch state {
        case .loaded(let reading, _): return reading.headline
        case .failed: return "–"
        case .loading, nil: return "…"
        }
    }

    private var isWarning: Bool {
        switch state {
        case .loaded(let reading, _): return reading.isLow
        case .failed: return true
        default: return false
        }
    }

    private var detail: String {
        switch state {
        case .loaded(let reading, _): return reading.detail
        case .failed(let message): return message
        case .loading, nil: return "Checking…"
        }
    }
}

private struct KeyRow: View {
    let provider: CreditProvider
    @ObservedObject var credits: CreditsController
    @State private var key = ""

    var body: some View {
        HStack {
            Text(provider.name).frame(width: 110, alignment: .leading)
            if credits.configured.contains(provider) {
                Text("Saved").foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { credits.remove(provider) }.controlSize(.small)
            } else {
                SecureField(provider.keyPlaceholder, text: $key)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(save)
            }
        }
    }

    private func save() {
        credits.save(key: key, for: provider)
        key = ""
    }
}
