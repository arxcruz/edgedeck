import XCTest
@testable import EdgeSensors

final class SensorsTests: XCTestCase {
    func testFahrenheitConversion() {
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: 40), 40)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 0), 32, accuracy: 0.001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 100), 212, accuracy: 0.001)
        XCTAssertEqual(TemperatureUnit.celsius.toggled, .fahrenheit)
        XCTAssertEqual(TemperatureUnit.fahrenheit.toggled, .celsius)
    }

    func testHeatLevelUsesCelsiusThresholds() {
        XCTAssertEqual(HeatLevel(celsius: 69.9), .normal)
        XCTAssertEqual(HeatLevel(celsius: 70), .warm)
        XCTAssertEqual(HeatLevel(celsius: 89.9), .warm)
        XCTAssertEqual(HeatLevel(celsius: 90), .hot)
    }

    func testStoppedFanIsIdle() {
        XCTAssertTrue(FanReading(rpm: 0, minRPM: 2317, maxRPM: 7826).isIdle)
        XCTAssertFalse(FanReading(rpm: 2400, minRPM: 2317, maxRPM: 7826).isIdle)
    }

    func testFanFractionIsClamped() {
        XCTAssertEqual(FanReading(rpm: 3913, minRPM: 2317, maxRPM: 7826).fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(FanReading(rpm: 9000, minRPM: 2317, maxRPM: 7826).fraction, 1)
        XCTAssertEqual(FanReading(rpm: 100, minRPM: 0, maxRPM: 0).fraction, 0)
    }

    func testHottestIgnoresBrokenSensors() {
        XCTAssertEqual(SensorFilter.hottest([38, 41.5, -9202.9, 0, 300]), 41.5)
        XCTAssertNil(SensorFilter.hottest([0, -9000]))
        XCTAssertNil(SensorFilter.hottest([]))
    }
}
