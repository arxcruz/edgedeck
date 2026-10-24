import XCTest
@testable import EdgeMarkets

final class MarketsTests: XCTestCase {
    func testAlertFiresOnceWhenReached() {
        let rises = PriceAlert(level: 200, rises: true)
        XCTAssertFalse(rises.isReached(by: 199.99))
        XCTAssertTrue(rises.isReached(by: 200))
        XCTAssertTrue(PriceAlert(level: 150, rises: false).isReached(by: 149))
        XCTAssertFalse(PriceAlert(level: 150, rises: false).isReached(by: 151))
        XCTAssertFalse(PriceAlert(level: 200, rises: true, triggered: true).isReached(by: 250))
    }

    func testArmingRefusesALevelAlreadyPast() {
        XCTAssertEqual(PriceAlert.refusal(level: 200, rises: true, price: 205)?.hasPrefix("Already above 200"), true)
        XCTAssertEqual(PriceAlert.refusal(level: 150, rises: false, price: 150)?.hasPrefix("Already below 150"), true)
        XCTAssertNil(PriceAlert.refusal(level: 200, rises: true, price: 190))
        XCTAssertNil(PriceAlert.refusal(level: 150, rises: false, price: 160))
        XCTAssertNotNil(PriceAlert.refusal(level: 200, rises: true, price: nil))
        XCTAssertNotNil(PriceAlert.refusal(level: 0, rises: true, price: 1))
    }

    func testFlippingAPairInvertsItsAlert() {
        let pair = CurrencyPair(from: "BRL", to: "EUR", alert: PriceAlert(level: 0.2, rises: true))
        XCTAssertEqual(pair.ticker, "BRLEUR=X")
        let flipped = pair.flipped
        XCTAssertEqual(flipped.ticker, "EURBRL=X")
        XCTAssertEqual(flipped.alert?.level ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(flipped.alert?.rises, false)
        XCTAssertEqual(flipped.flipped.alert?.level ?? 0, 0.2, accuracy: 0.0001)
    }

    func testChartParsingReadsPriceChangeAndMarketHours() throws {
        let json = """
        {"chart":{"result":[{"meta":{"regularMarketPrice":110,"chartPreviousClose":100,"shortName":"Apple Inc.",
        "currency":"USD","currentTradingPeriod":{"regular":{"start":1000,"end":2000}}}}],"error":null}}
        """.data(using: .utf8)!
        let open = try YahooFeed.parseChart(json, now: Date(timeIntervalSince1970: 1500))
        XCTAssertEqual(open.price, 110)
        XCTAssertEqual(open.changePercent ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(open.name, "Apple Inc.")
        XCTAssertTrue(open.marketOpen)
        XCTAssertFalse(try YahooFeed.parseChart(json, now: Date(timeIntervalSince1970: 2500)).marketOpen)
    }

    func testChartWithoutAPriceIsAnError() {
        let json = #"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try YahooFeed.parseChart(json))
    }

    func testSearchParsingSkipsCurrenciesAndFillsNames() throws {
        let json = """
        {"quotes":[{"symbol":"PETR4.SA","shortname":"PETROBRAS PN","exchDisp":"Sao Paulo","quoteType":"EQUITY"},
        {"symbol":"BRLEUR=X","shortname":"BRL/EUR","quoteType":"CURRENCY"},{"exchDisp":"x"}]}
        """.data(using: .utf8)!
        let hits = try YahooFeed.parseSearch(json)
        XCTAssertEqual(hits, [SearchHit(symbol: "PETR4.SA", name: "PETROBRAS PN", exchange: "Sao Paulo")])
    }

    func testCadenceSlowsWhileMarketsAreClosedAndFlagsStaleQuotes() {
        XCTAssertEqual(Cadence.interval(chosen: 60, anyMarketOpen: true), 60)
        XCTAssertEqual(Cadence.interval(chosen: 60, anyMarketOpen: false), 900)
        XCTAssertEqual(Cadence.interval(chosen: 900, anyMarketOpen: false), 900)
        let now = Date()
        XCTAssertFalse(Cadence.isStale(Quote(price: 1, fetched: now.addingTimeInterval(-300)), interval: 300, now: now))
        XCTAssertTrue(Cadence.isStale(Quote(price: 1, fetched: now.addingTimeInterval(-700)), interval: 300, now: now))
    }
}

final class AlertStorageTests: XCTestCase {
    func testAlertFromOlderConfigDecodesAsArmed() throws {
        let alert = try JSONDecoder().decode(PriceAlert.self, from: #"{"level":5,"rises":true}"#.data(using: .utf8)!)
        XCTAssertFalse(alert.triggered)
        XCTAssertFalse(alert.isPulsing)
    }

    func testTriggeredAlertPulsesUntilAcknowledged() {
        var alert = PriceAlert(level: 5, rises: true, triggered: true)
        XCTAssertTrue(alert.isPulsing)
        alert.acknowledged = true
        XCTAssertFalse(alert.isPulsing)
        XCTAssertTrue(alert.triggered)
    }
}
