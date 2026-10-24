import Foundation

/// A price level on one Symbol or Currency pair. It fires once, when the Quote reaches it, and
/// stays Triggered until the user re-arms it.
public struct PriceAlert: Codable, Hashable, Sendable {
    public var level: Double
    /// True for "rises to", false for "falls to".
    public var rises: Bool
    public var triggered: Bool
    /// The user has Tapped the Triggered Alert, so its Widget stops pulsing; it stays Triggered.
    public var acknowledged: Bool

    public init(level: Double, rises: Bool, triggered: Bool = false, acknowledged: Bool = false) {
        self.level = level
        self.rises = rises
        self.triggered = triggered
        self.acknowledged = acknowledged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(Double.self, forKey: .level)
        rises = try c.decode(Bool.self, forKey: .rises)
        triggered = try c.decodeIfPresent(Bool.self, forKey: .triggered) ?? false
        acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
    }

    /// Fired and not yet Tapped: the Widget pulses.
    public var isPulsing: Bool { triggered && !acknowledged }

    /// An armed Alert whose level the price has reached.
    public func isReached(by price: Double) -> Bool {
        !triggered && (rises ? price >= level : price <= level)
    }

    /// The same Alert for the pair read the other way round (BRL → EUR becomes EUR → BRL).
    public var inverted: PriceAlert {
        PriceAlert(level: 1 / level, rises: !rises, triggered: triggered, acknowledged: acknowledged)
    }

    /// Why a new Alert can't be armed at `price`: it would fire the moment it is made.
    public static func refusal(level: Double, rises: Bool, price: Double?) -> String? {
        guard level > 0 else { return "Enter a level above 0" }
        guard let price else { return "No price yet, try again in a moment" }
        if rises, price >= level { return "Already above \(format(level))" }
        if !rises, price <= level { return "Already below \(format(level))" }
        return nil
    }

    public static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 4 : 2)).grouping(.never))
    }
}

/// Two currencies, from → to, shown by one Currency Widget.
public struct CurrencyPair: Codable, Hashable, Sendable {
    public static let codes = ["USD", "EUR", "BRL", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "MXN", "ARS", "INR"]

    public var from: String
    public var to: String
    public var alert: PriceAlert?

    public init(from: String = "BRL", to: String = "EUR", alert: PriceAlert? = nil) {
        self.from = from
        self.to = to
        self.alert = alert
    }

    /// The Symbol quoting how much `to` one `from` buys, e.g. "BRLEUR=X".
    public var ticker: String { "\(from)\(to)=X" }

    /// Reads the pair the other way round, carrying an armed Alert along.
    public var flipped: CurrencyPair {
        CurrencyPair(from: to, to: from, alert: alert?.inverted)
    }
}

/// The latest price of a Symbol or Currency pair.
public struct Quote: Equatable, Sendable {
    public var price: Double
    public var previousClose: Double?
    public var name: String?
    public var currency: String?
    public var marketOpen: Bool
    public var fetched: Date

    public init(price: Double, previousClose: Double? = nil, name: String? = nil, currency: String? = nil,
                marketOpen: Bool = true, fetched: Date = Date()) {
        self.price = price
        self.previousClose = previousClose
        self.name = name
        self.currency = currency
        self.marketOpen = marketOpen
        self.fetched = fetched
    }

    /// The change on the day, in percent.
    public var changePercent: Double? {
        guard let previousClose, previousClose > 0 else { return nil }
        return (price - previousClose) / previousClose * 100
    }
}

public struct SearchHit: Equatable, Identifiable, Sendable {
    public var symbol: String
    public var name: String
    public var exchange: String
    public var id: String { symbol }
}

/// Yahoo Finance's public endpoints (ADR 0004): which URLs to ask, and how to read the answers.
public enum YahooFeed {
    public struct ParseError: Error {}

    public static func chartURL(_ ticker: String) -> URL? {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/")
        components?.path += ticker
        components?.queryItems = [.init(name: "interval", value: "1d"), .init(name: "range", value: "1d")]
        return components?.url
    }

    public static func searchURL(_ text: String) -> URL? {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")
        components?.queryItems = [.init(name: "q", value: text), .init(name: "quotesCount", value: "8"), .init(name: "newsCount", value: "0")]
        return components?.url
    }

    private struct Chart: Decodable {
        struct Period: Decodable { var start: TimeInterval?; var end: TimeInterval? }
        struct Meta: Decodable {
            var regularMarketPrice: Double?
            var chartPreviousClose: Double?
            var previousClose: Double?
            var shortName: String?
            var longName: String?
            var currency: String?
            var currentTradingPeriod: Trading?
        }
        struct Trading: Decodable { var regular: Period? }
        struct Result: Decodable { var meta: Meta }
        struct Body: Decodable { var result: [Result]? }
        var chart: Body
    }

    public static func parseChart(_ data: Data, now: Date = Date()) throws -> Quote {
        let decoded = try JSONDecoder().decode(Chart.self, from: data)
        guard let meta = decoded.chart.result?.first?.meta, let price = meta.regularMarketPrice, price > 0 else { throw ParseError() }
        var open = true
        if let period = meta.currentTradingPeriod?.regular, let start = period.start, let end = period.end {
            open = now.timeIntervalSince1970 >= start && now.timeIntervalSince1970 <= end
        }
        return Quote(price: price, previousClose: meta.previousClose ?? meta.chartPreviousClose,
                     name: meta.shortName ?? meta.longName, currency: meta.currency, marketOpen: open, fetched: now)
    }

    private struct Search: Decodable {
        struct Hit: Decodable {
            var symbol: String?
            var shortname: String?
            var longname: String?
            var exchDisp: String?
            var quoteType: String?
        }
        var quotes: [Hit]
    }

    public static func parseSearch(_ data: Data) throws -> [SearchHit] {
        try JSONDecoder().decode(Search.self, from: data).quotes.compactMap { hit in
            guard let symbol = hit.symbol, !symbol.isEmpty, hit.quoteType != "CURRENCY" else { return nil }
            return SearchHit(symbol: symbol, name: hit.shortname ?? hit.longname ?? symbol, exchange: hit.exchDisp ?? "")
        }
    }
}

/// How often the shared feed asks for new Quotes.
public enum Cadence {
    public static let choices: [TimeInterval] = [30, 60, 300, 900]
    public static let defaultSeconds: TimeInterval = 300
    /// What the feed slows to while every market it follows is closed.
    public static let closedSeconds: TimeInterval = 900
    /// The least time between two refreshes of one Widget by hand.
    public static let cooldown: TimeInterval = 10

    public static func interval(chosen: TimeInterval, anyMarketOpen: Bool) -> TimeInterval {
        anyMarketOpen ? chosen : max(chosen, closedSeconds)
    }

    /// A Quote is stale when it is older than two intervals (an update failed or was missed).
    public static func isStale(_ quote: Quote, interval: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(quote.fetched) > interval * 2 + 5
    }
}
