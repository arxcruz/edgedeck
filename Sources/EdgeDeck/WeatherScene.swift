import AppKit
import QuartzCore
import SwiftUI

/// iOS Weather–style animated sky behind the Weather widget: a gradient for the
/// condition and time of day, plus sun glow, stars, drifting clouds, rain, snow,
/// fog or lightning.
///
/// Built from Core Animation layers with repeating animations, which the window
/// server runs on its own: EdgeDeck does no per-frame work. (A SwiftUI Canvas in a
/// TimelineView cost ~0.5% CPU per frame per second, whatever it drew.)
struct WeatherScene: NSViewRepresentable {
    let code: Int
    let isDay: Bool
    /// Freezes the animations while the widget isn't visible.
    var paused = false

    func makeNSView(context: Context) -> WeatherSceneView { WeatherSceneView() }

    func updateNSView(_ view: WeatherSceneView, context: Context) {
        view.configure(kind: Kind(code: code), isDay: isDay, paused: paused || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    enum Kind: Equatable {
        case clear, partlyCloudy, overcast, fog, drizzle, rain, heavyRain, snow, thunder

        init(code: Int) {
            switch code {
            case 0: self = .clear
            case 1, 2: self = .partlyCloudy
            case 3: self = .overcast
            case 45, 48: self = .fog
            case 51, 53, 55, 56, 57: self = .drizzle
            case 61, 63, 66, 80, 81: self = .rain
            case 65, 67, 82: self = .heavyRain
            case 71, 73, 75, 77, 85, 86: self = .snow
            case 95, 96, 99: self = .thunder
            default: self = .overcast
            }
        }

        func sky(isDay: Bool) -> [String] {
            switch (self, isDay) {
            case (.clear, true): ["#2F6FC4", "#5EA2E6"]
            case (.partlyCloudy, true): ["#3C6EA8", "#6C9CCB"]
            case (.overcast, true), (.fog, true): ["#56657A", "#7D8A9B"]
            case (.drizzle, true), (.rain, true): ["#3E4C5E", "#5D6B7C"]
            case (.heavyRain, true), (.thunder, true): ["#262E3A", "#434D5B"]
            case (.snow, true): ["#6F8296", "#A3B1BF"]
            case (.clear, false), (.partlyCloudy, false): ["#070B1F", "#1B2547"]
            case (.snow, false): ["#1D2533", "#3A4556"]
            default: ["#12161F", "#2A303C"]
            }
        }
    }
}

final class WeatherSceneView: NSView {
    private let root = CALayer()
    private var built: (kind: WeatherScene.Kind, isDay: Bool, size: CGSize)?
    private var kind = WeatherScene.Kind.clear
    private var isDay = true
    private var paused = false

    init() {
        super.init(frame: .zero)
        // Layers use AppKit's bottom-left origin (geometry flipping isn't honoured
        // everywhere), so positions below are written top-down and converted with `up`.
        root.masksToBounds = true
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lets taps reach the widget's buttons above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(kind: WeatherScene.Kind, isDay: Bool, paused: Bool) {
        self.kind = kind
        self.isDay = isDay
        rebuildIfNeeded()
        setPaused(paused)
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        built = nil
        rebuildIfNeeded()
    }

    private func setPaused(_ pause: Bool) {
        guard pause != paused else { return }
        paused = pause
        if pause {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
        } else {
            let pausedAt = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }

    private func rebuildIfNeeded() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        if let built, built.kind == kind, built.isDay == isDay, built.size == size { return }
        built = (kind, isDay, size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let sky = CAGradientLayer()
        sky.frame = bounds
        sky.colors = kind.sky(isDay: isDay).map { NSColor(Color(hex: $0)).cgColor }
        sky.startPoint = CGPoint(x: 0.5, y: 1)
        sky.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(sky)

        switch kind {
        case .clear:
            if isDay { addSun(size) } else { addStars(size, count: 60) }
        case .partlyCloudy:
            if isDay { addSun(size) } else { addStars(size, count: 40) }
            addClouds(size, count: 3, opacity: isDay ? 0.55 : 0.18)
        case .overcast:
            addClouds(size, count: 6, opacity: isDay ? 0.35 : 0.12)
        case .fog:
            addFog(size)
        case .drizzle:
            addClouds(size, count: 4, opacity: isDay ? 0.25 : 0.1)
            addRain(size, count: 40, speed: 380, length: 10, opacity: 0.3)
        case .rain:
            addClouds(size, count: 5, opacity: isDay ? 0.25 : 0.1)
            addRain(size, count: 90, speed: 700, length: 18, opacity: 0.35)
        case .heavyRain:
            addClouds(size, count: 5, opacity: isDay ? 0.2 : 0.08)
            addRain(size, count: 170, speed: 950, length: 26, opacity: 0.4)
        case .snow:
            addClouds(size, count: 4, opacity: isDay ? 0.3 : 0.1)
            addSnow(size, count: 70)
        case .thunder:
            addClouds(size, count: 5, opacity: 0.12)
            addRain(size, count: 140, speed: 900, length: 24, opacity: 0.38)
            addLightning(size)
        }
        CATransaction.commit()
    }

    /// Top-down y → layer y.
    private func up(_ y: CGFloat) -> CGFloat { bounds.height - y }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }

    /// A repeating animation that starts at a random point of its cycle.
    private func looping(_ keyPath: String, from: Any, to: Any, duration: Double, autoreverses: Bool = false,
                         timing: CAMediaTimingFunctionName = .linear) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = autoreverses
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.timeOffset = .random(in: 0..<duration * (autoreverses ? 2 : 1))
        a.isRemovedOnCompletion = false
        return a
    }

    private func addSun(_ size: CGSize) {
        let center = CGPoint(x: size.width * 0.86, y: up(size.height * 0.02))
        let radius = max(size.width, size.height) * 0.55
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [NSColor(Color(hex: "#FFE9A8")).withAlphaComponent(0.55).cgColor,
                       NSColor(Color(hex: "#FFD36B")).withAlphaComponent(0.18).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 0.45, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        glow.position = center
        glow.add(looping("transform.scale", from: 0.96, to: 1.04, duration: 4, autoreverses: true, timing: .easeInEaseOut), forKey: "pulse")
        root.addSublayer(glow)

        // Faint rays turning slowly around the sun.
        let rays = CAShapeLayer()
        let path = CGMutablePath()
        let length = radius * 1.2
        for i in 0..<12 {
            let angle = Double(i) / 12 * 2 * .pi
            path.move(to: CGPoint(x: length, y: length))
            path.addLine(to: CGPoint(x: length + cos(angle - 0.05) * length, y: length + sin(angle - 0.05) * length))
            path.addLine(to: CGPoint(x: length + cos(angle + 0.05) * length, y: length + sin(angle + 0.05) * length))
            path.closeSubpath()
        }
        rays.path = path
        rays.fillColor = NSColor.white.withAlphaComponent(0.09).cgColor
        rays.bounds = CGRect(x: 0, y: 0, width: length * 2, height: length * 2)
        rays.position = center
        rays.contentsScale = scale
        let fade = CAGradientLayer()
        fade.type = .radial
        fade.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 1)
        fade.frame = rays.bounds
        rays.mask = fade
        rays.add(looping("transform.rotation.z", from: 0, to: 2 * Double.pi, duration: 120), forKey: "spin")
        root.addSublayer(rays)
    }

    private func addStars(_ size: CGSize, count: Int) {
        for _ in 0..<count {
            let r = CGFloat.random(in: 0.6...2)
            let star = CALayer()
            star.backgroundColor = NSColor.white.cgColor
            star.cornerRadius = r
            star.frame = CGRect(x: .random(in: 0...size.width), y: up(.random(in: 0...size.height * 0.8)), width: r * 2, height: r * 2)
            star.opacity = 0.9
            star.add(looping("opacity", from: 0.2, to: 0.95, duration: .random(in: 1.5...5), autoreverses: true, timing: .easeInEaseOut), forKey: "twinkle")
            root.addSublayer(star)
        }
    }

    private func addClouds(_ size: CGSize, count: Int, opacity: Float) {
        let sprites = CloudSprites.clouds
        guard !sprites.isEmpty else { return }
        for i in 0..<count {
            let width = size.width * .random(in: 0.45...0.8)
            let height = width * CloudSprites.cloudAspect
            let cloud = CALayer()
            cloud.contents = sprites[i % sprites.count]
            cloud.contentsGravity = .resize
            cloud.opacity = opacity
            cloud.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let y = size.height * .random(in: 0...0.45) + height * 0.15
            cloud.position = CGPoint(x: -width / 2, y: up(y))
            let span = size.width + width
            cloud.add(looping("position.x", from: -width / 2, to: -width / 2 + span, duration: span / .random(in: 6...16)), forKey: "drift")
            root.addSublayer(cloud)
        }
    }

    private func addFog(_ size: CGSize) {
        guard let band = CloudSprites.fog else { return }
        for i in 0..<5 {
            let layer = CALayer()
            layer.contents = band
            layer.contentsGravity = .resize
            layer.opacity = isDay ? 0.5 : 0.25
            layer.bounds = CGRect(x: 0, y: 0, width: size.width * 1.4, height: size.height * 0.35)
            let y = size.height * (0.08 + Double(i) * 0.18) + size.height * 0.175
            layer.position = CGPoint(x: size.width / 2, y: up(y))
            let drift = size.width * 0.15
            layer.add(looping("position.x", from: size.width / 2 - drift, to: size.width / 2 + drift,
                              duration: .random(in: 25...45), autoreverses: true, timing: .easeInEaseOut), forKey: "drift")
            root.addSublayer(layer)
        }
    }

    private func addRain(_ size: CGSize, count: Int, speed: Double, length: Double, opacity: Float) {
        let slant = 0.18
        for _ in 0..<count {
            let l = length * .random(in: 0.7...1.3)
            let v = speed * .random(in: 0.75...1.25)
            let drop = CALayer()
            drop.backgroundColor = NSColor.white.cgColor
            drop.opacity = opacity
            drop.cornerRadius = 0.65
            drop.bounds = CGRect(x: 0, y: 0, width: 1.3, height: l)
            drop.setAffineTransform(CGAffineTransform(rotationAngle: -atan(slant)))  // top leans right
            // Falls from above the top edge to below the bottom, drifting left with the slant.
            let travel = size.height + l * 2
            let startX = Double.random(in: 0...(size.width + size.height * slant))
            let from = CGPoint(x: startX, y: up(-l))
            let to = CGPoint(x: startX - travel * slant, y: up(size.height + l))
            drop.position = from
            drop.add(looping("position", from: NSValue(point: from), to: NSValue(point: to), duration: travel / v), forKey: "fall")
            root.addSublayer(drop)
        }
    }

    private func addSnow(_ size: CGSize, count: Int) {
        for _ in 0..<count {
            let depth = Double.random(in: 0...1)  // nearer flakes are bigger, faster and brighter
            let r = 1.2 + depth * 2.8
            let flake = CALayer()
            flake.backgroundColor = NSColor.white.cgColor
            flake.cornerRadius = r
            flake.opacity = Float(0.45 + depth * 0.45)
            flake.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            let x = Double.random(in: 0...size.width)
            flake.position = CGPoint(x: x, y: up(-r))
            let travel = size.height + r * 2
            flake.add(looping("position.y", from: up(-r), to: up(size.height + r), duration: travel / (18 + depth * 40)), forKey: "fall")
            let sway = 8 + depth * 14
            flake.add(looping("position.x", from: x - sway, to: x + sway, duration: .random(in: 2...4), autoreverses: true, timing: .easeInEaseOut), forKey: "sway")
            root.addSublayer(flake)
        }
    }

    /// A double flash every ~8.5 s.
    private func addLightning(_ size: CGSize) {
        let flash = CALayer()
        flash.frame = CGRect(origin: .zero, size: size)
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        let a = CAKeyframeAnimation(keyPath: "opacity")
        let cycle = 8.5
        a.values = [0, 0, 0.28, 0.06, 0.2, 0, 0]
        a.keyTimes = [0, 0.6, 0.61, 0.62, 0.64, 0.68, 1].map { NSNumber(value: $0) }
        a.duration = cycle
        a.repeatCount = .infinity
        a.timeOffset = .random(in: 0..<cycle)
        a.isRemovedOnCompletion = false
        flash.add(a, forKey: "flash")
        root.addSublayer(flash)
    }
}

/// Pre-blurred white cloud and fog shapes, rendered once.
@MainActor
enum CloudSprites {
    static let cloudAspect: CGFloat = 0.42

    static let clouds: [CGImage] = (0..<3).compactMap { variant in
        let width: CGFloat = 480, height = width * cloudAspect
        // Puffs across the middle; the margin leaves room for the blur.
        let puffs: [(x: CGFloat, r: CGFloat)] = [
            [(0.22, 0.20), (0.38, 0.30), (0.55, 0.26), (0.72, 0.19)],
            [(0.20, 0.17), (0.34, 0.24), (0.50, 0.32), (0.66, 0.24), (0.80, 0.16)],
            [(0.28, 0.24), (0.46, 0.28), (0.64, 0.22)],
        ][variant]
        let view = ZStack(alignment: .topLeading) {
            ForEach(Array(puffs.enumerated()), id: \.offset) { _, puff in
                let r = puff.r * width * 0.5
                Circle().fill(.white)
                    .frame(width: r * 2, height: r * 2)
                    .offset(x: puff.x * width - r, y: height * 0.62 - r * 1.5)
            }
            Capsule().fill(.white)
                .frame(width: width * 0.62, height: height * 0.26)
                .offset(x: width * 0.19, y: height * 0.5)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .blur(radius: 18)
        return render(view)
    }

    static let fog: CGImage? = render(
        Ellipse().fill(.white).padding(40).frame(width: 600, height: 160).blur(radius: 30))

    private static func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}
