import AppKit
import SwiftUI

extension WeatherLocation {
    /// The Local city: the city of the Mac's current time zone ("Europe/Berlin" → Berlin).
    static var local: WeatherLocation { WeatherLocation(name: ClockMath.city(TimeZone.current.identifier)) }

    var key: String {
        if let latitude, let longitude { return String(format: "%.3f,%.3f", latitude, longitude) }
        return name.lowercased()
    }
}

struct Forecast {
    struct Hour: Identifiable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        let precipitationChance: Int
        var id: Date { time }
    }

    struct Day: Identifiable {
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let precipitationChance: Int
        var id: Date { date }
    }

    let fetched: Date
    let timeZone: TimeZone
    let temperature: Double
    let feelsLike: Double
    let humidity: Int
    let windSpeed: Double
    let code: Int
    let isDay: Bool
    let hours: [Hour]
    let days: [Day]
    let sunrise: Date?
    let sunset: Date?
}

/// Fetches forecasts from Open-Meteo (free, no API key) for every location a widget
/// asks for, refreshing them every 15 minutes.
final class WeatherModel: ObservableObject {
    @Published private(set) var forecasts: [String: Forecast] = [:]
    @Published private(set) var errors: [String: String] = [:]

    /// Fahrenheit and mph where the system uses US units, Celsius and km/h elsewhere.
    let usUnits = Locale.current.measurementSystem == .us

    private var locations: [String: WeatherLocation] = [:]
    private var coordinates: [String: (Double, Double)] = [:]
    private var inFlight = Set<String>()
    private let refreshInterval: TimeInterval = 15 * 60
    /// Short timeout so a hanging request fails and the minute timer retries it.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func start() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshStale() }
        // Refresh right away after the Mac wakes rather than showing hours-old data.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refreshStale(force: true) }
        }
    }

    /// Called by widgets when they appear; fetches if there's no recent forecast.
    func track(_ location: WeatherLocation) {
        locations[location.key] = location
        refresh(location, force: false)
    }

    private func refreshStale(force: Bool = false) {
        locations.values.forEach { refresh($0, force: force) }
    }

    private func refresh(_ location: WeatherLocation, force: Bool) {
        let key = location.key
        if !force, let forecast = forecasts[key], Date().timeIntervalSince(forecast.fetched) < refreshInterval { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            do {
                let forecast = try await fetch(location)
                await MainActor.run {
                    forecasts[key] = forecast
                    errors[key] = nil
                    inFlight.remove(key)
                }
            } catch {
                NSLog("EdgeDeck: weather for \(location.name) failed: \(error)")
                await MainActor.run {
                    errors[key] = error.localizedDescription
                    inFlight.remove(key)
                }
            }
        }
    }

    private func fetch(_ location: WeatherLocation) async throws -> Forecast {
        let (latitude, longitude) = try await resolve(location)
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "forecast_hours", value: "25"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: usUnits ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: usUnits ? "mph" : "kmh"),
        ]
        let (data, _) = try await session.data(from: components.url!)
        let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        func date(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }
        let h = r.hourly
        let hours = h.time.indices.map { i in
            Forecast.Hour(time: date(h.time[i]), temperature: h.temperature_2m[i] ?? 0, code: h.weather_code[i] ?? 0,
                          isDay: (h.is_day[i] ?? 1) == 1, precipitationChance: h.precipitation_probability[i] ?? 0)
        }
        let d = r.daily
        let days = d.time.indices.map { i in
            Forecast.Day(date: date(d.time[i]), code: d.weather_code[i] ?? 0, high: d.temperature_2m_max[i] ?? 0,
                         low: d.temperature_2m_min[i] ?? 0, precipitationChance: d.precipitation_probability_max[i] ?? 0)
        }
        let c = r.current
        return Forecast(fetched: Date(), timeZone: TimeZone(identifier: r.timezone) ?? .current,
                        temperature: c.temperature_2m, feelsLike: c.apparent_temperature, humidity: c.relative_humidity_2m,
                        windSpeed: c.wind_speed_10m, code: c.weather_code, isDay: c.is_day == 1,
                        hours: hours, days: days,
                        sunrise: d.sunrise.first.map(date), sunset: d.sunset.first.map(date))
    }

    /// Coordinates from the config, or looked up by name with Open-Meteo's geocoder.
    private func resolve(_ location: WeatherLocation) async throws -> (Double, Double) {
        if let latitude = location.latitude, let longitude = location.longitude { return (latitude, longitude) }
        let key = location.key
        if let cached = await MainActor.run(body: { coordinates[key] }) { return cached }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: location.name), .init(name: "count", value: "1")]
        let (data, _) = try await session.data(from: components.url!)
        guard let place = try JSONDecoder().decode(GeocodingResponse.self, from: data).results?.first else {
            throw WeatherError.unknownPlace(location.name)
        }
        await MainActor.run { coordinates[key] = (place.latitude, place.longitude) }
        return (place.latitude, place.longitude)
    }
}

enum WeatherError: LocalizedError {
    case unknownPlace(String)
    var errorDescription: String? {
        switch self {
        case .unknownPlace(let name): "Couldn't find “\(name)”"
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Int
        let weather_code: Int
        let is_day: Int
        let wind_speed_10m: Double
    }
    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
        let precipitation_probability: [Int?]
    }
    struct Daily: Decodable {
        let time: [Double]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let sunrise: [Double]
        let sunset: [Double]
        let precipitation_probability_max: [Int?]
    }
    let timezone: String
    let current: Current
    let hourly: Hourly
    let daily: Daily
}

private struct GeocodingResponse: Decodable {
    struct Place: Decodable {
        let latitude: Double
        let longitude: Double
    }
    let results: [Place]?
}

/// WMO weather interpretation codes, as used by Open-Meteo.
enum WeatherCode {
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm, hail"
        default: "—"
        }
    }

    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95: "cloud.bolt.fill"
        case 96, 99: "cloud.bolt.rain.fill"
        default: "questionmark"
        }
    }
}

// MARK: Widget

struct WeatherWidget: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var weather: WeatherModel
    let widget: WidgetConfig

    private var location: WeatherLocation { widget.location ?? .local }

    /// Only animate while the widget can actually be seen.
    private var visible: Bool {
        model.currentPage.widgets.contains { $0.id == widget.id } && model.guest.current == nil && !model.player.isOpen
    }

    var body: some View {
        let location = location
        let forecast = weather.forecasts[location.key]
        Tile(title: widget.title ?? location.name, symbol: WidgetKind.weather.symbol, accent: Theme.accent(for: .weather),
             background: forecast == nil ? Theme.tile : .clear) {
            if let forecast {
                GeometryReader { geo in
                    let showDaily = geo.size.height >= 300
                    let currentWidth = min(geo.size.width, 250)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 16) {
                            CurrentWeather(forecast: forecast)
                                .frame(width: currentWidth, alignment: .leading)
                            if geo.size.width - currentWidth >= 140 {
                                HourlyStrip(hours: Array(forecast.hours.filter { $0.time > Date().addingTimeInterval(-3600) }.dropFirst()),
                                            timeZone: forecast.timeZone, available: geo.size.width - currentWidth - 16)
                            }
                        }
                        .frame(height: showDaily ? 150 : nil)
                        if showDaily {
                            DailyList(days: forecast.days, timeZone: forecast.timeZone)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    if let error = weather.errors[location.key] {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                        Text(error).font(.system(size: 14, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            if let forecast {
                WeatherScene(code: Self.debugCode ?? forecast.code, isDay: Self.debugNight ? false : forecast.isDay, paused: !visible)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .onAppear { weather.track(location) }
        .onChange(of: location) { _, new in weather.track(new) }
    }
}

extension WeatherWidget {
    /// Debug aid: EDGEDECK_WEATHER_CODE=<WMO code> / EDGEDECK_WEATHER_NIGHT=1 force the scene.
    static let debugCode = ProcessInfo.processInfo.environment["EDGEDECK_WEATHER_CODE"].flatMap(Int.init)
    static let debugNight = ProcessInfo.processInfo.environment["EDGEDECK_WEATHER_NIGHT"] == "1"
}

private struct CurrentWeather: View {
    let forecast: Forecast

    var body: some View {
        let today = forecast.days.first
        Button { AppLocator.open("com.apple.weather") } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: WeatherCode.symbol(forecast.code, isDay: forecast.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 46))
                    Text(Self.degrees(forecast.temperature))
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(WeatherCode.describe(forecast.code))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Group {
                    if let today {
                        Text("H \(Self.degrees(today.high))  L \(Self.degrees(today.low))  ·  Feels \(Self.degrees(forecast.feelsLike))")
                    } else {
                        Text("Feels \(Self.degrees(forecast.feelsLike))")
                    }
                }
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

private struct HourlyStrip: View {
    let hours: [Forecast.Hour]
    let timeZone: TimeZone
    let available: CGFloat

    private let cellWidth: CGFloat = 62

    var body: some View {
        let count = max(1, min(hours.count, Int(available / cellWidth)))
        HStack(spacing: 0) {
            ForEach(hours.prefix(count)) { hour in
                VStack(spacing: 6) {
                    Text(Self.hourLabel(hour.time, timeZone))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.8))
                    Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 22))
                        .frame(height: 26)
                    Text(CurrentWeather.degrees(hour.temperature))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    // Rain chance, shown only when it's worth knowing.
                    Text(hour.precipitationChance >= 20 ? "\(hour.precipitationChance)%" : " ")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: "#64D2FF"))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private static var formatters: [String: DateFormatter] = [:]

    static func hourLabel(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = formatters[zone.identifier] ?? {
            let f = DateFormatter()
            f.locale = .current
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate("j")
            formatters[zone.identifier] = f
            return f
        }()
        return formatter.string(from: date)
    }
}

private struct DailyList: View {
    let days: [Forecast.Day]
    let timeZone: TimeZone

    var body: some View {
        GeometryReader { geo in
            let rowHeight: CGFloat = 44
            let count = max(1, min(days.count, Int((geo.size.height + 4) / (rowHeight + 4))))
            let shown = Array(days.prefix(count))
            let low = shown.map(\.low).min() ?? 0
            let high = shown.map(\.high).max() ?? 1
            VStack(spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: 12) {
                        Text(index == 0 ? "Today" : Self.weekday(day.date, timeZone))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(width: 60, alignment: .leading)
                        Image(systemName: WeatherCode.symbol(day.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 20))
                            .frame(width: 30)
                        Text(day.precipitationChance >= 20 ? "\(day.precipitationChance)%" : "")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: "#64D2FF"))
                            .frame(width: 36, alignment: .leading)
                        Text(CurrentWeather.degrees(day.low))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .frame(width: 40, alignment: .trailing)
                        TemperatureBar(low: day.low, high: day.high, rangeLow: low, rangeHigh: high)
                            .frame(height: 6)
                        Text(CurrentWeather.degrees(day.high))
                            .frame(width: 40, alignment: .leading)
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(height: rowHeight)
                    .padding(.horizontal, 12)
                    .background(Color.black.opacity(index == 0 ? 0.3 : 0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    static func weekday(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }
}

/// Apple Weather–style bar placing a day's low…high within the week's range.
private struct TemperatureBar: View {
    let low: Double
    let high: Double
    let rangeLow: Double
    let rangeHigh: Double

    var body: some View {
        GeometryReader { geo in
            let span = max(rangeHigh - rangeLow, 1)
            let start = (low - rangeLow) / span * geo.size.width
            let width = max((high - low) / span * geo.size.width, 6)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: "#64D2FF"), Color(hex: "#FFD60A"), Color(hex: "#FF9F0A")], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .offset(x: start)
            }
        }
    }
}
