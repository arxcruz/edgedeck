import Foundation

public struct Point: Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
}

/// What the daemon should do on the Mac. Points are in panel space (display points,
/// origin top-left of the Edge).
public enum GestureAction: Equatable {
    case click(Point, count: Int)
    case rightClick(Point)
    case scrollBegin(Point)
    case scroll(dx: Double, dy: Double)
    /// Finger lifted; `velocity` is in points per second (zero if the finger had stopped).
    case scrollEnd(velocity: Point)
    case dragBegin(Point)
    case dragMove(Point)
    case dragEnd(Point)
}

public struct GestureConfig {
    /// Movement (points) before a touch stops being a tap.
    public var slop = 16.0
    /// Time (seconds) a finger must rest to count as a long press.
    public var holdDuration = 0.5
    public var doubleTapInterval = 0.35
    public var doubleTapDistance = 30.0
    /// Release velocity is measured over this much recent motion (seconds).
    public var velocityWindow = 0.08
    /// If the last sample is older than this at lift-off the finger had stopped (seconds).
    public var staleAfter = 0.06
    public init() {}
}

/// Turns single-contact samples into gestures.
///
/// - tap → click (double/triple tap raise the click count)
/// - move before the hold time → scroll
/// - hold, then move → drag
/// - hold, then lift without moving → right click
public final class GestureEngine {
    private enum State {
        case idle
        case pending(start: Point, since: TimeInterval)
        case scrolling(last: Point)
        case dragging
    }

    public var config: GestureConfig
    private var state = State.idle
    private var lastTap: (point: Point, time: TimeInterval, count: Int)?
    private var samples: [(time: TimeInterval, point: Point)] = []
    private var suppressTap = false

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// The touch that is starting (or about to start) only stopped coasting content,
    /// so it must not also click.
    public func suppressCurrentTap() {
        suppressTap = true
    }

    public func handle(down: Bool, at p: Point, time: TimeInterval) -> [GestureAction] {
        switch state {
        case .idle:
            if down { state = .pending(start: p, since: time) }
            return []

        case let .pending(start, since):
            let held = time - since >= config.holdDuration
            if down {
                guard p.distance(to: start) > config.slop else { return [] }
                if suppressTap { suppressTap = false }
                if held {
                    state = .dragging
                    return [.dragBegin(start), .dragMove(p)]
                }
                state = .scrolling(last: p)
                samples = [(time, p)]
                return [.scrollBegin(start), .scroll(dx: p.x - start.x, dy: p.y - start.y)]
            }
            state = .idle
            if suppressTap {
                suppressTap = false
                return []
            }
            if held { return [.rightClick(start)] }
            return [.click(start, count: nextClickCount(at: start, time: time))]

        case let .scrolling(last):
            if down {
                state = .scrolling(last: p)
                samples.append((time, p))
                samples.removeAll { time - $0.time > config.velocityWindow }
                return [.scroll(dx: p.x - last.x, dy: p.y - last.y)]
            }
            state = .idle
            return [.scrollEnd(velocity: releaseVelocity(at: time))]

        case .dragging:
            if down { return [.dragMove(p)] }
            state = .idle
            return [.dragEnd(p)]
        }
    }

    /// Call when the device disappears mid-gesture so nothing is left pressed.
    public func cancel() -> [GestureAction] {
        defer { state = .idle }
        switch state {
        case .scrolling: return [.scrollEnd(velocity: Point(0, 0))]
        case .dragging: return [.dragEnd(Point(0, 0))]
        default: return []
        }
    }

    private func releaseVelocity(at time: TimeInterval) -> Point {
        defer { samples = [] }
        let recent = samples.filter { time - $0.time <= config.velocityWindow }
        guard let first = recent.first, let last = recent.last,
              time - last.time < config.staleAfter,
              last.time - first.time > 0.01 else { return Point(0, 0) }
        let dt = last.time - first.time
        return Point((last.point.x - first.point.x) / dt, (last.point.y - first.point.y) / dt)
    }

    private func nextClickCount(at p: Point, time: TimeInterval) -> Int {
        var count = 1
        if let last = lastTap,
           time - last.time <= config.doubleTapInterval,
           p.distance(to: last.point) <= config.doubleTapDistance {
            count = last.count % 3 + 1
        }
        lastTap = (p, time, count)
        return count
    }
}
