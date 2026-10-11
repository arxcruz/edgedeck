import SwiftUI

extension City {
    static var defaults: [City] {
        let others = ["America/Sao_Paulo", "America/New_York", "Asia/Tokyo"].filter { $0 != TimeZone.current.identifier }
        return [.local] + others.map { City(timeZone: $0) }
    }

    /// The Local city follows the Mac's time zone; every other city is fixed.
    var isLocal: Bool { timeZone == Self.localIdentifier }
    var resolvedTimeZone: TimeZone { isLocal ? .current : TimeZone(identifier: timeZone) ?? .current }
    var name: String { label ?? ClockMath.city(resolvedTimeZone.identifier) }
}

enum ClockMath {
    /// "America/Argentina/Buenos_Aires" → "Buenos Aires".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    private static var formatters: [String: DateFormatter] = [:]

    /// Time in the zone, following the system's 12/24-hour preference.
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = formatters[zone.identifier] ?? {
            let f = DateFormatter()
            f.locale = .current
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate("jmm")
            formatters[zone.identifier] = f
            return f
        }()
        return formatter.string(from: date)
    }

    static func hour(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date)
    }

    /// Difference in calendar days between the zone and here (-1, 0, +1).
    static func dayOffset(_ date: Date, in zone: TimeZone) -> Int {
        func dayNumber(_ tz: TimeZone) -> Int {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return Int((utc.date(from: c)?.timeIntervalSince1970 ?? 0) / 86_400)
        }
        return dayNumber(zone) - dayNumber(.current)
    }

    /// "+5h", "−3h", "+5:30", or "" for the local offset.
    static func offset(_ date: Date, in zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard seconds != 0 else { return "" }
        let sign = seconds > 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        return minutes % 60 == 0 ? "\(sign)\(minutes / 60)h" : String(format: "%@%d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// "Saturday, 11 October" in the zone.
    static func longDate(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.timeZone = zone
        return date.formatted(style)
    }

    static func relativeDescription(_ date: Date, in zone: TimeZone) -> String {
        let day: String
        switch dayOffset(date, in: zone) {
        case ..<0: day = "Yesterday"
        case 1...: day = "Tomorrow"
        default: day = "Today"
        }
        let offset = offset(date, in: zone)
        return offset.isEmpty ? day : "\(day) · \(offset)"
    }
}

// MARK: Widget

struct WorldClockWidget: View {
    @EnvironmentObject var model: AppModel
    let widget: WidgetConfig

    private let spacing: CGFloat = 10

    var body: some View {
        let cities = widget.cities ?? []
        Tile(title: widget.title ?? (cities.count == 1 ? cities[0].name : "World Clock"), symbol: WidgetKind.worldClock.symbol, accent: Theme.accent(for: .worldClock)) {
            if cities.isEmpty {
                Button { model.cityEditorWidgetID = widget.id } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle").font(.system(size: 34))
                        Text("Add cities").font(.system(size: 16, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            } else if cities.count == 1 {
                TimelineView(.everyMinute) { context in
                    SingleClock(city: cities[0], date: context.date)
                }
            } else {
                TimelineView(.everyMinute) { context in
                    GeometryReader { geo in
                        let grid = Self.grid(count: cities.count, in: geo.size, spacing: spacing)
                        Pager(items: cities, perPage: grid.columns * grid.rows) { page in
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: grid.columns), spacing: spacing) {
                                ForEach(page) { CityCard(city: $0, date: context.date, height: grid.cellHeight) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Picks the column count giving the largest ~1.6:1 cards with everything on one
    /// page; past a minimum card size it pages instead.
    static func grid(count: Int, in size: CGSize, spacing: CGFloat) -> (columns: Int, rows: Int, cellHeight: CGFloat) {
        let aspect: CGFloat = 1.6
        var best = (columns: 1, rows: max(count, 1), cellHeight: CGFloat(0), score: CGFloat(0))
        for columns in 1...max(count, 1) {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let height = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let score = min(width / aspect, height)
            if score > best.score { best = (columns, rows, min(height, width / 1.1), score) }
        }
        if best.score >= 64 { return (best.columns, best.rows, best.cellHeight) }
        // Too many for one page: fixed-size cards, paged (leaving room for the pager controls).
        let cardHeight: CGFloat = 80
        let columns = max(1, Int((size.width + spacing) / (cardHeight * aspect + spacing)))
        let rows = max(1, Int((size.height - 44 + spacing) / (cardHeight + spacing)))
        return (columns, rows, cardHeight)
    }
}

private struct CityCard: View {
    let city: City
    let date: Date
    let height: CGFloat

    var body: some View {
        let tz = city.resolvedTimeZone
        let hour = ClockMath.hour(date, in: tz)
        let isDay = (6..<18).contains(hour)
        let scale = min(max(height / 120, 0.6), 2.2)

        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(spacing: 6) {
                Text(city.name)
                    .font(.system(size: 15 * scale, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if city.isLocal {
                    Text("HERE")
                        .font(.system(size: 9 * scale, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent(for: .worldClock).opacity(0.25), in: Capsule())
                        .foregroundStyle(Theme.accent(for: .worldClock))
                }
                Spacer(minLength: 0)
                Image(systemName: isDay ? "sun.max.fill" : "moon.stars.fill")
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(isDay ? Color(hex: "#FFD60A") : Color(hex: "#9EB8FF"))
            }
            Text(ClockMath.time(date, in: tz))
                .font(.system(size: 40 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(ClockMath.relativeDescription(date, in: tz))
                .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(
            LinearGradient(colors: isDay ? [Color(hex: "#2A3F5F"), Color(hex: "#1C2433")] : [Color(hex: "#161A2E"), Color(hex: "#0E1018")],
                           startPoint: .topTrailing, endPoint: .bottomLeading),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if city.isLocal {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent(for: .worldClock).opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

/// One city: the time large with the full date, like a desk clock.
private struct SingleClock: View {
    let city: City
    let date: Date

    var body: some View {
        let tz = city.resolvedTimeZone
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(ClockMath.time(date, in: tz))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(ClockMath.longDate(date, in: tz))
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !city.isLocal {
                Text(ClockMath.relativeDescription(date, in: tz))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: City editor

enum CityRegion: String, CaseIterable, Identifiable {
    case americas = "Americas", europe = "Europe", africa = "Africa", asia = "Asia", oceania = "Oceania", other = "Other"

    var id: String { rawValue }

    func contains(_ identifier: String) -> Bool {
        let area = identifier.split(separator: "/").first.map(String.init) ?? identifier
        switch self {
        case .americas: return area == "America"
        case .europe: return area == "Europe"
        case .africa: return area == "Africa"
        case .asia: return area == "Asia"
        case .oceania: return area == "Australia" || area == "Pacific"
        case .other: return ["Atlantic", "Indian", "Antarctica", "Arctic", "UTC", "GMT"].contains(area)
        }
    }

    /// One entry per city, sorted by name.
    var identifiers: [String] {
        (TimeZone.knownTimeZoneIdentifiers + ["UTC"])
            .filter(contains)
            .reduce(into: [String: String]()) { $0[ClockMath.city($1)] = $0[ClockMath.city($1)] ?? $1 }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map(\.value)
    }
}

final class CityEditorState: ObservableObject {
    @Published var region: CityRegion = .europe
    @Published var page = 0
    var gridFrame: CGRect = .zero
}

struct CityEditor: View {
    @EnvironmentObject var model: AppModel
    let widgetID: UUID
    @StateObject private var state = CityEditorState()

    private let cellSize = CGSize(width: 200, height: 64)
    private let spacing: CGFloat = 8

    var body: some View {
        let cities = model.widget(widgetID)?.cities ?? []
        let chosen = Set(cities.map(\.timeZone))
        let choices = state.region.identifiers

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "globe").foregroundStyle(Theme.accent(for: .worldClock))
                Text("World Clock cities").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("\(cities.count) selected").foregroundStyle(Theme.secondaryText)
                Spacer()
                Button { model.cityEditorWidgetID = nil } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 110, height: 44)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            selectedRow(cities)

            HStack(spacing: 8) {
                let hasLocal = cities.contains(where: \.isLocal)
                Button { toggle(City.localIdentifier, cities: cities) } label: {
                    Label("Local · \(ClockMath.city(TimeZone.current.identifier))", systemImage: hasLocal ? "checkmark.circle.fill" : "location.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(hasLocal ? Color.black : Theme.accent(for: .worldClock))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(hasLocal ? Theme.accent(for: .worldClock) : Theme.tileRaised, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                Divider().frame(height: 28).overlay(Color.white.opacity(0.15))
                ForEach(CityRegion.allCases) { region in
                    let selected = region == state.region
                    Button {
                        state.region = region
                        state.page = 0
                    } label: {
                        Text(region.rawValue)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(selected ? Color.white : Theme.tileRaised, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            GeometryReader { geo in
                let columns = max(1, Int((geo.size.width - 60 + spacing) / (cellSize.width + spacing)))
                let rows = max(1, Int((geo.size.height + spacing) / (cellSize.height + spacing)))
                let perPage = columns * rows
                let pages = max(1, Int(ceil(Double(choices.count) / Double(perPage))))
                let page = min(state.page, pages - 1)
                let slice = Array(choices.dropFirst(page * perPage).prefix(perPage))

                HStack(alignment: .top, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize.width), spacing: spacing), count: columns),
                              alignment: .leading, spacing: spacing) {
                        ForEach(slice, id: \.self) { identifier in
                            CityButton(identifier: identifier, selected: chosen.contains(identifier), size: cellSize) {
                                toggle(identifier, cities: cities)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                        if value.translation.height < -40 { state.page = min(page + 1, pages - 1) }
                        if value.translation.height > 40 { state.page = max(page - 1, 0) }
                    })
                    .onVerticalSwipe(frame: { state.gridFrame = $0 }, contains: { state.gridFrame.contains($0) }) { forward in
                        state.page = forward ? min(page + 1, pages - 1) : max(page - 1, 0)
                    }

                    VStack(spacing: 8) {
                        TouchButton(symbol: "chevron.up", size: 44, enabled: page > 0) { state.page = page - 1 }
                        Text("\(page + 1)/\(pages)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondaryText)
                        TouchButton(symbol: "chevron.down", size: 44, enabled: page < pages - 1) { state.page = page + 1 }
                        letterIndex(choices: choices, perPage: perPage)
                    }
                    .frame(width: 48)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    /// Chosen cities in display order, each with move-earlier and remove buttons.
    private func selectedRow(_ cities: [City]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(cities.enumerated()), id: \.element.id) { index, city in
                HStack(spacing: 6) {
                    TouchButton(symbol: "chevron.left", size: 32, enabled: index > 0) { move(city.id, by: -1) }
                    Text(city.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    Spacer(minLength: 0)
                    TouchButton(symbol: "xmark", tint: Color(hex: "#FF453A"), size: 32) { remove(city.id) }
                }
                .padding(.horizontal, 6)
                .frame(height: 44)
                .background(Theme.accent(for: .worldClock).opacity(0.15), in: Capsule())
            }
        }
    }

    /// A–Z strip: jumps to the page holding the first city with that letter.
    private func letterIndex(choices: [String], perPage: Int) -> some View {
        let letters = Array(Set(choices.compactMap { ClockMath.city($0).first.map { String($0).uppercased() } })).sorted()
        return VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    if let index = choices.firstIndex(where: { ClockMath.city($0).uppercased().hasPrefix(letter) }) {
                        state.page = index / max(perPage, 1)
                    }
                } label: {
                    Text(letter)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent(for: .worldClock))
                        .frame(width: 44, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func toggle(_ identifier: String, cities: [City]) {
        model.updateWidget(widgetID) { widget in
            var list = widget.cities ?? []
            if let index = list.firstIndex(where: { $0.timeZone == identifier }) {
                list.remove(at: index)
            } else {
                list.append(City(timeZone: identifier))
            }
            widget.cities = list
        }
    }

    private func remove(_ id: UUID) {
        model.updateWidget(widgetID) { $0.cities?.removeAll { $0.id == id } }
    }

    private func move(_ id: UUID, by offset: Int) {
        model.updateWidget(widgetID) { widget in
            guard var list = widget.cities, let index = list.firstIndex(where: { $0.id == id }),
                  list.indices.contains(index + offset) else { return }
            list.swapAt(index, index + offset)
            widget.cities = list
        }
    }
}

private struct CityButton: View {
    let identifier: String
    let selected: Bool
    let size: CGSize
    let action: () -> Void

    var body: some View {
        let tz = TimeZone(identifier: identifier) ?? .current
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClockMath.city(identifier))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(ClockMath.time(Date(), in: tz))  \(ClockMath.offset(Date(), in: tz))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20))
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(width: size.width, height: size.height)
            .background(selected ? Theme.accent(for: .worldClock) : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
