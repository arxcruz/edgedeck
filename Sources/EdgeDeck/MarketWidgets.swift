import EdgeMarkets
import SwiftUI

/// The Quotes of a Watchlist. Tap the header to fetch now; a Triggered Alert pulses until Tapped.
struct StocksWidget: View {
    @EnvironmentObject var markets: MarketsModel
    let widget: WidgetConfig

    var body: some View {
        let accent = Theme.accent(for: .stocks)
        let list = widget.watchlist ?? []
        Tile(title: widget.title ?? "Stocks", symbol: WidgetKind.stocks.symbol, accent: accent,
             refresh: TileRefresh(updated: markets.updated(widget), spinning: markets.isRefreshing(widget)) { markets.refresh(widget) }) {
            if list.isEmpty {
                Text("Edit this Widget to add Symbols").foregroundStyle(Theme.secondaryText)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(list) { row($0) }
                    }
                }
            }
        }
        .ringing(list.contains { $0.alert?.isPulsing == true }, color: accent) { markets.acknowledge(widget.id) }
    }

    private func row(_ item: WatchedSymbol) -> some View {
        let quote = markets.quote(item.ticker)
        let stale = quote == nil || markets.isStale(item.ticker)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.ticker).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(item.name)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if let alert = item.alert {
                Image(systemName: alert.triggered ? "bell.badge.fill" : "bell.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(alert.triggered ? Color(hex: "#FF9F0A") : Theme.secondaryText)
            }
            if let quote {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(MarketFormat.price(quote.price)).font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(quote.changePercent.map(MarketFormat.change) ?? "")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MarketFormat.color(quote.changePercent))
                }
            } else {
                Text(markets.failed.contains(item.ticker) ? "Unavailable" : "…")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .opacity(stale ? 0.5 : 1)
    }
}

/// One Currency pair's rate. A Tap flips the pair (BRL → EUR becomes EUR → BRL).
struct CurrencyWidget: View {
    @EnvironmentObject var markets: MarketsModel
    @EnvironmentObject var model: AppModel
    let widget: WidgetConfig

    var body: some View {
        let accent = Theme.accent(for: .currency)
        let pair = widget.pair ?? CurrencyPair()
        let quote = markets.quote(pair.ticker)
        let stale = quote == nil || markets.isStale(pair.ticker)
        Tile(title: widget.title ?? "Currency", symbol: WidgetKind.currency.symbol, accent: accent,
             refresh: TileRefresh(updated: markets.updated(widget), spinning: markets.isRefreshing(widget)) { markets.refresh(widget) }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(pair.from) → \(pair.to)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                if let quote {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        BigValue(text: MarketFormat.price(quote.price, digits: 4), unit: pair.to)
                        Text(quote.changePercent.map(MarketFormat.change) ?? "")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(MarketFormat.color(quote.changePercent))
                    }
                    .opacity(stale ? 0.5 : 1)
                } else {
                    Text(markets.failed.contains(pair.ticker) ? "Unavailable" : "…").foregroundStyle(Theme.secondaryText)
                }
                if let alert = pair.alert {
                    Label(MarketFormat.alertText(alert), systemImage: alert.triggered ? "bell.badge.fill" : "bell.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(alert.triggered ? Color(hex: "#FF9F0A") : Theme.secondaryText)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.updateWidget(widget.id) { $0.pair = $0.pair?.flipped } }
        .ringing(pair.alert?.isPulsing == true, color: accent) { markets.acknowledge(widget.id) }
    }
}
