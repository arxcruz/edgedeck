import AppKit
import ApplicationServices

struct RunningApp: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleURL: URL?
    let isActive: Bool
    let isHidden: Bool
    var badge: String?

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: id) }

    /// The bundle's icon; NSRunningApplication.icon comes back blank for some apps (e.g. Safari).
    var icon: NSImage? { bundleURL.flatMap { AppLocator.icon(for: $0.path) } ?? app?.icon }
}

/// Tracks the regular (Dock-visible) apps that are running, plus their Dock
/// badges (unread counts), which the Dock exposes as AXStatusLabel.
final class RunningAppsModel: ObservableObject {
    @Published private(set) var apps: [RunningApp] = []

    private var badges: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var badgeTimer: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ]
        observers = names.map { center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.refresh() } }
        refreshBadges()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshBadges() }
    }

    private func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let next = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { app in
                RunningApp(id: app.processIdentifier, name: app.localizedName ?? "App", bundleURL: app.bundleURL,
                           isActive: app.isActive, isHidden: app.isHidden,
                           badge: app.bundleURL.flatMap { badges[$0.standardizedFileURL.path] })
            }
        if next != apps { apps = next }
    }

    /// Asked before each Dock scan: badges only show in the Running Apps widget.
    var isNeeded: () -> Bool = { true }

    private func refreshBadges() {
        defer { refresh() }
        guard isNeeded(), AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        var next: [String: String] = [:]
        for list in AX.children(AXUIElementCreateApplication(dock.processIdentifier)) {
            for item in AX.children(list) {
                guard let label: String = AX.value(item, "AXStatusLabel"), !label.isEmpty,
                      let url: URL = AX.value(item, kAXURLAttribute) else { continue }
                next[url.standardizedFileURL.path] = label
            }
        }
        badges = next
    }

    // MARK: Actions

    /// Brings the app forward. Opening it through Launch Services (rather than
    /// just activating) also unhides it and reopens a window if it has none.
    func bringToFront(_ item: RunningApp) {
        guard let app = item.app else { return }
        if let url = item.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.unhide()
            app.activate()
        }
    }

    func hide(_ item: RunningApp) { item.app?.hide() }

    func quit(_ item: RunningApp) { item.app?.terminate() }
}
