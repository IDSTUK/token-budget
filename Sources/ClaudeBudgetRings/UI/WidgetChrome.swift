// WidgetChrome — the shared look of every menu bar widget.
//
// Canonical copy: OmniWidget/Shared/WidgetChrome.swift. Each app keeps a
// vendored copy so it builds on its own; run OmniWidget/scripts/sync.sh after
// editing this file. See OmniWidget/DESIGN.md for the rules these views encode.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Metrics

enum Chrome {
    static let width: CGFloat = 320
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 12
    static let cornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 6

    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let sectionFont = Font.system(size: 11, weight: .semibold)
    static let captionFont = Font.system(size: 11)

    /// A template SF Symbol sized for the menu bar.
    static func menuBarSymbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}

// MARK: - Status panel

/// The dropdown every widget shows from its menu bar item: a borderless,
/// non-activating panel with rounded corners that hangs under the item, like
/// the system's own menu bar extras. Non-activating so opening it never takes
/// focus from the app you're working in.
@MainActor
final class StatusPanel: NSObject, NSWindowDelegate {
    let statusItem: NSStatusItem
    /// Called just before the panel appears, e.g. to refresh data.
    var onOpen: (() -> Void)?

    private let panel: KeyablePanel
    private var clickMonitor: Any?
    private var closedAt = Date.distantPast

    init<Content: View>(statusItem: NSStatusItem, @ViewBuilder content: () -> Content) {
        self.statusItem = statusItem
        let host = NSHostingController(rootView: PanelSurface(content: content()))
        host.sizingOptions = [.preferredContentSize]
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Chrome.width, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
    }

    var isShown: Bool { panel.isVisible }

    @objc func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            // The click that closed the panel (outside it) can also land on
            // the status item; don't reopen straight away.
            show()
        }
    }

    func show() {
        onOpen?()
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        reposition()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = Date()
        statusItem.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Hang the panel under the status item, kept on screen; the top edge
    /// stays put as the content grows or shrinks.
    private func reposition() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(anchor.minX, visible.minX + 6), visible.maxX - size.width - 6)
        let y = anchor.minY - size.height - 5
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResize(_ notification: Notification) {
        if panel.isVisible { reposition() }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Borderless panels can't become key by default, which text fields and
/// keyboard shortcuts need. Accessory apps also have no Edit menu, so the
/// standard editing shortcuts are routed by hand.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { orderOut(sender); resignKey() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            case "q": #selector(NSApplication.terminate(_:))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Width, padding, material and corner rounding shared by every panel.
private struct PanelSurface<Content: View>: View {
    let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Chrome.spacing) { content }
            .font(Chrome.bodyFont)
            .padding(Chrome.padding)
            .frame(width: Chrome.width, alignment: .leading)
            .background(MenuMaterial())
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Building blocks

/// App name in bold, an optional one-line status under it, and an optional
/// control (usually the master switch) on the right.
struct PanelHeader<Accessory: View>: View {
    let title: String
    var status: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Chrome.titleFont)
                if let status {
                    Text(status).font(Chrome.captionFont).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String, status: String? = nil) {
        self.init(title: title, status: status) { EmptyView() }
    }
}

/// The master on/off switch for a header.
struct MasterSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(Chrome.sectionFont).foregroundStyle(.secondary)
    }
}

/// An option with a switch on the right.
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

/// A labelled slider with its current value on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// An option chosen from a short list, shown as a pop-up on the right.
struct PickerRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// A full-width, menu-item-like action with a hover highlight.
struct ActionRow: View {
    let title: String
    var shortcut: String?
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
    }
}

/// Something the user must do before the app can work, e.g. grant a permission.
struct Notice: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button(actionTitle, action: action).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// "Launch at login" and "Quit <App>": the last two rows of every panel.
struct PanelFooter: View {
    @ObservedObject private var loginItem = LoginItem.shared

    var body: some View {
        Divider()
        ToggleRow("Launch at login", isOn: $loginItem.isEnabled)
        if let error = loginItem.error {
            Text(error).font(Chrome.captionFont).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        ActionRow(title: "Quit \(Chrome.appName)", shortcut: "⌘Q") { NSApp.terminate(nil) }
    }
}

// MARK: - Launch at login

@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !syncing else { return }
            apply(isEnabled)
        }
    }
    @Published private(set) var error: String?
    private var syncing = false

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Every widget launches at login unless the user turns it off. Register
    /// once, on the first run, so turning it off sticks.
    func enableOnFirstRun() {
        let key = "chrome.loginItemInitialised"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        apply(true)
    }

    private func apply(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change the login item: \(error.localizedDescription)"
        }
        // Reflect what macOS actually did without re-triggering didSet.
        syncing = true
        isEnabled = SMAppService.mainApp.status == .enabled
        syncing = false
    }
}
