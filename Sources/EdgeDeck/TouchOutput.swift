import ApplicationServices
import AppKit
import Foundation
import EdgeTouch

// Private CoreGraphics calls, the usual way for a background process to hide the cursor.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Posts synthetic mouse/scroll events at the touch point, for touches on other apps'
/// windows (a Guest app, a Plain display). The visible cursor is moved only for the
/// duration of a gesture (including momentum coasting) and put back afterwards. (From Edgetap.)
final class TouchOutput: NSObject {
    // CGScrollPhase / CGMomentumScrollPhase values
    private enum ScrollPhase { static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4 }
    private enum MomentumPhase { static let began: Int64 = 1, `continue`: Int64 = 2, end: Int64 = 3 }

    /// Hide the cursor while it is parked on the touch point (macOS moves it there for every posted event).
    var hidesCursor = true

    /// Multiplier for finger and coasting scroll distance.
    var scrollSpeed = 1.0
    var reverseScroll = false
    var momentumEnabled = true
    /// See `MomentumScroll.init(boost:)`; `.infinity` means no flick acceleration.
    var momentumBoost = 2000.0

    private var scrollGain: Double { scrollSpeed * (reverseScroll ? -1 : 1) }

    private let source = CGEventSource(stateID: .hidSystemState)

    override init() {
        super.init()
        // By default macOS ignores the physical mouse for 0.25 s after we post events or warp the cursor.
        source?.localEventsSuppressionInterval = 0
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }
    private var cursorHidden = false
    private var savedCursor: CGPoint?
    private var pendingRestore: DispatchWorkItem?
    private var scrollStarted = false
    private var scrollRemainder = CGPoint.zero

    private var momentum: MomentumScroll?
    private var momentumTimer: DispatchSourceTimer?
    private var momentumLast = 0.0
    private var momentumStarted = false

    func perform(_ action: GestureAction, origin: CGPoint) {
        func global(_ p: Point) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }

        switch action {
        case let .click(p, count):
            let at = global(p)
            beginGesture(at: at)
            mouse(.leftMouseDown, .left, at, clickState: count)
            mouse(.leftMouseUp, .left, at, clickState: count)
            endGesture()

        case let .rightClick(p):
            let at = global(p)
            beginGesture(at: at)
            mouse(.rightMouseDown, .right, at, clickState: 1)
            mouse(.rightMouseUp, .right, at, clickState: 1)
            endGesture()

        case let .dragBegin(p):
            let at = global(p)
            beginGesture(at: at)
            mouse(.leftMouseDown, .left, at, clickState: 1)

        case let .dragMove(p):
            mouse(.leftMouseDragged, .left, global(p), clickState: 1)

        case let .dragEnd(p):
            mouse(.leftMouseUp, .left, global(p), clickState: 1)
            endGesture()

        case let .scrollBegin(p):
            beginGesture(at: global(p))
            scrollStarted = false
            scrollRemainder = .zero

        case let .scroll(dx, dy):
            scroll(dx: dx, dy: dy)

        case let .scrollEnd(velocity):
            if scrollStarted { postScroll(dx: 0, dy: 0, phase: ScrollPhase.ended) }
            scrollStarted = false
            let scaled = Point(velocity.x * scrollGain, velocity.y * scrollGain)
            if momentumEnabled, let m = MomentumScroll(velocity: scaled, boost: momentumBoost) {
                startMomentum(m)   // keeps the cursor parked on the content until it stops
            } else {
                endGesture()
            }
        }
    }

    /// Stops any coasting. Returns true if something was coasting, i.e. the touch
    /// that triggered this was "catch the content" rather than a new gesture.
    @discardableResult
    func stopMomentum() -> Bool {
        guard momentum != nil else { return false }
        if momentumStarted { postScroll(dx: 0, dy: 0, phase: 0, momentum: MomentumPhase.end) }
        finishMomentum()
        return true
    }

    /// The physical mouse moved: the user wants their cursor back right now. End any coast
    /// where the cursor is, without snapping it back to where it was before the touch.
    func abortForMouseMovement() {
        guard momentum != nil else { return }
        if momentumStarted { postScroll(dx: 0, dy: 0, phase: 0, momentum: MomentumPhase.end) }
        finishMomentum(restoreCursor: false)
    }

    // MARK: - Momentum

    private func startMomentum(_ m: MomentumScroll) {
        momentum = m
        momentumStarted = false
        momentumLast = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.momentumTick() }
        momentumTimer = timer
        timer.resume()
    }

    private func momentumTick() {
        guard var m = momentum else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let step = m.step(dt: min(now - momentumLast, 0.1))
        momentumLast = now
        momentum = m

        let fx = step.dx + scrollRemainder.x, fy = step.dy + scrollRemainder.y
        let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
        scrollRemainder = CGPoint(x: fx - ix, y: fy - iy)
        if ix != 0 || iy != 0 {
            postScroll(dx: ix, dy: iy, phase: 0,
                       momentum: momentumStarted ? MomentumPhase.continue : MomentumPhase.began)
            momentumStarted = true
        }
        if step.finished {
            if momentumStarted { postScroll(dx: 0, dy: 0, phase: 0, momentum: MomentumPhase.end) }
            finishMomentum()
        }
    }

    private func finishMomentum(restoreCursor: Bool = true) {
        momentumTimer?.cancel()
        momentumTimer = nil
        momentum = nil
        momentumStarted = false
        if restoreCursor {
            endGesture()
        } else {
            pendingRestore?.cancel()
            pendingRestore = nil
            savedCursor = nil
            showCursor()
        }
    }

    // MARK: - Cursor handling

    private func beginGesture(at p: CGPoint) {
        if let pending = pendingRestore {
            // A restore is still queued from the previous gesture: keep its saved position.
            pending.cancel()
            pendingRestore = nil
        } else if savedCursor == nil {
            savedCursor = CGEvent(source: nil)?.location
        }
        hideCursor()
        CGWarpMouseCursorPosition(p)
    }

    private func hideCursor() {
        guard hidesCursor, !cursorHidden else { return }
        let connection = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = false
    }

    private func endGesture() {
        guard let saved = savedCursor, pendingRestore == nil else { return }
        // Give the window server a moment to deliver the posted events first.
        let restore = DispatchWorkItem { [weak self] in
            CGWarpMouseCursorPosition(saved)
            self?.showCursor()
            self?.savedCursor = nil
            self?.pendingRestore = nil
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: restore)
    }

    // MARK: - Event posting

    private func mouse(_ type: CGEventType, _ button: CGMouseButton, _ at: CGPoint, clickState: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        // Wheel events are integer pixels; carry the fraction to the next sample.
        let fx = dx * scrollGain + scrollRemainder.x, fy = dy * scrollGain + scrollRemainder.y
        let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
        scrollRemainder = CGPoint(x: fx - ix, y: fy - iy)
        guard ix != 0 || iy != 0 else { return }
        postScroll(dx: ix, dy: iy, phase: scrollStarted ? ScrollPhase.changed : ScrollPhase.began)
        scrollStarted = true
    }

    private func postScroll(dx: Double, dy: Double, phase: Int64, momentum: Int64 = 0) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.post(tap: .cghidEventTap)
    }
}
