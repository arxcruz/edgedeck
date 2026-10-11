import AppKit
import ApplicationServices
import EdgeTouch
import IOKit.hid

// Touch on the Edge. EdgeDeck holds the touchscreen (it came from Edgetap) and decides at
// touch-down where each touch goes:
//
// - on one of EdgeDeck's own windows (the Dashboard, the Rail, Editors): handed to that window
//   directly as mouse events, inside the app. Nothing is guessed (touch-down is a mouse-down at
//   once, so a held finger shows as pressed) and the cursor never moves.
// - anywhere else (a Guest app, a Plain display): turned into clicks, scrolls and drags by the
//   gesture engine and posted system-wide, as Edgetap does.

/// Touch preferences, in EdgeDeck's own defaults. The first launch copies Edgetap's.
final class TouchSettings {
    var onChange: () -> Void = {}
    private let defaults = UserDefaults.standard

    init() { copyFromEdgetap() }

    private func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "touch." + key) as? T ?? fallback }
    private func store(_ key: String, _ newValue: Any) {
        defaults.set(newValue, forKey: "touch." + key)
        onChange()
    }

    /// Off hands the touchscreen back to macOS (which then drags the cursor around).
    var enabled: Bool {
        get { value("enabled", true) }
        set { store("enabled", newValue) }
    }
    /// Hide the cursor while it's parked on a touch in another app's window.
    var hidesCursor: Bool {
        get { value("hidesCursor", true) }
        set { store("hidesCursor", newValue) }
    }
    /// Multiplier on scroll distance, for finger and coasting.
    var scrollSpeed: Double {
        get { value("scrollSpeed", 1.0) }
        set { store("scrollSpeed", newValue) }
    }
    var reverseScroll: Bool {
        get { value("reverseScroll", false) }
        set { store("reverseScroll", newValue) }
    }
    var momentum: Bool {
        get { value("momentum", true) }
        set { store("momentum", newValue) }
    }
    /// Release speed (points/s) that doubles the coast distance; 0 = no acceleration.
    var flickBoost: Double {
        get { value("flickBoost", 2000.0) }
        set { store("flickBoost", newValue) }
    }
    /// Seconds a finger rests before it becomes a right click / drag in other apps' windows.
    var holdDuration: Double {
        get { value("holdDuration", 0.5) }
        set { store("holdDuration", newValue) }
    }

    private func copyFromEdgetap() {
        guard !defaults.bool(forKey: "touch.copiedFromEdgetap") else { return }
        defaults.set(true, forKey: "touch.copiedFromEdgetap")
        guard let edgetap = UserDefaults(suiteName: TouchController.edgetapBundleID) else { return }
        for key in ["enabled", "hidesCursor", "scrollSpeed", "reverseScroll", "momentum", "flickBoost", "holdDuration"] {
            if let old = edgetap.object(forKey: key) { defaults.set(old, forKey: "touch." + key) }
        }
    }
}

enum TouchStatus: Equatable {
    case running
    case off
    case noEdge
    case needsAccessibility
    case needsInputMonitoring
    /// The old Edgetap app is running and holds the touchscreen.
    case edgetapRunning
    /// Something else (e.g. touch-probe) holds the touchscreen.
    case busy

    var description: String {
        switch self {
        case .running: "Touch active on the Edge"
        case .off: "Touch is off (macOS handles the touchscreen)"
        case .noEdge: "Waiting for the Edge"
        case .needsAccessibility: "Touch needs the \(AppModel.accessibilityName) permission"
        case .needsInputMonitoring: "Touch needs the Input Monitoring permission"
        case .edgetapRunning: "Edgetap is handling touch — quit it to let EdgeDeck"
        case .busy: "Another program is using the touchscreen"
        }
    }
}

final class TouchController: ObservableObject {
    static let edgetapBundleID = "io.github.arxcruz.edgetap"

    @Published private(set) var status = TouchStatus.off
    let settings = TouchSettings()
    /// The Edge's display, set by the app delegate; nil while it's unplugged.
    var display: CGDirectDisplayID? {
        didSet { if display != oldValue { reconcile() } }
    }
    /// Called (once per launch) when the old Edgetap app turns out to be running.
    var onEdgetapFound: () -> Void = {}
    /// While the Edge is a Plain display, a swipe in from its right edge calls `onEdgeSwipe`.
    var plainDisplay = false
    var onEdgeSwipe: () -> Void = {}

    private let engine = GestureEngine()
    private let output = TouchOutput()
    private let input = TouchInput()
    private var wasDown = false
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var askedForInputMonitoring = false
    private var reportedEdgetap = false

    /// The EdgeDeck window the current touch belongs to; nil when it goes to other apps.
    private var ownWindow: NSWindow?
    private var lastOwnPoint = CGPoint.zero
    private var lastOwnTap: (point: CGPoint, time: TimeInterval, count: Int)?
    /// A touch that started at the Edge's right edge on a Plain display: where it started,
    /// and whether it already brought the Dashboard back.
    private var edgeSwipe: (start: Point, done: Bool)?
    private static let edgeZone = 28.0, edgeSwipeDistance = 120.0
    /// A touch that landed on another app's title bar: it drags the window straight away.
    private var titleBarDrag = false

    func start() {
        input.onReport = { [weak self] in self?.handle($0) }
        input.onRemoved = { [weak self] in self?.releaseTouch() }
        settings.onChange = { [weak self] in self?.reconcile() }
        // Our own posted events never produce mouseMoved, so this is the real mouse: hand the cursor back.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.output.abortForMouseMovement()
        }
        reconcile()
        // Cheap, and catches permissions being granted or Edgetap quitting.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    func stop() {
        releaseTouch()
        input.stop()
    }

    func reconcile() {
        output.hidesCursor = settings.hidesCursor
        output.scrollSpeed = settings.scrollSpeed
        output.reverseScroll = settings.reverseScroll
        output.momentumEnabled = settings.momentum
        output.momentumBoost = settings.flickBoost > 0 ? settings.flickBoost : .infinity
        engine.config.holdDuration = settings.holdDuration

        func idle(_ newStatus: TouchStatus) {
            if input.isRunning {
                releaseTouch()
                input.stop()
            }
            if status != newStatus { status = newStatus }
        }
        guard settings.enabled else { return idle(.off) }
        guard display != nil else { return idle(.noEdge) }
        guard AXIsProcessTrusted() else { return idle(.needsAccessibility) }
        do {
            try input.start()
            if status != .running { status = .running }
        } catch let error as TouchInput.StartError where error.isBusy {
            let edgetap = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.edgetapBundleID).isEmpty
            idle(edgetap ? .edgetapRunning : .busy)
            if edgetap, !reportedEdgetap {
                reportedEdgetap = true
                onEdgetapFound()
            }
        } catch {
            idle(.needsInputMonitoring)
            if !askedForInputMonitoring {
                askedForInputMonitoring = true
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
        }
    }

    // MARK: Routing

    private func handle(_ report: TouchReport) {
        guard let display else { return }
        // Recomputed each time: displays may be rearranged while we run.
        let bounds = CGDisplayBounds(display)
        let n = report.normalized
        let local = Point(n.x * bounds.width, n.y * bounds.height)
        let global = CGPoint(x: bounds.minX + local.x, y: bounds.minY + local.y)
        let time = ProcessInfo.processInfo.systemUptime
        defer { wasDown = report.down }

        if report.down && !wasDown {
            let caughtCoast = output.stopMomentum()
            if let window = Self.ownWindow(at: global) {
                ownWindow = window
                lastOwnPoint = global
                post(.leftMouseDown, at: global, to: window, clickCount: ownClickCount(at: global, time: time))
                return
            }
            ownWindow = nil
            if plainDisplay, local.x >= bounds.width - Self.edgeZone {
                edgeSwipe = (local, false)
                return
            }
            if caughtCoast { engine.suppressCurrentTap() }   // catching coasting content shouldn't also click
            // On a title bar there's nothing to scroll, so a drag moves the window at once,
            // without the rest the gesture engine needs.
            if Self.isTitleBar(at: global) {
                titleBarDrag = true
                output.perform(.dragBegin(local), origin: bounds.origin)
                return
            }
        }

        if titleBarDrag {
            if report.down {
                output.perform(.dragMove(local), origin: bounds.origin)
            } else {
                output.perform(.dragEnd(local), origin: bounds.origin)
                titleBarDrag = false
            }
            return
        }

        if let swipe = edgeSwipe {
            if report.down {
                if !swipe.done, swipe.start.x - local.x >= Self.edgeSwipeDistance {
                    edgeSwipe?.done = true
                    onEdgeSwipe()
                }
            } else {
                edgeSwipe = nil
                // A plain tap at the edge still belongs to the window there.
                if !swipe.done, abs(local.x - swipe.start.x) < 16, abs(local.y - swipe.start.y) < 16 {
                    output.perform(.click(swipe.start, count: 1), origin: bounds.origin)
                }
            }
            return
        }

        if let window = ownWindow {
            if report.down {
                guard hypot(global.x - lastOwnPoint.x, global.y - lastOwnPoint.y) >= 0.5 else { return }
                lastOwnPoint = global
                post(.leftMouseDragged, at: global, to: window, clickCount: 1)
            } else {
                post(.leftMouseUp, at: global, to: window, clickCount: lastOwnTap?.count ?? 1)
                ownWindow = nil
            }
            return
        }
        for action in engine.handle(down: report.down, at: local, time: time) {
            output.perform(action, origin: bounds.origin)
        }
    }

    /// Nothing may stay pressed, scrolling or hidden when touch handling stops.
    private func releaseTouch() {
        if let window = ownWindow {
            post(.leftMouseUp, at: lastOwnPoint, to: window, clickCount: 1)
            ownWindow = nil
        }
        wasDown = false
        edgeSwipe = nil
        if titleBarDrag {
            titleBarDrag = false
            output.perform(.dragEnd(Point(0, 0)), origin: display.map { CGDisplayBounds($0).origin } ?? .zero)
        }
        output.stopMomentum()
        let origin = display.map { CGDisplayBounds($0).origin } ?? .zero
        for action in engine.cancel() { output.perform(action, origin: origin) }
    }

    /// Whether `point` (global, top-left origin) is in the title-bar strip of the frontmost
    /// app window there.
    private static func isTitleBar(at point: CGPoint) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        for info in windows {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point) else { continue }
            // The frontmost window under the finger decides; menu bars, panels and the like aren't title bars.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid else { return false }
            return point.y - bounds.minY <= 30
        }
        return false
    }

    /// EdgeDeck's window on top at `point` (global, top-left origin), if the topmost window there is ours.
    private static func ownWindow(at point: CGPoint) -> NSWindow? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return NSApp.windows.first { $0.windowNumber == number && $0.isVisible }
    }

    /// Hands EdgeDeck's own window a mouse event without going through the system: the cursor stays put.
    private func post(_ type: NSEvent.EventType, at point: CGPoint, to window: NSWindow, clickCount: Int) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = window.convertPoint(fromScreen: NSPoint(x: point.x, y: primaryHeight - point.y))
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: clickCount,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func ownClickCount(at point: CGPoint, time: TimeInterval) -> Int {
        let config = engine.config
        var count = 1
        if let last = lastOwnTap, time - last.time <= config.doubleTapInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= config.doubleTapDistance {
            count = last.count % 3 + 1
        }
        lastOwnTap = (point, time, count)
        return count
    }
}
