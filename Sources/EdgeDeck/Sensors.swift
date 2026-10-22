import EdgeSensors
import Foundation
import IOKit

/// Reads temperatures and fan speeds from the SMC, Apple's sensor chip, through its IOKit user client.
/// The interface is private but needs no elevated privileges. Key names are per chip generation, so
/// anything it can't find reads as unavailable rather than as a wrong number.
final class SMC {
    private struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }

    /// Mirrors the kernel's 80-byte `SMCKeyData_t`.
    private struct Param {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var info: (size: UInt32, type: UInt32, attributes: UInt8, pad: (UInt8, UInt8, UInt8)) = (0, 0, 0, (0, 0, 0))
        var result: UInt8 = 0
        var status: UInt8 = 0
        var selector: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Selector: UInt8 { case readBytes = 5, keyAtIndex = 8, keyInfo = 9 }

    private static let float = fourCC("flt ")

    private var connection: io_connect_t = 0
    /// Sensor keys found once at start-up, so a sample is plain reads: no enumerating, no type look-ups.
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []
    private var fanKeys: [(speed: UInt32, min: Double, max: Double)] = []
    let isOpen: Bool

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { if service != 0 { IOObjectRelease(service) } }
        isOpen = service != 0 && IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
        if isOpen { discover() }
    }

    deinit { if isOpen { IOServiceClose(connection) } }

    var hasTemperatures: Bool { !cpuKeys.isEmpty || !gpuKeys.isEmpty }
    var fanCount: Int { fanKeys.count }

    /// The hottest believable CPU and GPU sensors, in Celsius.
    func temperatures() -> (cpu: Double?, gpu: Double?) {
        (SensorFilter.hottest(cpuKeys.compactMap(readFloat)), SensorFilter.hottest(gpuKeys.compactMap(readFloat)))
    }

    func fans() -> [FanReading] {
        fanKeys.map { FanReading(rpm: readFloat($0.speed) ?? 0, minRPM: $0.min, maxRPM: $0.max) }
    }

    // MARK: Start-up

    private func discover() {
        // Performance and efficiency cores report as Tp*/Te*, GPU clusters as Tg* (Apple silicon).
        let total = readBytes(Self.fourCC("#KEY"), size: 4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } ?? 0
        for index in 0..<total {
            // Names first: asking for the type of every one of the thousands of keys takes half a second.
            guard let key = key(at: index) else { continue }
            let prefix = Self.name(of: key).prefix(2)
            guard prefix == "Tp" || prefix == "Te" || prefix == "Tg",
                  let info = info(of: key), info.type == Self.float, info.size == 4 else { continue }
            if prefix == "Tg" { gpuKeys.append(key) } else { cpuKeys.append(key) }
        }
        let count = readBytes(Self.fourCC("FNum"), size: 1)?.first.map(Int.init) ?? 0
        for fan in 0..<count {
            guard let speed = Self.fanKey(fan, "Ac"), readFloat(speed) != nil else { continue }
            let low = Self.fanKey(fan, "Mn").flatMap(readFloat) ?? 0
            let high = Self.fanKey(fan, "Mx").flatMap(readFloat) ?? 0
            fanKeys.append((speed, low, high))
        }
    }

    // MARK: Reading

    private func call(_ input: Param) -> Param? {
        var input = input
        var output = Param()
        var size = MemoryLayout<Param>.size
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func key(at index: UInt32) -> UInt32? {
        var param = Param()
        param.selector = Selector.keyAtIndex.rawValue
        param.index = index
        return call(param)?.key
    }

    private func info(of key: UInt32) -> KeyInfo? {
        var param = Param()
        param.key = key
        param.selector = Selector.keyInfo.rawValue
        return call(param).map { KeyInfo(size: $0.info.size, type: $0.info.type, attributes: $0.info.attributes) }
    }

    private func readBytes(_ key: UInt32, size: UInt32) -> [UInt8]? {
        var param = Param()
        param.key = key
        param.info.size = size
        param.selector = Selector.readBytes.rawValue
        guard let output = call(param) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
    }

    private func readFloat(_ key: UInt32) -> Double? {
        readBytes(key, size: 4).map { Double($0.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) }
    }

    private static func fourCC(_ string: String) -> UInt32 { string.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func name(of key: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((key >> $0) & 0xFF) }, as: UTF8.self)
    }

    private static func fanKey(_ fan: Int, _ suffix: String) -> UInt32? {
        guard fan < 10 else { return nil }
        return fourCC("F\(fan)\(suffix)")
    }
}

/// Samples the Temperature and Fans Widgets' sensors. Costs nothing while neither is on the page, and
/// otherwise reads fans every `interval` and temperatures every `temperatureInterval`.
final class SensorSampler: ObservableObject {
    static let interval: TimeInterval = 2
    /// Temperatures drift slowly and cost far more to read than fans (about 60 keys against 2).
    static let temperatureInterval: TimeInterval = 4
    static let historyLength = StatsSampler.historyLength

    /// Hottest believable sensor, Celsius. Nil: this Mac doesn't report it.
    @Published var cpu: Double?
    @Published var gpu: Double?
    @Published var cpuHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    /// Nil until the first reading, or when the SMC can't be read at all; empty on a Mac with no fans.
    @Published var fans: [FanReading]?
    /// Speed of the fastest fan, for the Sparkline.
    @Published var fanHistory: [Double] = []

    /// Asked every second which sensors a Widget on the current page shows; the rest aren't read.
    var needs: () -> (temperature: Bool, fans: Bool) = { (true, true) }

    private let queue = DispatchQueue(label: "edgedeck.sensors", qos: .utility)
    private var smc: SMC?
    private var timer: Timer?
    private var lastTemperatures: Date?
    private var busy = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }

    private func sample() {
        let needed = needs()
        guard needed.temperature || needed.fans, !busy else { return }
        busy = true
        let temperaturesDue = needed.temperature
            && (lastTemperatures.map { Date().timeIntervalSince($0) >= Self.temperatureInterval - 0.5 } ?? true)
        if temperaturesDue { lastTemperatures = Date() }
        let fansDue = needed.fans
        queue.async { [weak self] in
            guard let self else { return }
            // Opening the connection and finding the keys happens once, off the main thread.
            let smc = self.smc ?? SMC()
            self.smc = smc
            let temperatures = temperaturesDue ? (smc.hasTemperatures ? smc.temperatures() : (cpu: nil, gpu: nil)) : nil
            let fans = fansDue && smc.isOpen ? smc.fans() : nil
            DispatchQueue.main.async {
                self.busy = false
                self.publish(temperatures: temperatures, fans: fans)
            }
        }
    }

    private func publish(temperatures: (cpu: Double?, gpu: Double?)?, fans newFans: [FanReading]?) {
        if let temperatures {
            cpu = temperatures.cpu
            gpu = temperatures.gpu
            if let value = temperatures.cpu { push(&cpuHistory, value) }
            if let value = temperatures.gpu { push(&gpuHistory, value) }
        }
        // Assigning an unchanged value would still redraw, so fans publish only when the display would differ.
        if let newFans {
            if !Self.sameDisplay(newFans, fans) { fans = newFans }
            push(&fanHistory, newFans.map(\.rpm).max() ?? 0)
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    /// Fan speeds shown to the nearest 10 RPM.
    private static func sameDisplay(_ a: [FanReading], _ b: [FanReading]?) -> Bool {
        guard let b, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { ($0.rpm / 10).rounded() == ($1.rpm / 10).rounded() && $0.maxRPM == $1.maxRPM }
    }
}
