import Foundation

/// The unit a Temperature Widget shows. Readings are always kept in Celsius.
public enum TemperatureUnit: String, Codable, Sendable {
    case celsius, fahrenheit

    public var symbol: String { self == .celsius ? "°C" : "°F" }

    public var toggled: TemperatureUnit { self == .celsius ? .fahrenheit : .celsius }

    public func value(fromCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

/// How worried to be about a temperature. The thresholds are in Celsius whichever unit is shown.
public enum HeatLevel: Sendable {
    case normal, warm, hot

    public static let warmFrom = 70.0
    public static let hotFrom = 90.0

    public init(celsius: Double) {
        self = celsius >= Self.hotFrom ? .hot : celsius >= Self.warmFrom ? .warm : .normal
    }
}

/// One fan: its speed now and the range its Mac allows.
public struct FanReading: Equatable, Sendable {
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double

    public init(rpm: Double, minRPM: Double, maxRPM: Double) {
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// Macs stop their fans altogether when cool, so a fan below its minimum speed is not turning.
    public var isIdle: Bool { rpm < max(minRPM / 2, 1) }

    /// Share of the fan's top speed, 0...1.
    public var fraction: Double { maxRPM > 0 ? min(max(rpm / maxRPM, 0), 1) : 0 }
}

/// Reduces the readings of many sensors to the one a Widget shows: the hottest believable one.
public enum SensorFilter {
    /// A sensor that reads outside this range is broken or not wired up, not a temperature.
    public static let believable = 10.0...125.0

    public static func hottest(_ readings: [Double]) -> Double? {
        readings.filter { believable.contains($0) }.max()
    }
}
