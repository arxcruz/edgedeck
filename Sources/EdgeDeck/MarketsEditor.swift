import EdgeMarkets
import SwiftUI

/// The Editor of a Stocks Widget (its Watchlist, with search) or a Currency Widget (its Currency
/// pair), and the Alerts of either.
struct MarketsEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var markets: MarketsModel
    let widgetID: UUID
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    /// The Watchlist row whose Alert form is open.
    @State private var alertTicker: String?

    var body: some View {
        let widget = model.widget(widgetID)
        let kind = widget?.kind ?? .stocks
        let accent = Theme.accent(for: kind)

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol).foregroundStyle(accent)
                Text(kind.displayName).font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button { model.marketsEditorWidgetID = nil } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 110, height: 44)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            if let widget {
                if kind == .stocks {
                    HStack(alignment: .top, spacing: 24) {
                        watchlist(widget.watchlist ?? [], accent: accent)
                        search(widget.watchlist ?? [], accent: accent)
                    }
                } else {
                    currency(widget.pair ?? CurrencyPair(), accent: accent)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    // MARK: Stocks

    private func watchlist(_ list: [WatchedSymbol], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Watchlist", detail: list.isEmpty ? "Search for a Symbol to add it" : nil)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 8) {
                            row(item, index: index, count: list.count, accent: accent)
                            if alertTicker == item.ticker {
                                AlertForm(alert: item.alert, price: markets.quote(item.ticker)?.price, accent: accent) { alert in
                                    model.updateWidget(widgetID) { widget in
                                        if let at = widget.watchlist?.firstIndex(where: { $0.ticker == item.ticker }) { widget.watchlist?[at].alert = alert }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ item: WatchedSymbol, index: Int, count: Int, accent: Color) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.ticker).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(item.name).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if let alert = item.alert {
                Text(MarketFormat.alertText(alert) + (alert.triggered ? " · triggered" : ""))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(alert.triggered ? Color(hex: "#FF9F0A") : Theme.secondaryText)
            }
            iconButton(item.alert == nil ? "bell" : "bell.fill", tint: alertTicker == item.ticker ? accent : .white) {
                alertTicker = alertTicker == item.ticker ? nil : item.ticker
            }
            iconButton("chevron.up", enabled: index > 0) { move(index, by: -1) }
            iconButton("chevron.down", enabled: index < count - 1) { move(index, by: 1) }
            iconButton("trash", tint: Color(hex: "#FF453A")) {
                if alertTicker == item.ticker { alertTicker = nil }
                model.updateWidget(widgetID) { $0.watchlist?.removeAll { $0.ticker == item.ticker } }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func move(_ index: Int, by offset: Int) {
        model.updateWidget(widgetID) { widget in
            guard var list = widget.watchlist, list.indices.contains(index), list.indices.contains(index + offset) else { return }
            list.swapAt(index, index + offset)
            widget.watchlist = list
        }
    }

    private func search(_ list: [WatchedSymbol], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Add a Symbol", detail: "Type a name or ticker on the Mac keyboard")
            MarketTextField(placeholder: "Search, e.g. Apple or PETR4", text: $query, accent: accent)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(hits) { hit in
                        let added = list.contains { $0.ticker == hit.symbol }
                        Button {
                            guard !added else { return }
                            model.updateWidget(widgetID) { $0.watchlist = ($0.watchlist ?? []) + [WatchedSymbol(ticker: hit.symbol, name: hit.name)] }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.symbol).font(.system(size: 17, weight: .bold, design: .rounded))
                                    Text(hit.name + (hit.exchange.isEmpty ? "" : " · " + hit.exchange))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 6)
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 22))
                                    .foregroundStyle(added ? accent : .white)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 60)
                            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    if hits.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty && !searching {
                        Text("Nothing found").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { hits = []; return }
            searching = true
            // Wait for a pause in typing; a newer keystroke cancels this task.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let found = await markets.search(text)
            if !Task.isCancelled { hits = found }
            searching = false
        }
    }

    // MARK: Currency

    private func currency(_ pair: CurrencyPair, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            codes("From", current: pair.from, accent: accent) { code in
                setPair { $0.from = code; if $0.to == code { $0.to = pair.from } }
            }
            codes("To", current: pair.to, accent: accent) { code in
                setPair { $0.to = code; if $0.from == code { $0.from = pair.to } }
            }
            VStack(alignment: .leading, spacing: 8) {
                heading("Alert", detail: "On the rate \(pair.from) → \(pair.to)")
                AlertForm(alert: pair.alert, price: markets.quote(pair.ticker)?.price, accent: accent) { alert in
                    setPair { $0.alert = alert }
                }
            }
        }
    }

    /// A new pair starts with no Alert: its level was for another rate.
    private func setPair(_ change: @escaping (inout CurrencyPair) -> Void) {
        model.updateWidget(widgetID) { widget in
            var pair = widget.pair ?? CurrencyPair()
            let before = pair.ticker
            change(&pair)
            if pair.ticker != before, pair.alert?.level == widget.pair?.alert?.level { pair.alert = nil }
            widget.pair = pair
        }
    }

    private func codes(_ title: String, current: String, accent: Color, pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(title, detail: nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CurrencyPair.codes, id: \.self) { code in
                    let selected = code == current
                    Button { pick(code) } label: {
                        Text(code)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(selected ? accent : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    // MARK: Parts

    private func heading(_ title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            if let detail {
                Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func iconButton(_ symbol: String, tint: Color = .white, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        TouchButton(symbol: symbol, tint: tint, size: 44, enabled: enabled, action: action)
            .disabled(!enabled)
    }
}

/// Sets or removes the Alert of one Symbol or Currency pair. Arming is refused when the price is
/// already past the level, so an Alert only ever fires on a real crossing.
private struct AlertForm: View {
    @EnvironmentObject var model: AppModel
    let alert: PriceAlert?
    let price: Double?
    let accent: Color
    let set: (PriceAlert?) -> Void
    @State private var rises: Bool?
    @State private var level = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip("Rises to", selected: (rises ?? alert?.rises ?? true)) { rises = true }
                chip("Falls to", selected: !(rises ?? alert?.rises ?? true)) { rises = false }
                MarketTextField(placeholder: price.map { "Now " + MarketFormat.price($0, digits: 4) } ?? "Level", text: $level, accent: accent,
                                onSubmit: arm)
                    .frame(width: 200)
                Button(action: arm) {
                    Text(alert?.triggered == true ? "Re-arm" : "Arm")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                if alert != nil {
                    Button { set(nil); message = nil } label: {
                        Text("Remove")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Theme.tileRaised, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            if let message {
                Text(message).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: "#FF453A"))
            } else if let alert {
                Text(MarketFormat.alertText(alert) + (alert.triggered ? " · triggered, tap Re-arm to watch again" : " · armed"))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { if level.isEmpty, let alert { level = PriceAlert.format(alert.level) } }
    }

    private func arm() {
        let direction = rises ?? alert?.rises ?? true
        guard let value = MarketFormat.parse(level) else { message = "Enter a level, e.g. 200"; return }
        if let refusal = PriceAlert.refusal(level: value, rises: direction, price: price) { message = refusal; return }
        message = nil
        set(PriceAlert(level: value, rises: direction))
        model.endTyping()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(selected ? accent : Theme.tileRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// A text field in an Editor: tap to type on the Mac keyboard, Return to finish.
private struct MarketTextField: View {
    @EnvironmentObject var model: AppModel
    let placeholder: String
    @Binding var text: String
    let accent: Color
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? accent : .clear, lineWidth: 2))
            .focused($focused)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                model.beginTyping()
                DispatchQueue.main.async { focused = true }
            })
            .onSubmit {
                focused = false
                model.endTyping()
                onSubmit()
            }
    }
}

/// The Toast of Triggered Alerts: a Tap on a row stops its pulse and shows its Page.
struct AlertToastView: View {
    @EnvironmentObject var model: AppModel
    let widgets: [WidgetConfig]
    /// Floating over other apps' windows (Plain display): see AgentToastView.
    var floating = false

    var body: some View {
        let accent = Theme.accent(for: widgets.first?.kind ?? .stocks)
        HStack(spacing: 16) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 56, height: 56)
                .background(accent.opacity(0.18), in: Circle())
            VStack(spacing: 8) {
                ForEach(widgets) { widget in row(widget) }
            }
            TouchButton(symbol: "xmark", tint: Theme.secondaryText, size: 48) { model.markets.silenceAll() }
        }
        .padding(14)
        .frame(width: 760)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            if floating { shape.fill(Theme.tile) } else { shape.fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(accent.opacity(0.8), lineWidth: 1.5))
        .shadow(color: .black.opacity(floating ? 0.45 : 0.6), radius: floating ? 12 : 30, y: floating ? 4 : 0)
    }

    private func row(_ widget: WidgetConfig) -> some View {
        let accent = Theme.accent(for: widget.kind)
        return Button { model.acknowledgeAlert(widget.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: widget.kind.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(accent)
                Text(Self.summary(widget))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// "AAPL rises to 200.00", with the price now.
    private static func summary(_ widget: WidgetConfig) -> String {
        var parts: [String] = []
        for item in widget.watchlist ?? [] {
            if let alert = item.alert, alert.isPulsing { parts.append("\(item.ticker) \(MarketFormat.alertText(alert))") }
        }
        if let pair = widget.pair, let alert = pair.alert, alert.isPulsing {
            parts.append("\(pair.from) → \(pair.to) \(MarketFormat.alertText(alert))")
        }
        return parts.joined(separator: " · ")
    }
}
