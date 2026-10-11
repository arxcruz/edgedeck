import Testing
@testable import EdgeTouch

struct GestureEngineTests {
    private func run(_ engine: GestureEngine, _ steps: [(Bool, Double, Double, Double)]) -> [GestureAction] {
        steps.flatMap { engine.handle(down: $0.0, at: Point($0.1, $0.2), time: $0.3) }
    }

    @Test func tapClicks() {
        let actions = run(GestureEngine(), [(true, 100, 100, 0), (true, 102, 101, 0.05), (false, 102, 101, 0.1)])
        #expect(actions == [.click(Point(100, 100), count: 1)])
    }

    @Test func doubleTapRaisesClickCount() {
        let e = GestureEngine()
        let a = run(e, [(true, 100, 100, 0), (false, 100, 100, 0.05), (true, 104, 100, 0.2), (false, 104, 100, 0.25)])
        #expect(a == [.click(Point(100, 100), count: 1), .click(Point(104, 100), count: 2)])
    }

    @Test func slowSecondTapIsSingle() {
        let e = GestureEngine()
        let a = run(e, [(true, 100, 100, 0), (false, 100, 100, 0.05), (true, 100, 100, 1), (false, 100, 100, 1.05)])
        #expect(a.last == .click(Point(100, 100), count: 1))
    }

    @Test func quickDragScrolls() {
        let a = run(GestureEngine(), [(true, 0, 0, 0), (true, 0, 30, 0.05), (true, 0, 50, 0.1), (false, 0, 50, 0.15)])
        #expect(Array(a.prefix(3)) == [.scrollBegin(Point(0, 0)), .scroll(dx: 0, dy: 30), .scroll(dx: 0, dy: 20)])
        #expect(a.count == 4)
    }

    @Test func holdAndReleaseRightClicks() {
        let a = run(GestureEngine(), [(true, 5, 5, 0), (true, 5, 5, 0.3), (false, 5, 5, 0.6)])
        #expect(a == [.rightClick(Point(5, 5))])
    }

    @Test func holdThenMoveDrags() {
        let a = run(GestureEngine(), [(true, 0, 0, 0), (true, 0, 0, 0.6), (true, 40, 0, 0.7), (false, 40, 0, 0.8)])
        #expect(a == [.dragBegin(Point(0, 0)), .dragMove(Point(40, 0)), .dragEnd(Point(40, 0))])
    }

    @Test func reportParsing() {
        let r = TouchReport(bytes: [0x07, 0x01, 0xAE, 0x0C, 0xB2, 0x0F, 0x00])
        #expect(r == TouchReport(down: true, x: 0x0CAE, y: 0x0FB2))
        #expect(TouchReport(bytes: [0x0D, 0x01, 0, 0, 0, 0, 0]) == nil)
        #expect(TouchReport(bytes: [7, 0, 0, 0, 0, 0, 0])?.down == false)
    }

    private func releaseVelocity(_ a: [GestureAction]) -> Point? {
        if case let .scrollEnd(v)? = a.last { return v }
        return nil
    }

    @Test func flickReleasesWithVelocity() throws {
        let a = run(GestureEngine(), [(true, 0, 0, 0), (true, 0, 40, 0.02), (true, 0, 80, 0.04), (true, 0, 120, 0.06), (false, 0, 120, 0.08)])
        let v = try #require(releaseVelocity(a))
        #expect(abs(v.y - 2000) < 1)
        #expect(v.x == 0)
    }

    @Test func pausedFingerReleasesWithoutVelocity() throws {
        let a = run(GestureEngine(), [(true, 0, 0, 0), (true, 0, 40, 0.02), (true, 0, 80, 0.04), (true, 0, 80, 0.2), (false, 0, 80, 0.25)])
        #expect(try #require(releaseVelocity(a)) == Point(0, 0))
    }

    @Test func tapThatStoppedCoastingDoesNotClick() {
        let e = GestureEngine()
        e.suppressCurrentTap()
        let a = run(e, [(true, 9, 9, 0), (false, 9, 9, 0.05), (true, 9, 9, 1), (false, 9, 9, 1.05)])
        #expect(a == [.click(Point(9, 9), count: 1)])
    }

    @Test func momentumDecaysAndFinishes() throws {
        #expect(MomentumScroll(velocity: Point(0, 100)) == nil)
        var m = try #require(MomentumScroll(velocity: Point(0, 2000), boost: .infinity))
        var total = 0.0
        var steps = 0
        while true {
            let r = m.step(dt: 1.0 / 60)
            total += r.dy
            steps += 1
            if r.finished || steps > 1000 { break }
        }
        #expect(steps < 1000)
        #expect(abs(total - 2000 * 0.35) < 40) // ≈ v·τ, minus what is left below minSpeed
    }

    @Test func fasterFlicksTravelDisproportionatelyFarther() throws {
        func travel(_ speed: Double) throws -> Double {
            var m = try #require(MomentumScroll(velocity: Point(0, speed)))
            var total = 0.0
            for _ in 0..<2000 {
                let r = m.step(dt: 1.0 / 60)
                total += r.dy
                if r.finished { break }
            }
            return total
        }
        let slow = try travel(1000), fast = try travel(3000)
        #expect(fast > slow * 3 * 1.4)   // more than the 3x that linear coasting would give
    }
}
