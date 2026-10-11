import Foundation

/// Exponentially decaying coast after a flick, like trackpad inertia.
public struct MomentumScroll {
    public private(set) var velocity: Point
    private let tau: Double
    private let minSpeed: Double

    /// - Parameters:
    ///   - velocity: release velocity, points per second.
    ///   - tau: decay time constant in seconds; total travel is `velocity * tau`.
    ///   - minSpeed: speed (points/s) below which the coast ends.
    ///   - boost: release speed (points/s) at which the coast gets twice the plain `velocity * tau` travel.
    ///     The gain is `1 + speed / boost`, so hard flicks cover disproportionately more of a long page.
    ///     Pass `.infinity` for no acceleration.
    public init?(velocity: Point, tau: Double = 0.35, minSpeed: Double = 80, startThreshold: Double = 150,
                 boost: Double = 2000, maxSpeed: Double = 20000) {
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= startThreshold else { return nil }
        let boosted = speed * (1 + speed / boost)
        let scale = min(boosted, maxSpeed) / speed
        self.velocity = Point(velocity.x * scale, velocity.y * scale)
        self.tau = tau
        self.minSpeed = minSpeed
    }

    /// Advances by `dt` seconds. Returns the distance to scroll and whether the coast is over.
    public mutating func step(dt: Double) -> (dx: Double, dy: Double, finished: Bool) {
        let decay = exp(-dt / tau)
        let travel = tau * (1 - decay)
        let delta = (dx: velocity.x * travel, dy: velocity.y * travel)
        velocity = Point(velocity.x * decay, velocity.y * decay)
        return (delta.dx, delta.dy, hypot(velocity.x, velocity.y) < minSpeed)
    }
}
