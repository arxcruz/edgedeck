import Foundation

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, notifications, launcher, runningApps, nowPlaying, worldClock, weather, calendar, music, ai, timer, pomodoro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .notifications: "Notifications"
        case .launcher: "Launcher"
        case .runningApps: "Running Apps"
        case .nowPlaying: "Now Playing"
        case .worldClock: "World Clock"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .music: "Music"
        case .ai: "AI Agents"
        case .timer: "Timer"
        case .pomodoro: "Pomodoro"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .notifications: "bell.badge"
        case .launcher: "square.grid.3x3"
        case .runningApps: "macwindow.on.rectangle"
        case .nowPlaying: "play.circle"
        case .worldClock: "globe"
        case .weather: "cloud.sun"
        case .calendar: "calendar"
        case .music: "music.note"
        case .ai: "sparkles"
        case .timer: "timer"
        case .pomodoro: "repeat.circle"
        }
    }

    /// Size in grid cells when added to a page (on the default 30×4 grid).
    var defaultSize: (w: Int, h: Int) {
        switch self {
        case .cpu, .gpu, .memory, .disk, .network: (3, 2)
        case .notifications: (7, 4)
        case .launcher: (6, 2)
        case .runningApps: (5, 4)
        case .nowPlaying: (8, 2)
        case .worldClock: (8, 2)
        case .weather: (6, 2)
        case .calendar: (7, 4)
        case .music: (14, 4)
        case .ai: (10, 4)
        case .timer, .pomodoro: (6, 2)
        }
    }
}

struct ActionConfig: Codable, Hashable {
    enum Kind: String, Codable {
        /// value: bundle id ("com.apple.Safari"), app name ("Safari") or path.
        case openApp
        /// value: any URL, including custom schemes (slack://, raycast://, ...).
        case openURL
        /// value: command run with `zsh -lc`.
        case shell
        /// value: name of a Shortcuts.app shortcut.
        case shortcut
        /// value: "cmd+shift+4", or a media key: playpause, next, previous, volumeup, volumedown, mute.
        case keys
        /// value: AppleScript source.
        case appleScript
        /// value: same as openApp; brings the app's front window to the Edge as the Guest app.
        case bringToEdge
        /// value: unused. Turns the Dashboard off: the Edge becomes a Plain display.
        case plainDisplay

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // "dockApp" is the pre-CONTEXT.md name of bringToEdge.
            guard let kind = Kind(rawValue: raw == "dockApp" ? "bringToEdge" : raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown action type \(raw)"))
            }
            self = kind
        }
    }

    var type: Kind
    var value: String
}

struct ButtonConfig: Codable, Hashable, Identifiable {
    var id: UUID
    var title: String
    /// SF Symbol name; when absent the icon of `app` (or of the openApp target) is used.
    var symbol: String?
    /// App whose icon is shown (bundle id, name or path).
    var app: String?
    /// Hex tint, e.g. "#4F8CFF".
    var color: String?
    var action: ActionConfig

    init(title: String, symbol: String? = nil, app: String? = nil, color: String? = nil, action: ActionConfig) {
        self.id = UUID()
        self.title = title
        self.symbol = symbol
        self.app = app
        self.color = color
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        action = try c.decode(ActionConfig.self, forKey: .action)
    }
}

/// Position and size of a widget on its page's grid, in cells. Origin is top-left.
struct GridFrame: Codable, Hashable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func intersects(_ other: GridFrame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// A named place with a time zone, shown by World Clock and forecast by Weather.
struct City: Codable, Hashable, Identifiable {
    /// `timeZone` of the Local city, which follows the Mac's current time zone.
    static let localIdentifier = "local"
    static var local: City { City(timeZone: localIdentifier) }

    var id: UUID
    /// IANA identifier, e.g. "America/Sao_Paulo", or `localIdentifier`. Empty only for a
    /// place migrated from an old Weather `location` until its first forecast fills it in.
    var timeZone: String
    /// Optional display name; defaults to the city in the identifier.
    var label: String?
    /// Where Weather forecasts for; looked up by name when absent.
    var latitude: Double?
    var longitude: Double?

    init(timeZone: String, label: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = UUID()
        self.timeZone = timeZone
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
    }

    /// An old Weather `location`: a name matching a time-zone city becomes that city,
    /// anything else a labelled place whose time zone is filled in by its first forecast.
    init(legacyName name: String, latitude: Double?, longitude: Double?) {
        func folded(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let match = TimeZone.knownTimeZoneIdentifiers.first { folded(ClockMath.city($0)) == folded(name) }
        let label = match.map(ClockMath.city) == name ? nil : name
        self.init(timeZone: match ?? "", label: label, latitude: latitude, longitude: longitude)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timeZone = try c.decode(String.self, forKey: .timeZone)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }
}

/// How a Weather widget's place was stored before it became a City.
private struct LegacyWeatherLocation: Decodable {
    var name: String
    var latitude: Double?
    var longitude: Double?
}

struct WidgetConfig: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: WidgetKind
    /// Where the widget sits on its page. Nil until placed (e.g. migrated configs).
    var frame: GridFrame?
    var title: String?
    /// Launcher only.
    var buttons: [ButtonConfig]?
    /// World Clock only.
    var cities: [City]?
    /// Weather only; nil means the Local city.
    var city: City?
    /// Calendar only: calendar names to show (all when absent).
    var calendars: [String]?
    /// Calendar only: how many days to show, starting today.
    var days: Int?
    /// Timer only: the durations offered as chips, in minutes.
    var presets: [Int]?
    /// Pomodoro only: how long each phase lasts.
    var pomodoro: PomodoroLengths?
    /// Timer and Pomodoro: the macOS system sound played when Ringing (e.g. "Glass").
    var sound: String?
    /// Pre-pages configs sized widgets by relative width in a single row.
    var legacyWidth: Double?

    init(kind: WidgetKind, frame: GridFrame? = nil, title: String? = nil, buttons: [ButtonConfig]? = nil) {
        self.id = UUID()
        self.kind = kind
        self.frame = frame
        self.title = title
        self.buttons = buttons ?? (kind == .launcher ? [] : nil)
        if kind == .worldClock { cities = City.defaults }
        if kind == .timer { presets = Self.defaultPresets }
        if kind == .pomodoro { pomodoro = PomodoroLengths() }
    }

    static let defaultPresets = [1, 5, 10, 25]

    /// `zones` is the old name of `cities`; `location` the old form of `city`.
    enum CodingKeys: String, CodingKey { case id, kind = "type", frame, title, buttons, cities, zones, city, location, calendars, days, presets, pomodoro, sound, width }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawKind = try c.decode(String.self, forKey: .kind)
        frame = try c.decodeIfPresent(GridFrame.self, forKey: .frame)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        buttons = try c.decodeIfPresent([ButtonConfig].self, forKey: .buttons)
        cities = try c.decodeIfPresent([City].self, forKey: .cities) ?? c.decodeIfPresent([City].self, forKey: .zones)
        if rawKind == "clock" {
            // The Clock kind was folded into World Clock: a single Local city looks the same.
            kind = .worldClock
            cities = cities ?? [.local]
        } else if let known = WidgetKind(rawValue: rawKind) {
            kind = known
        } else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown widget kind \(rawKind)")
        }
        city = try c.decodeIfPresent(City.self, forKey: .city)
            ?? c.decodeIfPresent(LegacyWeatherLocation.self, forKey: .location).map {
                City(legacyName: $0.name, latitude: $0.latitude, longitude: $0.longitude)
            }
        calendars = try c.decodeIfPresent([String].self, forKey: .calendars)
        days = try c.decodeIfPresent(Int.self, forKey: .days)
        presets = try c.decodeIfPresent([Int].self, forKey: .presets)
        pomodoro = try c.decodeIfPresent(PomodoroLengths.self, forKey: .pomodoro)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        legacyWidth = try c.decodeIfPresent(Double.self, forKey: .width)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(frame, forKey: .frame)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(buttons, forKey: .buttons)
        try c.encodeIfPresent(cities, forKey: .cities)
        try c.encodeIfPresent(city, forKey: .city)
        try c.encodeIfPresent(calendars, forKey: .calendars)
        try c.encodeIfPresent(days, forKey: .days)
        try c.encodeIfPresent(presets, forKey: .presets)
        try c.encodeIfPresent(pomodoro, forKey: .pomodoro)
        try c.encodeIfPresent(sound, forKey: .sound)
    }
}

/// A Pomodoro's phase lengths in minutes, and how many Rounds make a Cycle.
struct PomodoroLengths: Codable, Hashable {
    var work = 25
    /// The Break after every Work but the Cycle's last.
    var shortBreak = 5
    /// The Break that ends the Cycle.
    var longBreak = 15
    var rounds = 4

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroLengths()
        work = max(1, try c.decodeIfPresent(Int.self, forKey: .work) ?? d.work)
        shortBreak = max(1, try c.decodeIfPresent(Int.self, forKey: .shortBreak) ?? d.shortBreak)
        longBreak = max(1, try c.decodeIfPresent(Int.self, forKey: .longBreak) ?? d.longBreak)
        rounds = max(1, try c.decodeIfPresent(Int.self, forKey: .rounds) ?? d.rounds)
    }
}

struct PageConfig: Codable, Hashable, Identifiable {
    static let defaultColumns = 30
    static let defaultRows = 4

    var id: UUID
    var columns: Int
    var rows: Int
    var widgets: [WidgetConfig]

    init(columns: Int = PageConfig.defaultColumns, rows: Int = PageConfig.defaultRows, widgets: [WidgetConfig] = []) {
        self.id = UUID()
        self.columns = columns
        self.rows = rows
        self.widgets = widgets
        placeUnpositioned()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        columns = max(1, try c.decodeIfPresent(Int.self, forKey: .columns) ?? Self.defaultColumns)
        rows = max(1, try c.decodeIfPresent(Int.self, forKey: .rows) ?? Self.defaultRows)
        widgets = try c.decodeIfPresent([WidgetConfig].self, forKey: .widgets) ?? []
        placeUnpositioned()
    }

    /// True when `frame` is inside the grid and doesn't overlap any widget except `ignoring`.
    func fits(_ frame: GridFrame, ignoring id: UUID? = nil) -> Bool {
        guard frame.x >= 0, frame.y >= 0, frame.w >= 1, frame.h >= 1, frame.maxX <= columns, frame.maxY <= rows else { return false }
        return !widgets.contains { $0.id != id && ($0.frame?.intersects(frame) ?? false) }
    }

    /// First free spot for a w×h widget scanning columns left to right, shrinking
    /// the size if nothing that big is free.
    func freeFrame(w: Int, h: Int) -> GridFrame? {
        var size = (w: min(w, columns), h: min(h, rows))
        while true {
            for x in 0...(columns - size.w) {
                for y in 0...(rows - size.h) {
                    let candidate = GridFrame(x: x, y: y, w: size.w, h: size.h)
                    if fits(candidate) { return candidate }
                }
            }
            if size.w == 1 && size.h == 1 { return nil }
            if size.w >= size.h { size.w = max(1, size.w - 1) } else { size.h = max(1, size.h - 1) }
        }
    }

    /// Gives widgets without a frame one: legacy single-row layouts keep their
    /// order and proportions as full-height columns, anything else goes in the first free spot.
    mutating func placeUnpositioned() {
        let legacyTotal = widgets.filter { $0.frame == nil }.compactMap(\.legacyWidth).reduce(0, +)
        var cursor = 0
        for index in widgets.indices where widgets[index].frame == nil {
            if let width = widgets[index].legacyWidth, legacyTotal > 0 {
                let w = max(1, Int((width / legacyTotal * Double(columns)).rounded()))
                let frame = GridFrame(x: cursor, y: 0, w: min(w, columns - cursor), h: rows)
                if frame.w > 0, fits(frame) {
                    widgets[index].frame = frame
                    cursor += frame.w
                    continue
                }
            }
            let size = widgets[index].kind.defaultSize
            widgets[index].frame = freeFrame(w: size.w, h: size.h)
        }
        widgets.removeAll { $0.frame == nil }
        for index in widgets.indices { widgets[index].legacyWidth = nil }
    }
}

struct NotificationSettings: Codable, Hashable {
    /// Apps brought to the Edge as the Guest app when you tap their Notification.
    var bringToEdgeOnTap: [String] = ["Slack"]
    /// Apps whose notifications are never shown.
    var ignoreApps: [String] = []
    var maxItems: Int = 30
    /// Names used before CONTEXT.md, still accepted when reading.
    private enum LegacyKeys: String, CodingKey { case dockOnTap }
    var toastSeconds: Double = 8

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        bringToEdgeOnTap = try c.decodeIfPresent([String].self, forKey: .bringToEdgeOnTap)
            ?? legacy.decodeIfPresent([String].self, forKey: .dockOnTap) ?? d.bringToEdgeOnTap
        ignoreApps = try c.decodeIfPresent([String].self, forKey: .ignoreApps) ?? d.ignoreApps
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        toastSeconds = try c.decodeIfPresent(Double.self, forKey: .toastSeconds) ?? d.toastSeconds
    }
}

struct DisplaySettings: Codable, Hashable {
    /// Case-insensitive substring of the display name the dashboard lives on.
    var match: String = "XENEON"
    /// Width of the Rail shown during a Takeover.
    var railWidth: Double = 150
    /// Names used before CONTEXT.md, still accepted when reading.
    private enum LegacyKeys: String, CodingKey { case dockRailWidth }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        match = try c.decodeIfPresent(String.self, forKey: .match) ?? d.match
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        railWidth = try c.decodeIfPresent(Double.self, forKey: .railWidth)
            ?? legacy.decodeIfPresent(Double.self, forKey: .dockRailWidth) ?? d.railWidth
    }
}

struct AISettings: Codable, Hashable {
    /// Claude Code config folders (CLAUDE_CONFIG_DIR) beyond the ones found on their own
    /// (~/.claude, ~/.claude-*): added in the Editor, by hand, or learned from running Sessions.
    var claudeDirs: [String]?
    /// Profile folders not to show (e.g. "~/.claude-old").
    var hiddenClaudeDirs: [String] = []
    /// OpenCode's database. Nil: ~/.local/share/opencode/opencode.db.
    var opencodeDatabase: String?
    /// A Session that Needs you raises a Toast (or a Rail button during a Takeover).
    var toastOnNeedsYou = true
    /// Each Session row shows its cost so far (Claude: an API-price estimate).
    var showCost = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        claudeDirs = try c.decodeIfPresent([String].self, forKey: .claudeDirs)
        hiddenClaudeDirs = try c.decodeIfPresent([String].self, forKey: .hiddenClaudeDirs) ?? d.hiddenClaudeDirs
        opencodeDatabase = try c.decodeIfPresent(String.self, forKey: .opencodeDatabase)
        toastOnNeedsYou = try c.decodeIfPresent(Bool.self, forKey: .toastOnNeedsYou) ?? d.toastOnNeedsYou
        showCost = try c.decodeIfPresent(Bool.self, forKey: .showCost) ?? d.showCost
    }
}

struct AppConfig: Codable, Hashable {
    var display = DisplaySettings()
    var notifications = NotificationSettings()
    var ai = AISettings()
    var pages: [PageConfig] = []
    /// Set when the file was in the single-page format and got converted.
    private(set) var migrated = false

    init(display: DisplaySettings = DisplaySettings(), notifications: NotificationSettings = NotificationSettings(), pages: [PageConfig]) {
        self.display = display
        self.notifications = notifications
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey { case display, notifications, ai, pages, widgets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? DisplaySettings()
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        ai = try c.decodeIfPresent(AISettings.self, forKey: .ai) ?? AISettings()
        pages = try c.decodeIfPresent([PageConfig].self, forKey: .pages) ?? []
        if let legacy = try c.decodeIfPresent([WidgetConfig].self, forKey: .widgets) {
            pages.insert(PageConfig(widgets: legacy), at: 0)
            migrated = true
        }
        if pages.isEmpty { pages = [PageConfig()] }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(display, forKey: .display)
        try c.encode(notifications, forKey: .notifications)
        if ai != AISettings() { try c.encode(ai, forKey: .ai) }
        try c.encode(pages, forKey: .pages)
    }

    static func == (lhs: AppConfig, rhs: AppConfig) -> Bool {
        lhs.display == rhs.display && lhs.notifications == rhs.notifications && lhs.ai == rhs.ai && lhs.pages == rhs.pages
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(display)
        hasher.combine(notifications)
        hasher.combine(ai)
        hasher.combine(pages)
    }

    static var `default`: AppConfig {
        let apps = [
            ButtonConfig(title: "Vivaldi", action: .init(type: .openApp, value: "Vivaldi")),
            ButtonConfig(title: "iTerm", action: .init(type: .openApp, value: "com.googlecode.iterm2")),
            ButtonConfig(title: "Telegram", action: .init(type: .openApp, value: "Telegram")),
            ButtonConfig(title: "WhatsApp", action: .init(type: .openApp, value: "WhatsApp")),
            ButtonConfig(title: "Finder", action: .init(type: .openApp, value: "com.apple.finder")),
        ]
        let controls = [
            ButtonConfig(title: "Play/Pause", symbol: "playpause.fill", color: "#34C759", action: .init(type: .keys, value: "playpause")),
            ButtonConfig(title: "Next", symbol: "forward.fill", color: "#34C759", action: .init(type: .keys, value: "next")),
            ButtonConfig(title: "Mute", symbol: "speaker.slash.fill", color: "#FF9F0A", action: .init(type: .keys, value: "mute")),
            ButtonConfig(title: "Screenshot", symbol: "camera.viewfinder", color: "#5E9EFF", action: .init(type: .keys, value: "cmd+shift+4")),
            ButtonConfig(title: "Bring Slack", symbol: "rectangle.portrait.and.arrow.right", color: "#BF5AF2", action: .init(type: .bringToEdge, value: "com.tinyspeck.slackmacgap")),
            ButtonConfig(title: "Lock", symbol: "lock.fill", color: "#FF453A", action: .init(type: .keys, value: "ctrl+cmd+q")),
        ]
        func at(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> GridFrame { GridFrame(x: x, y: y, w: w, h: h) }
        var clock = WidgetConfig(kind: .worldClock, frame: at(0, 0, 3, 4))
        clock.cities = [.local]
        let main = PageConfig(widgets: [
            clock,
            WidgetConfig(kind: .cpu, frame: at(3, 0, 3, 2)),
            WidgetConfig(kind: .gpu, frame: at(3, 2, 3, 2)),
            WidgetConfig(kind: .memory, frame: at(6, 0, 3, 2)),
            WidgetConfig(kind: .network, frame: at(6, 2, 3, 2)),
            WidgetConfig(kind: .notifications, frame: at(9, 0, 7, 4)),
            WidgetConfig(kind: .runningApps, frame: at(16, 0, 5, 4), title: "Running"),
            WidgetConfig(kind: .launcher, frame: at(21, 0, 9, 2), title: "Launch", buttons: apps),
            WidgetConfig(kind: .launcher, frame: at(21, 2, 9, 2), title: "Controls", buttons: controls),
        ])
        let system = PageConfig(widgets: [
            WidgetConfig(kind: .cpu, frame: at(0, 0, 8, 4)),
            WidgetConfig(kind: .gpu, frame: at(8, 0, 6, 4)),
            WidgetConfig(kind: .memory, frame: at(14, 0, 6, 2)),
            WidgetConfig(kind: .disk, frame: at(14, 2, 6, 2)),
            WidgetConfig(kind: .network, frame: at(20, 0, 10, 4)),
        ])
        let media = PageConfig(widgets: [
            WidgetConfig(kind: .nowPlaying, frame: at(0, 0, 16, 4)),
            WidgetConfig(kind: .launcher, frame: at(16, 0, 14, 2), title: "Controls", buttons: controls),
        ])
        return AppConfig(pages: [main, system, media])
    }
}

/// Loads, saves and live-reloads ~/Library/Application Support/EdgeDeck/config.json.
final class ConfigStore: ObservableObject {
    /// ~/Library/Application Support/EdgeDeck. EDGEDECK_CONFIG_DIR=<dir> uses another folder for
    /// config.json and Timer state, so a test run never touches the real ones.
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["EDGEDECK_CONFIG_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeDeck", isDirectory: true)
    }

    @Published private(set) var config: AppConfig
    @Published private(set) var lastError: String?

    let url: URL
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        config = .default
        if FileManager.default.fileExists(atPath: url.path) {
            reload()
        } else {
            save(config)
        }
        watch()
    }

    func reload() {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            if decoded.migrated {
                // Rewrite single-page configs in the pages format, keeping a backup.
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("v1-backup.json"))
                save(decoded)
            } else if decoded != config {
                config = decoded
            }
            lastError = nil
        } catch {
            lastError = "config.json: \(error.localizedDescription)"
            NSLog("EdgeDeck: failed to load config: \(error)")
        }
    }

    func update(_ change: (inout AppConfig) -> Void) {
        var next = config
        change(&next)
        save(next)
    }

    private func save(_ next: AppConfig) {
        config = next
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(next).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save config: \(error.localizedDescription)"
        }
    }

    /// Editors usually replace the file atomically, so the watch is re-armed after deletes/renames.
    private func watch() {
        watcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.reload()
                if replaced { self.watch() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
