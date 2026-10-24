import AppKit
import CoreGraphics
import EdgeMarkets
import ServiceManagement
import SwiftUI

/// What the Settings window needs from the app delegate, which owns the pieces that aren't Observable.
final class SettingsContext: ObservableObject {
    /// EdgeDeck gave up putting the Edge in its Native mode.
    @Published var resolutionStuck = false
    @Published private(set) var loginStatus = SMAppService.Status.notRegistered
    /// Bumped when the Edge's display mode may have changed.
    @Published private(set) var modeRevision = 0

    var tryResolutionAgain: () -> Void = {}
    var keepResolutionChanged: () -> Void = {}

    /// Open at Login must point at one stable copy, which scripts/build.sh installs.
    var installed: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    func modeChanged() { modeRevision += 1 }

    /// SMAppService.status is a synchronous round trip to another process (~13 ms), so it's
    /// never asked on the main thread.
    func refreshLogin() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async { self?.loginStatus = status }
        }
    }

    func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("EdgeDeck: Open at Login failed: \(error)")
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        refreshLogin()
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", display = "Display", touch = "Touch", keyboard = "Keyboard"
    case notifications = "Notifications", markets = "Markets"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "display"
        case .touch: "hand.tap"
        case .keyboard: "keyboard"
        case .notifications: "bell"
        case .markets: "chart.line.uptrend.xyaxis"
        }
    }
}

/// Every app-level setting in one place; changes apply at once. Widgets are still configured
/// in their Editors on the Edge.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: SettingsContext
    @State private var section = SettingsSection.general

    var body: some View {
        // A fixed sidebar rather than NavigationSplitView, whose divider shifted while the panes laid out.
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            Group {
                switch section {
                case .general: GeneralPane(model: model, context: context)
                case .display: DisplayPane(model: model, context: context)
                case .touch: TouchPane(touch: model.touch)
                case .keyboard: KeyboardPane(lender: model.keyboardLender)
                case .notifications: NotificationsPane(configStore: model.configStore)
                case .markets: MarketsPane(configStore: model.configStore)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: SettingsContext

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { context.loginStatus == .enabled }, set: { _ in context.toggleLogin() }))
                    .disabled(!context.installed)
                if !context.installed {
                    Text("Run EdgeDeck from /Applications to use this.").foregroundStyle(.secondary)
                } else if context.loginStatus == .requiresApproval {
                    Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("Advanced") {
                HStack {
                    Button("Open config.json") { model.openConfigFile() }
                    Button("Reload Config") { model.configStore.reload() }
                }
                if let error = model.configStore.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .onAppear { context.refreshLogin() }
    }
}

private struct DisplayPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: SettingsContext
    @ObservedObject var configStore: ConfigStore

    init(model: AppModel, context: SettingsContext) {
        self.model = model
        self.context = context
        configStore = model.configStore
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Edge", value: edgeDescription)
                Toggle("Keep Edge at 2560×720", isOn: Binding(
                    get: { configStore.config.display.fixResolution },
                    set: { value in
                        configStore.update { $0.display.fixResolution = value }
                        context.keepResolutionChanged()
                    }))
                Text("macOS sometimes drops the Edge to 1080p after a replug, wake or KVM switch. EdgeDeck puts it back.")
                    .foregroundStyle(.secondary)
            }
            Section {
                CommittedTextField("Display name contains", value: configStore.config.display.match, prompt: "XENEON") { text in
                    configStore.update { $0.display.match = text.isEmpty ? DisplaySettings().match : text }
                }
                Stepper("Rail width: \(Int(configStore.config.display.railWidth)) pt",
                        value: Binding(get: { configStore.config.display.railWidth },
                                       set: { value in configStore.update { $0.display.railWidth = value } }),
                        in: 100...300, step: 10)
                Text("EdgeDeck puts the Dashboard on the display whose name contains this text. The Rail is the strip of controls beside a Guest app or Edge player.")
                    .foregroundStyle(.secondary)
            }
            if context.resolutionStuck {
                Section {
                    Text("Couldn't set the Edge to 2560×720.").foregroundStyle(.red)
                    Button("Try Again") { context.tryResolutionAgain() }
                }
            }
        }
    }

    private var edgeDescription: String {
        _ = context.modeRevision
        guard model.edgeConnected, let display = model.touch.display, let mode = CGDisplayCopyDisplayMode(display) else {
            return "Not connected"
        }
        let rate = mode.refreshRate > 0 ? String(format: " @ %.0f Hz", mode.refreshRate) : ""
        return "\(mode.width)×\(mode.height)\(rate)"
    }
}

private struct TouchPane: View {
    @ObservedObject var touch: TouchController
    /// TouchSettings isn't observable, so each change bumps this to redraw.
    @State private var revision = 0

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<TouchSettings, T>) -> Binding<T> {
        Binding(get: { _ = revision; return touch.settings[keyPath: keyPath] },
                set: { touch.settings[keyPath: keyPath] = $0; revision += 1 })
    }

    var body: some View {
        let settings = touch.settings
        Form {
            Section {
                Toggle("Touch Support", isOn: binding(\.enabled))
                LabeledContent("Status", value: touch.status.description)
                switch touch.status {
                case .needsInputMonitoring:
                    Button("Open Input Monitoring Settings…") { AppDelegate.openPrivacy("Privacy_ListenEvent") }
                case .needsAccessibility:
                    Button("Open \(AppModel.accessibilityName) Settings…") { AppDelegate.openPrivacy("Privacy_Accessibility") }
                case .edgetapRunning:
                    Button("Quit Edgetap") { AppDelegate.quitEdgetap() }
                default: EmptyView()
                }
            }
            Section("Scrolling") {
                Picker("Scroll Speed", selection: binding(\.scrollSpeed)) {
                    ForEach([(0.5, "0.5×"), (0.75, "0.75×"), (1, "1×"), (1.5, "1.5×"), (2, "2×"), (3, "3×")], id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Reverse Scroll Direction", isOn: binding(\.reverseScroll))
                Toggle("Momentum Scrolling", isOn: binding(\.momentum))
                Picker("Flick Acceleration", selection: binding(\.flickBoost)) {
                    ForEach([(0, "Off"), (4000, "Low"), (2000, "Normal"), (1000, "High")], id: \.0) { Text($0.1).tag(Double($0.0)) }
                }
                .disabled(!settings.momentum)
            }
            Section("Other apps' windows") {
                Picker("Hold Time for Right-Click", selection: binding(\.holdDuration)) {
                    ForEach([(0.3, "0.3 s"), (0.5, "0.5 s"), (0.8, "0.8 s"), (1.2, "1.2 s")], id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Hide Cursor While Touching", isOn: binding(\.hidesCursor))
            }
        }
    }
}

private struct KeyboardPane: View {
    @ObservedObject var lender: KeyboardLender
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: lender.lentTo.map { "Typing on \($0)" } ?? "This keyboard types here")
                Button("Take Back Keyboard") { lender.takeBack() }.disabled(lender.lentTo == nil)
            }
            Section {
                Toggle("Allow Paired Macs to Grab the Keyboard", isOn: $lender.allowed)
                LabeledContent("Take Back Keyboard Shortcut") {
                    HStack {
                        Text(recording ? "Press a shortcut with ⌘, ⌥ or ⌃…" : lender.shortcut.description)
                            .foregroundStyle(recording ? .secondary : .primary)
                        Button(recording ? "Cancel" : "Record Shortcut") { recording ? stopRecording() : startRecording() }
                        Button("Reset") { lender.shortcut = .standard }
                            .disabled(recording || lender.shortcut == .standard)
                    }
                }
                Text("It always gives this Mac its keyboard back while another Mac has grabbed it.").foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }  // Escape
            guard let shortcut = KeyShortcut(event: event) else { return event }
            lender.shortcut = shortcut
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct MarketsPane: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section("Quotes") {
                Picker("Update prices every", selection: Binding(
                    get: { configStore.config.markets.refreshSeconds },
                    set: { value in configStore.update { $0.markets.refreshSeconds = value } })) {
                    ForEach(Cadence.choices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min").tag(seconds)
                    }
                }
                Text("Prices come from Yahoo Finance, so updating more often than needed can get EdgeDeck rate-limited. While every market followed is closed, updates slow to every 15 minutes. Tap a Widget's header to update it right now.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NotificationsPane: View {
    @ObservedObject var configStore: ConfigStore

    private func binding<T>(_ keyPath: WritableKeyPath<NotificationSettings, T>) -> Binding<T> {
        Binding(get: { configStore.config.notifications[keyPath: keyPath] },
                set: { value in configStore.update { $0.notifications[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("Apps") {
                AppList("Bring to the Edge when tapped", items: binding(\.bringToEdgeOnTap), prompt: "App name, e.g. Slack")
                AppList("Never show", items: binding(\.ignoreApps), prompt: "App name, e.g. Mail")
            }
            Section("Showing") {
                Stepper("Keep the last \(configStore.config.notifications.maxItems) notifications",
                        value: binding(\.maxItems), in: 5...100, step: 5)
                Picker("Toast stays for", selection: binding(\.toastSeconds)) {
                    ForEach([3.0, 5, 8, 12, 20, 30], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Picker("Look for new notifications every", selection: binding(\.pollSeconds)) {
                    ForEach([0.5, 1, 1.5, 3, 5], id: \.self) { Text("\($0.formatted()) s").tag($0) }
                }
                Text("Looking more often shows new notifications sooner but uses more CPU.").foregroundStyle(.secondary)
            }
        }
    }
}

/// A text field that applies its text on Return or when it loses focus, not on every keystroke
/// (a half-typed display name could match the wrong display).
private struct CommittedTextField: View {
    let title: String
    let value: String
    let prompt: String
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(_ title: String, value: String, prompt: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.prompt = prompt
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
    }

    private func apply() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        draft = text
        if text != value { commit(text) }
    }
}

/// A list of app names, added with Return and removed with the minus button.
private struct AppList: View {
    let title: String
    @Binding var items: [String]
    let prompt: String
    @State private var new = ""

    init(_ title: String, items: Binding<[String]>, prompt: String) {
        self.title = title
        _items = items
        self.prompt = prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item)
                    Spacer()
                    Button { items.removeAll { $0 == item } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(item)")
                }
            }
            TextField("", text: $new, prompt: Text(prompt))
                .labelsHidden()
                .onSubmit {
                    let name = new.trimmingCharacters(in: .whitespaces)
                    new = ""
                    if !name.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { items.append(name) }
                }
        }
    }
}
