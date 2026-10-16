import AppKit
import ApplicationServices

struct EdgeNotification: Identifiable, Equatable {
    let id: String
    let app: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date

    var contentKey: String { [app, title, subtitle, body].joined(separator: "\u{1F}") }
}

/// Mirrors the banners macOS shows by reading Notification Center through the
/// Accessibility API. Each banner is an AXGroup with subrole
/// AXNotificationCenterBanner whose description is "App, title, subtitle, body"
/// and whose children are static texts identified as title/subtitle/body.
final class NotificationWatcher: ObservableObject {
    @Published private(set) var items: [EdgeNotification] = []
    @Published private(set) var toast: EdgeNotification?

    var settings = NotificationSettings()
    /// Notifications that get no Toast of their own (still listed), e.g. a terminal's
    /// "Claude needs your permission" while that Session's Needs-you Toast is up.
    var suppressesToast: (EdgeNotification) -> Bool = { _ in false }

    /// Banners currently on screen, keyed by notification id, so a tap can press the real one.
    private var liveBanners: [String: AXUIElement] = [:]
    private var seenIDs = Set<String>()
    private var recentContent: [String: Date] = [:]
    private var timer: Timer?
    private var toastTimer: Timer?
    private var primed = false

    private var lastBanner = Date.distantPast
    /// How long after a banner the poll stays quick, for a follow-up banner or a tap.
    private static let burst: TimeInterval = 5

    func start() {
        poll()
    }

    /// Every poll is a round of Accessibility calls into Notification Center, so idle polls
    /// are slow (`pollSeconds`) and only speed up while banners are around.
    private func schedule() {
        let quick = !liveBanners.isEmpty || Date().timeIntervalSince(lastBanner) < Self.burst
        let interval = quick ? min(0.5, settings.pollSeconds) : settings.pollSeconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.poll() }
    }

    func liveBanner(for notification: EdgeNotification) -> AXUIElement? {
        liveBanners[notification.id]
    }

    func remove(_ notification: EdgeNotification) {
        items.removeAll { $0.id == notification.id }
        if toast?.id == notification.id { toast = nil }
    }

    func clearAll() {
        items.removeAll()
        toast = nil
    }

    func dismissToast() { toast = nil }

    /// Closes the macOS banner too, if it's still on screen.
    func close(_ notification: EdgeNotification) {
        if let banner = liveBanners[notification.id] {
            if let close = AX.actions(banner).first(where: { $0.contains("Name:Close") }) {
                AX.perform(banner, close)
            } else if let button = AX.children(banner).first(where: { (AX.value($0, kAXIdentifierAttribute) as String?) == "xmark" }) {
                AX.perform(button, kAXPressAction)
            }
        }
        remove(notification)
    }

    private func poll() {
        defer { schedule() }
        guard AXIsProcessTrusted(),
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }

        let app = AXUIElementCreateApplication(center.processIdentifier)
        var banners: [(String, AXUIElement)] = []
        for window in AX.children(app) where (AX.value(window, kAXRoleAttribute) as String?) == kAXWindowRole {
            collectBanners(in: window, depth: 0, into: &banners)
        }

        var live: [String: AXUIElement] = [:]
        var fresh: [EdgeNotification] = []
        for (id, element) in banners {
            live[id] = element
            guard !seenIDs.contains(id), let notification = parse(element, id: id) else { continue }
            seenIDs.insert(id)
            // Re-delivered or re-rendered banners (e.g. when Notification Center is opened)
            // get new ids; suppress identical content seen in the last 10 minutes.
            if let seen = recentContent[notification.contentKey], Date().timeIntervalSince(seen) < 600 { continue }
            recentContent[notification.contentKey] = notification.date
            if settings.ignoreApps.contains(where: { $0.caseInsensitiveCompare(notification.app) == .orderedSame }) { continue }
            fresh.append(notification)
        }
        liveBanners = live
        if !live.isEmpty { lastBanner = Date() }

        // Whatever is already on screen at launch goes into the list without a toast.
        defer { primed = true }
        guard !fresh.isEmpty else { return }
        items.insert(contentsOf: fresh.reversed(), at: 0)
        if items.count > settings.maxItems { items.removeLast(items.count - settings.maxItems) }
        if primed, let newest = fresh.last, !suppressesToast(newest) { showToast(newest) }
        pruneMemory()
    }

    private func collectBanners(in element: AXUIElement, depth: Int, into result: inout [(String, AXUIElement)]) {
        guard depth < 10 else { return }
        for child in AX.children(element) {
            let role: String? = AX.value(child, kAXRoleAttribute)
            let identifier: String? = AX.value(child, kAXIdentifierAttribute)
            if role == kAXMenuBarRole || identifier?.hasPrefix("widget") == true { continue }
            let subrole: String? = AX.value(child, kAXSubroleAttribute)
            let isBanner = subrole?.hasPrefix("AXNotificationCenter") == true
                && AX.children(child).contains { (AX.value($0, kAXIdentifierAttribute) as String?) == "title" }
            if isBanner {
                let description: String = AX.value(child, kAXDescriptionAttribute) ?? ""
                result.append((identifier ?? description, child))
            } else {
                collectBanners(in: child, depth: depth + 1, into: &result)
            }
        }
    }

    private func parse(_ banner: AXUIElement, id: String) -> EdgeNotification? {
        var fields: [String: String] = [:]
        for child in AX.children(banner) {
            guard let key: String = AX.value(child, kAXIdentifierAttribute),
                  let value: String = AX.value(child, kAXValueAttribute) else { continue }
            fields[key] = value
        }
        let title = fields["title"] ?? ""
        let subtitle = fields["subtitle"] ?? ""
        let body = fields["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }

        // The description is "<App>, <title>, <subtitle>, <body>"; strip the known
        // suffix rather than splitting on commas, since app names can contain them.
        let description: String = AX.value(banner, kAXDescriptionAttribute) ?? ""
        let suffix = [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: ", ")
        let app: String
        if description.hasSuffix(", " + suffix) {
            app = String(description.dropLast(suffix.count + 2))
        } else {
            app = description.components(separatedBy: ", ").first ?? "Notification"
        }
        return EdgeNotification(id: id, app: app.isEmpty ? "Notification" : app, title: title,
                                subtitle: subtitle, body: body, date: Date())
    }

    private func showToast(_ notification: EdgeNotification) {
        toast = notification
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: settings.toastSeconds, repeats: false) { [weak self] _ in
            if self?.toast?.id == notification.id { self?.toast = nil }
        }
    }

    private func pruneMemory() {
        let cutoff = Date().addingTimeInterval(-600)
        recentContent = recentContent.filter { $0.value > cutoff }
        if seenIDs.count > 2000 { seenIDs = Set(liveBanners.keys) }
    }
}
