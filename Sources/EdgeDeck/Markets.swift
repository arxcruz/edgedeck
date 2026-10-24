import AppKit
import EdgeMarkets
import SwiftUI

/// The one feed behind every Stocks and Currency Widget (ADR 0004): it asks Yahoo only for the
/// Symbols and Currency pairs the Widgets hold, and checks every Alert as each Quote comes in.
final class MarketsModel: ObservableObject {
    @Published private(set) var quotes: [String: Quote] = [:]
    /// Tickers whose last fetch failed: their Quote (if any) is stale.
    @Published private(set) var failed: Set<String> = []
    /// Tickers being fetched now.
    @Published private(set) var refreshing: Set<String> = []
    /// Triggered Alerts whose Toast was closed with ✕: silent, but the Widget pulses until Tapped.
    @Published private(set) var silenced: Set<UUID> = []

    /// The Stocks and Currency Widgets in the config, by id; set by AppModel.
    var widgets: [UUID: WidgetConfig] = [:] {
        didSet {
            objectWillChange.send()
            fetch(tickers.filter { quotes[$0] == nil && !refreshing.contains($0) })
        }
    }
    /// The seconds between updates the user chose in the Settings window.
    var chosenSeconds = Cadence.defaultSeconds
    /// Changes one Widget's config; set by AppModel.
    var update: (UUID, @escaping (inout WidgetConfig) -> Void) -> Void = { _, _ in }

    private var lastAttempt: [String: Date] = [:]
    private var lastManual: [UUID: Date] = [:]
    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) EdgeDeck"]
        return URLSession(configuration: config)
    }()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.fetchDue() }
        // Right after the Mac wakes, not hours-old Quotes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refreshAll() }
        }
    }

    // MARK: Reading

    /// Every ticker the Widgets hold.
    var tickers: Set<String> {
        var all = Set<String>()
        for widget in widgets.values {
            widget.watchlist?.forEach { all.insert($0.ticker) }
            if let pair = widget.pair { all.insert(pair.ticker) }
        }
        return all
    }

    /// The seconds between updates now: slower while every market followed is closed.
    var interval: TimeInterval {
        let followed = tickers.compactMap { quotes[$0] }
        return Cadence.interval(chosen: chosenSeconds, anyMarketOpen: followed.isEmpty || followed.contains { $0.marketOpen })
    }

    /// The Quote of `ticker`. A Currency pair just flipped shows the inverse of the Quote of its
    /// reverse until its own arrives.
    func quote(_ ticker: String) -> Quote? {
        if let quote = quotes[ticker] { return quote }
        guard ticker.hasSuffix("=X"), ticker.count == 8 else { return nil }
        let code = ticker.dropLast(2)
        guard var reverse = quotes[String(code.suffix(3) + code.prefix(3)) + "=X"] else { return nil }
        reverse.price = 1 / reverse.price
        reverse.previousClose = reverse.previousClose.map { 1 / $0 }
        return reverse
    }

    func isStale(_ ticker: String) -> Bool {
        guard let quote = quotes[ticker] else { return false }
        return failed.contains(ticker) || Cadence.isStale(quote, interval: interval)
    }

    /// When the Widget's Quotes were last fetched: the oldest of them.
    func updated(_ widget: WidgetConfig) -> Date? {
        let own = tickers(of: widget).compactMap { quotes[$0]?.fetched }
        return own.min()
    }

    func isRefreshing(_ widget: WidgetConfig) -> Bool {
        !refreshing.isDisjoint(with: tickers(of: widget))
    }

    private func tickers(of widget: WidgetConfig) -> [String] {
        (widget.watchlist?.map(\.ticker) ?? []) + (widget.pair.map { [$0.ticker] } ?? [])
    }

    // MARK: Fetching

    private func fetchDue() {
        let now = Date()
        let interval = self.interval
        fetch(tickers.filter { ticker in
            guard !refreshing.contains(ticker) else { return false }
            let wait = failed.contains(ticker) ? min(60, interval) : interval
            return now.timeIntervalSince(lastAttempt[ticker] ?? .distantPast) >= wait - 1
        })
    }

    /// Fetches everything at once (after waking, or when the Dashboard returns from a Plain display).
    func refreshAll() {
        fetch(tickers.filter { !refreshing.contains($0) })
    }

    /// A Tap on a Widget's header: fetches just its Quotes, at most once in `Cadence.cooldown`.
    func refresh(_ widget: WidgetConfig) {
        if let last = lastManual[widget.id], Date().timeIntervalSince(last) < Cadence.cooldown { return }
        lastManual[widget.id] = Date()
        fetch(tickers(of: widget).filter { !refreshing.contains($0) })
    }

    private func fetch<S: Sequence>(_ tickers: S) where S.Element == String {
        for ticker in tickers {
            guard let url = YahooFeed.chartURL(ticker) else { continue }
            refreshing.insert(ticker)
            lastAttempt[ticker] = Date()
            Task {
                let result = try? await YahooFeed.parseChart(session.data(from: url).0)
                await MainActor.run {
                    refreshing.remove(ticker)
                    if let result {
                        quotes[ticker] = result
                        failed.remove(ticker)
                        checkAlerts(ticker, price: result.price)
                    } else {
                        NSLog("EdgeDeck: quote for \(ticker) failed")
                        failed.insert(ticker)
                    }
                }
            }
        }
    }

    func search(_ text: String) async -> [SearchHit] {
        guard let url = YahooFeed.searchURL(text), let data = try? await session.data(from: url).0 else { return [] }
        return (try? YahooFeed.parseSearch(data)) ?? []
    }

    // MARK: Alerts

    /// Fires every armed Alert on `ticker` that the price has reached.
    private func checkAlerts(_ ticker: String, price: Double) {
        for widget in widgets.values {
            var fire = false
            if widget.watchlist?.contains(where: { $0.ticker == ticker && $0.alert?.isReached(by: price) == true }) == true { fire = true }
            if widget.pair?.ticker == ticker, widget.pair?.alert?.isReached(by: price) == true { fire = true }
            guard fire else { continue }
            update(widget.id) { widget in
                for index in (widget.watchlist ?? []).indices where widget.watchlist?[index].ticker == ticker && widget.watchlist?[index].alert?.isReached(by: price) == true {
                    widget.watchlist?[index].alert?.triggered = true
                }
                if widget.pair?.ticker == ticker, widget.pair?.alert?.isReached(by: price) == true { widget.pair?.alert?.triggered = true }
            }
        }
    }

    /// The Widgets whose Alert fired and has not been Tapped, the one holding the Alert first.
    var pulsing: [WidgetConfig] {
        widgets.values.filter { widget in
            widget.watchlist?.contains { $0.alert?.isPulsing == true } == true || widget.pair?.alert?.isPulsing == true
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// What the Toast lists: pulsing minus what ✕ silenced.
    var toastPulsing: [WidgetConfig] { pulsing.filter { !silenced.contains($0.id) } }

    func silenceAll() { silenced.formUnion(pulsing.map(\.id)) }

    /// A Tap on the pulsing Widget or its Toast row: it stops pulsing; the Alert stays Triggered.
    func acknowledge(_ id: UUID) {
        silenced.remove(id)
        update(id) { widget in
            for index in (widget.watchlist ?? []).indices where widget.watchlist?[index].alert?.isPulsing == true {
                widget.watchlist?[index].alert?.acknowledged = true
            }
            if widget.pair?.alert?.isPulsing == true { widget.pair?.alert?.acknowledged = true }
        }
    }
}

// MARK: Formatting

enum MarketFormat {
    static func price(_ value: Double, digits: Int? = nil) -> String {
        let places = digits ?? (value >= 100 ? 2 : value >= 1 ? 2 : 4)
        return value.formatted(.number.precision(.fractionLength(places)))
    }

    static func change(_ percent: Double) -> String {
        (percent >= 0 ? "+" : "−") + abs(percent).formatted(.number.precision(.fractionLength(2))) + "%"
    }

    static func color(_ percent: Double?) -> Color {
        guard let percent else { return Theme.secondaryText }
        return percent > 0 ? Color(hex: "#30D158") : percent < 0 ? Color(hex: "#FF453A") : Theme.secondaryText
    }

    /// "now", "4m", "2h": how long ago.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }

    /// The level as typed in the user's locale, e.g. "0,18".
    static func parse(_ text: String) -> Double? {
        try? Double(text.trimmingCharacters(in: .whitespaces), format: .number)
    }

    static func alertText(_ alert: PriceAlert) -> String {
        (alert.rises ? "rises to " : "falls to ") + PriceAlert.format(alert.level)
    }
}
