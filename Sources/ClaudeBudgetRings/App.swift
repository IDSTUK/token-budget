import AppKit
import Combine
import SwiftUI

/// Status item + panel. AppKit rather than `MenuBarExtra` so the icon can be
/// a drawing-handler image that resolves colours in the menu bar's own
/// appearance at draw time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = UsageController()
    private let credits = CreditsController()
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        panel = StatusPanel(statusItem: statusItem) { PanelView(controller: controller, credits: credits) }
        panel.onOpen = { [weak self] in
            self?.controller.popoverOpened()
            self?.credits.panelOpened()
        }
        LoginItem.shared.enableOnFirstRun()

        // Redraw the icon whenever anything it depends on changes. `now` ticks
        // every 15 s, which moves the pace tick and colour.
        Publishers.CombineLatest4(controller.$snapshot, controller.$now, controller.$status, controller.$auth)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        controller.start()
        credits.start()
        updateIcon()

        if controller.auth == .signedOut {
            // First run: show the sign-in panel rather than two empty rings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.panel.show() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let paces = WindowKind.displayed.map { controller.pace(for: $0) }
        let items = zip(WindowKind.displayed, paces).map { (label: $0.shortLabel.uppercased(), pace: $1) }
        button.image = RingRenderer.menuBarImage(items: items, stale: controller.isStale)
        button.toolTip = tooltip(paces)
        button.setAccessibilityLabel(tooltip(paces))
    }

    private func tooltip(_ paces: [Pace?]) -> String {
        guard controller.auth == .signedIn else { return "Token Budget: not signed in" }
        let parts = zip(WindowKind.displayed, paces).map { kind, pace -> String in
            guard let pace else { return "\(kind.shortLabel) –" }
            return "\(kind.shortLabel) \(Int(pace.utilization.rounded()))% (ideal \(Int(pace.ideal.rounded()))%, \(PaceColor.verdict(delta: pace.delta).lowercased()))"
        }
        return "Token Budget — " + parts.joined(separator: " · ")
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") {
            Probe.run(raw: args.contains("--raw"))
        } else if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            Preview.render(to: URL(fileURLWithPath: args[i + 1]))
        } else if args.contains("--login") {
            Probe.login()
        } else {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
