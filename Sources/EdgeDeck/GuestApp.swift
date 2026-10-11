import AppKit
import ApplicationServices

/// Thin helpers over the Accessibility API.
enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = value(window, kAXPositionAttribute),
              let sizeValue: AXValue = value(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// `rect` is in global top-left-origin coordinates (the Accessibility/CoreGraphics space).
    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Move first so the size isn't clamped by the old display, then size, then
        // move again in case the app adjusted its origin while resizing.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
    }

    /// Converts an AppKit (bottom-left origin) screen rect into AX coordinates.
    static func rect(fromScreen rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct GuestApp {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let window: AXUIElement
    let originalFrame: CGRect
    let edgeFrame: CGRect
}

/// Brings an app's window to the Edge as the Guest app (leaving room for the Rail) and sends it back.
final class GuestAppManager: ObservableObject {
    @Published private(set) var current: GuestApp?
    @Published var lastError: String?

    /// AppKit-coordinates frame of the Edge display; set by the window controller.
    var screenFrame: NSRect = .zero
    var railWidth: Double = 150

    private var monitor: Timer?

    /// Launches/activates `identifier` and brings its front window to the Edge once one exists.
    func bringToEdge(_ identifier: String) {
        if let app = AppLocator.running(identifier) {
            app.activate()
            bringToEdgeWhenReady(app)
        } else {
            AppLocator.open(identifier) { [weak self] app in
                guard let app else {
                    self?.lastError = "Couldn't find \(identifier)"
                    return
                }
                self?.bringToEdgeWhenReady(app)
            }
        }
    }

    /// Polls until the app has a usable window (it may still be launching or
    /// switching conversations), then brings it to the Edge.
    func bringToEdgeWhenReady(_ app: NSRunningApplication, attempts: Int = 20) {
        if let window = Self.frontWindow(of: app) {
            bringToEdge(window, of: app)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.bringToEdgeWhenReady(app, attempts: attempts - 1)
            }
        } else {
            lastError = "\(app.localizedName ?? "App") has no window to move"
        }
    }

    func bringToEdge(_ window: AXUIElement, of app: NSRunningApplication) {
        guard screenFrame != .zero, let originalFrame = AX.frame(of: window) else { return }
        if let current, CFEqual(current.window, window) {
            AX.setFrame(window, current.edgeFrame)
            return
        }
        sendBack()

        var target = screenFrame
        target.size.width -= railWidth
        let axTarget = AX.rect(fromScreen: target)
        AX.setFrame(window, axTarget)
        AX.perform(window, kAXRaiseAction)

        current = GuestApp(pid: app.processIdentifier, name: app.localizedName ?? "App", icon: app.icon,
                           window: window, originalFrame: originalFrame, edgeFrame: axTarget)
        lastError = nil
        startMonitoring()
    }

    /// Puts the window back where it came from.
    func sendBack() {
        guard let current else { return }
        AX.setFrame(current.window, current.originalFrame)
        self.current = nil
        monitor?.invalidate()
    }

    func activate() {
        guard let current else { return }
        NSRunningApplication(processIdentifier: current.pid)?.activate()
        AX.perform(current.window, kAXRaiseAction)
    }

    /// Forget the current window if it was closed or dragged off the Edge.
    private func startMonitoring() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let current = self.current else { return }
            let edge = AX.rect(fromScreen: self.screenFrame)
            guard let frame = AX.frame(of: current.window), edge.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                self.current = nil
                self.monitor?.invalidate()
                return
            }
        }
    }

    static func frontWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let candidates: [AXUIElement?] = [
            AX.value(element, kAXFocusedWindowAttribute),
            AX.value(element, kAXMainWindowAttribute),
        ] + (AX.value(element, kAXWindowsAttribute) as [AXUIElement]? ?? []).map { Optional($0) }
        return candidates.compactMap { $0 }.first { window in
            let subrole: String? = AX.value(window, kAXSubroleAttribute)
            let minimized: Bool = AX.value(window, kAXMinimizedAttribute) ?? false
            return subrole == kAXStandardWindowSubrole && !minimized
        }
    }
}
