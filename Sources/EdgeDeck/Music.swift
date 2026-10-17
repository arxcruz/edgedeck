import AppKit
import SwiftUI

/// Apple Music (Music.app) through its AppleScript dictionary: playlists, albums
/// with artwork, love / shuffle / repeat / volume and AirPlay outputs. Complements
/// the Now Playing widget, which covers the current track for any player.
///
/// Scripts run on one background queue. Music is never launched implicitly:
/// nothing is sent while it isn't running.
final class MusicModel: ObservableObject {
    struct Playlist: Identifiable, Hashable {
        let id: String  // persistent ID
        let name: String
        let trackCount: Int
    }

    struct Album: Identifiable, Hashable {
        let id: String  // "album\u{1F}artist"
        let name: String
        let artist: String
        /// Persistent IDs in disc/track order.
        let trackIDs: [String]
    }

    struct AirPlayDevice: Identifiable, Hashable {
        let name: String
        let kind: String
        let selected: Bool
        var id: String { name }

        var symbol: String {
            switch kind.lowercased() {
            case "computer": "laptopcomputer"
            case "apple tv": "appletv.fill"
            case "homepod": "homepodmini.fill"
            case "bluetooth device": "headphones"
            case "tv": "tv"
            case "speaker", "airport express": "hifispeaker.fill"
            default: "airplayaudio"
            }
        }
    }

    enum Repeat: String { case off, one, all }

    enum Status: Equatable { case notRunning, denied, ready }

    @Published private(set) var status: Status = .notRunning
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var devices: [AirPlayDevice] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode = Repeat.off
    @Published private(set) var volume = 50
    @Published private(set) var favorited = false
    @Published private(set) var hasTrack = false
    @Published private(set) var currentPlaylist: String?
    @Published private(set) var artwork: [String: NSImage] = [:]
    /// Something to tell the user, e.g. that Music couldn't play an album.
    @Published private(set) var message: String?

    /// Helper playlist that albums are copied into to play them in order.
    static let queuePlaylist = "EdgeDeck"
    static let bundleID = "com.apple.Music"

    private let queue = DispatchQueue(label: "edgedeck.music")
    private var compiled: [String: NSAppleScript] = [:]
    private var visibleWidgets = Set<UUID>()
    /// Each list is loaded once it has actually arrived; until then every poll tries again.
    private var playlistsLoaded = false
    private var albumsLoaded = false
    private var loading = Set<String>()
    private var artworkRequested = Set<String>()
    private var lastDevicesRefresh = Date.distantPast
    /// No scripts before this: Music may be quitting (see `start`).
    private var quietUntil = Date.distantPast

    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains { !$0.isTerminated }
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
                self?.playlistsLoaded = false
                self?.albumsLoaded = false
                self?.poll()
            }
        }
        // Library edits (new playlists, albums) show up when Music says they happened.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            // Quitting, Music sends a bare "Stopped" (no track fields) while it's still shutting
            // down. A script sent then reaches it as it exits, and AppleScript relaunches it to
            // retry, so stay quiet until it's gone.
            if (note.userInfo?["Player State"] as? String) == "Stopped", (note.userInfo?.count ?? 0) <= 1 {
                self?.quietUntil = Date().addingTimeInterval(3)
                return
            }
            self?.poll()
        }
    }

    /// Widgets report whether they're on screen; Music is only polled for visible ones.
    func setVisible(_ id: UUID, _ visible: Bool) {
        let wasEmpty = visibleWidgets.isEmpty
        if visible { visibleWidgets.insert(id) } else { visibleWidgets.remove(id) }
        if wasEmpty && visible { poll() }
    }

    // MARK: Commands

    func openMusic() { AppLocator.open(Self.bundleID) }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func play(_ playlist: Playlist) {
        command("play (first playlist whose persistent ID is \(Self.quote(playlist.id)))")
        checkStarted("“\(playlist.name)”")
    }

    func play(_ album: Album) {
        let ids = album.trackIDs.map(Self.quote).joined(separator: ", ")
        command("""
        set q to missing value
        try
            set q to user playlist \(Self.quote(Self.queuePlaylist))
        on error
            set q to make new user playlist with properties {name:\(Self.quote(Self.queuePlaylist))}
        end try
        delete every track of q
        repeat with pid in {\(ids)}
            duplicate (first track of library playlist 1 whose persistent ID is pid) to q
        end repeat
        play q
        """)
        checkStarted("“\(album.name)”")
    }

    /// Music silently does nothing for tracks it can't play (e.g. an old purchase this Mac
    /// isn't authorized for), so say so if nothing is playing after a while. Streamed
    /// Apple Music tracks take several seconds to start, so keep checking before giving up.
    private func checkStarted(_ what: String, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 2 : 2.5)) { [weak self] in
            self?.run("return player state as text") { result in
                guard result?.stringValue != "playing" else { return }
                if attempt < 4 {
                    self?.checkStarted(what, attempt: attempt + 1)
                } else {
                    self?.message = "Music couldn't play \(what) — its tracks may be unavailable on this Mac"
                }
            }
        }
    }

    func shuffleAll() {
        command("set shuffle enabled to true\nplay library playlist 1")
    }

    func toggleFavorite() {
        favorited.toggle()
        command("set favorited of current track to \(favorited)")
    }

    func toggleShuffle() {
        shuffle.toggle()
        command("set shuffle enabled to \(shuffle)")
    }

    /// off → all → one → off, like Music's own button.
    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        command("set song repeat to \(repeatMode.rawValue)")
    }

    func setVolume(_ value: Int) {
        volume = min(max(value, 0), 100)
        command("set sound volume to \(volume)")
    }

    /// Toggles an output, keeping at least one selected.
    func toggle(_ device: AirPlayDevice) {
        let selectedCount = devices.filter(\.selected).count
        if device.selected && selectedCount <= 1 { return }
        command("set selected of AirPlay device \(Self.quote(device.name)) to \(!device.selected)")
        devices = devices.map { $0.name == device.name ? AirPlayDevice(name: $0.name, kind: $0.kind, selected: !$0.selected) : $0 }
    }

    /// Makes `device` the only output.
    func playOnly(_ device: AirPlayDevice) {
        command("set current AirPlay devices to {AirPlay device \(Self.quote(device.name))}")
        devices = devices.map { AirPlayDevice(name: $0.name, kind: $0.kind, selected: $0.name == device.name) }
    }

    func refreshDevices() {
        guard isRunning else { return }
        run(Self.devicesScript) { [weak self] result in
            guard let self, let result else { return }
            devices = Self.items(result).compactMap { item in
                let fields = Self.items(item)
                guard fields.count >= 3 else { return nil }
                return AirPlayDevice(name: fields[0].stringValue ?? "?", kind: fields[1].stringValue ?? "", selected: fields[2].booleanValue)
            }
            lastDevicesRefresh = Date()
        }
    }

    // MARK: Polling

    private func poll() {
        guard isRunning else {
            if status != .notRunning { status = .notRunning }
            return
        }
        guard !visibleWidgets.isEmpty else { return }
        run(Self.stateScript) { [weak self] result in
            guard let self, let result else { return }
            let f = Self.items(result)
            guard f.count >= 7 else { return }
            isPlaying = f[0].stringValue == "playing"
            shuffle = f[1].booleanValue
            repeatMode = Repeat(rawValue: f[2].stringValue ?? "off") ?? .off
            volume = Int(f[3].int32Value)
            favorited = f[4].booleanValue
            hasTrack = f[5].booleanValue
            currentPlaylist = f[6].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if !playlistsLoaded || !albumsLoaded { loadLibrary() }
            if Date().timeIntervalSince(lastDevicesRefresh) > 15 { refreshDevices() }
        }
    }

    private func loadLibrary() {
        if !playlistsLoaded, loading.insert("playlists").inserted {
        run(Self.playlistsScript) { [weak self] result in
            guard let self else { return }
            loading.remove("playlists")
            guard let result else { NSLog("EdgeDeck: Music playlists came back empty, will retry"); return }
            playlistsLoaded = true
            playlists = Self.items(result).compactMap { item in
                let f = Self.items(item)
                guard f.count >= 4, let name = f[1].stringValue, name != Self.queuePlaylist else { return nil }
                // Library and the built-in Music / Music Videos lists duplicate the albums view.
                let special = f[3].stringValue ?? "none"
                guard special == "none" || special == "Purchased Music" else { return nil }
                return Playlist(id: f[0].stringValue ?? "", name: name, trackCount: Int(f[2].int32Value))
            }
            .filter { $0.trackCount > 0 && $0.name != "Music Videos" }
        }
        }
        if !albumsLoaded, loading.insert("albums").inserted {
        run(Self.tracksScript) { [weak self] result in
            guard let self else { return }
            loading.remove("albums")
            guard let result else { NSLog("EdgeDeck: Music albums came back empty, will retry"); return }
            let columns = Self.items(result).map { Self.items($0) }
            guard columns.count == 6 else { NSLog("EdgeDeck: Music albums had \(columns.count) columns, will retry"); return }
            albumsLoaded = true
            struct Row { let id: String; let album: String; let artist: String; let disc: Int; let track: Int }
            var rows: [Row] = []
            for i in 0..<columns[0].count {
                let album = columns[1][i].stringValue ?? ""
                guard !album.isEmpty else { continue }
                let albumArtist = columns[2][i].stringValue ?? ""
                rows.append(Row(id: columns[0][i].stringValue ?? "", album: album,
                                artist: albumArtist.isEmpty ? (columns[3][i].stringValue ?? "") : albumArtist,
                                disc: Int(columns[4][i].int32Value), track: Int(columns[5][i].int32Value)))
            }
            let grouped = Dictionary(grouping: rows) { "\($0.album)\u{1F}\($0.artist)" }
            albums = grouped.map { key, rows in
                let ordered = rows.sorted { ($0.disc, $0.track) < ($1.disc, $1.track) }
                return Album(id: key, name: rows[0].album, artist: rows[0].artist, trackIDs: ordered.map(\.id))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        }
    }

    // MARK: Artwork

    /// Loads artwork for an album or playlist the first time a tile asks for it.
    func requestArtwork(album: Album) {
        guard let first = album.trackIDs.first, artworkRequested.insert(album.id).inserted else { return }
        run("return raw data of artwork 1 of (first track of library playlist 1 whose persistent ID is \(Self.quote(first)))") { [weak self] result in
            if let image = result.flatMap(Self.image) { self?.artwork[album.id] = image }
            else { self?.artworkRequested.remove(album.id) }  // asked again when the tile reappears
        }
    }

    /// A playlist gets its own artwork if it has one, else a 2×2 mosaic of its first albums.
    func requestArtwork(playlist: Playlist) {
        guard artworkRequested.insert(playlist.id).inserted else { return }
        run("""
        set p to first playlist whose persistent ID is \(Self.quote(playlist.id))
        if (count of artworks of p) > 0 then return {raw data of artwork 1 of p}
        set out to {}
        set seen to {}
        set n to count of tracks of p
        if n > 40 then set n to 40
        repeat with t in (tracks 1 thru n of p)
            set a to album of t
            if a is not in seen and (count of artworks of t) > 0 then
                set end of seen to a
                set end of out to raw data of artwork 1 of t
                if (count of out) is 4 then exit repeat
            end if
        end repeat
        return out
        """) { [weak self] result in
            let images = result.map { Self.items($0).compactMap(Self.image) } ?? []
            if let image = Self.mosaic(images) { self?.artwork[playlist.id] = image }
            else {
                NSLog("EdgeDeck: no artwork for playlist “\(playlist.name)”")
                self?.artworkRequested.remove(playlist.id)
            }
        }
    }

    private static func image(_ descriptor: NSAppleEventDescriptor) -> NSImage? {
        guard let image = NSImage(data: descriptor.data) else { return nil }
        // Downscaled: tiles are small and full-size covers are often 3000 px.
        let side: CGFloat = 360
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        thumb.unlockFocus()
        return thumb
    }

    private static func mosaic(_ images: [NSImage]) -> NSImage? {
        guard let first = images.first else { return nil }
        guard images.count >= 4 else { return first }
        let side: CGFloat = 360, half = side / 2
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        for (i, image) in images.prefix(4).enumerated() {
            image.draw(in: NSRect(x: CGFloat(i % 2) * half, y: CGFloat(1 - i / 2) * half, width: half, height: half))
        }
        out.unlockFocus()
        return out
    }

    // MARK: Script plumbing

    private func command(_ body: String) {
        guard isRunning else { return }
        run(body) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.poll() }
        }
    }

    /// Runs `body` inside `tell application "Music"` and hands the result to the main queue.
    /// Never launches Music: scripts still queued (artwork, polls) when Music quits would
    /// otherwise reopen it, so each one checks right before it talks to Music.
    private func run(_ body: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        let source = """
        if application id "\(Self.bundleID)" is running then
        tell application id "\(Self.bundleID)"
        \(body)
        end tell
        end if
        """
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning, Date() >= self.quietUntil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let script = compiled[source] ?? {
                let s = NSAppleScript(source: source)!
                self.compiled[source] = s
                return s
            }()
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            DispatchQueue.main.async {
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -1743 {  // errAEEventNotPermitted: Automation permission denied
                        self.status = .denied
                    } else if code != -1728 {  // -1728: no current track etc.
                        NSLog("EdgeDeck: Music script error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
                    }
                    completion(nil)
                } else {
                    if self.status != .ready { self.status = .ready }
                    completion(result)
                }
            }
        }
    }

    private static func items(_ descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let stateScript = """
    set fav to false
    set hasTrack to false
    set plName to ""
    try
        set fav to favorited of current track
        set hasTrack to true
    end try
    try
        set plName to name of current playlist
    end try
    return {player state as text, shuffle enabled, song repeat as text, sound volume, fav, hasTrack, plName}
    """

    private static let devicesScript = """
    set out to {}
    repeat with d in AirPlay devices
        set end of out to {name of d, kind of d as text, selected of d}
    end repeat
    return out
    """

    private static let playlistsScript = """
    set out to {}
    repeat with p in playlists
        set end of out to {persistent ID of p, name of p, count of tracks of p, special kind of p as text}
    end repeat
    return out
    """

    private static let tracksScript = """
    set lp to library playlist 1
    return {persistent ID, album, album artist, artist, disc number, track number} of every track of lp
    """
}

// MARK: Widget

final class MusicWidgetState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case playlists = "Playlists", albums = "Albums"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .playlists
    @Published var showOutputs = false
}

struct MusicWidget: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var music: MusicModel
    let widget: WidgetConfig
    @StateObject private var state = MusicWidgetState()

    private let accent = Theme.accent(for: .music)
    private let spacing: CGFloat = 12

    private var visible: Bool {
        model.currentPage.widgets.contains { $0.id == widget.id } && model.guest.current == nil && !model.player.isOpen
    }

    var body: some View {
        Tile(title: widget.title ?? "Music", symbol: WidgetKind.music.symbol, accent: accent) {
            switch music.status {
            case .notRunning:
                prompt(symbol: "music.note", message: "Music isn't open", button: "Open Music") { music.openMusic() }
            case .denied:
                prompt(symbol: "lock.shield", message: "Allow EdgeDeck to control Music in Privacy › Automation", button: "Open Settings") {
                    music.openAutomationSettings()
                }
            case .ready:
                VStack(spacing: 12) {
                    toolbar
                    ZStack {
                        grid
                        if state.showOutputs { outputs }
                    }
                    volumeBar
                }
            }
        }
        .onAppear { music.setVisible(widget.id, visible) }
        .onChange(of: visible) { _, now in music.setVisible(widget.id, now) }
        .onDisappear { music.setVisible(widget.id, false) }
    }

    // MARK: Parts

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(MusicWidgetState.Tab.allCases) { tab in
                let selected = tab == state.tab
                Button {
                    state.tab = tab
                    state.showOutputs = false
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(selected ? Color.white : Theme.tileRaised, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            Spacer(minLength: 8)
            ToggleIcon(symbol: music.favorited ? "heart.fill" : "heart", on: music.favorited, tint: Color(hex: "#FF375F"), enabled: music.hasTrack) {
                music.toggleFavorite()
            }
            ToggleIcon(symbol: "shuffle", on: music.shuffle, tint: accent) { music.toggleShuffle() }
            ToggleIcon(symbol: music.repeatMode == .one ? "repeat.1" : "repeat", on: music.repeatMode != .off, tint: accent) { music.cycleRepeat() }
            Button {
                state.showOutputs.toggle()
                if state.showOutputs { music.refreshDevices() }
            } label: {
                let current = music.devices.filter(\.selected)
                HStack(spacing: 8) {
                    Image(systemName: current.count == 1 ? current[0].symbol : "airplayaudio")
                    Text(current.isEmpty ? "Output" : current.count == 1 ? current[0].name : "\(current.count) outputs")
                        .lineLimit(1)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(state.showOutputs ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: 220)
                .frame(height: 44)
                .background(state.showOutputs ? accent : Theme.tileRaised, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }

    @ViewBuilder
    private var grid: some View {
        let items: [MusicItem] = switch state.tab {
        case .playlists: [.shuffleAll] + music.playlists.map(MusicItem.playlist)
        case .albums: music.albums.map(MusicItem.album)
        }
        GeometryReader { geo in
            let layout = Self.layout(count: items.count, in: geo.size, spacing: spacing)
            Pager(items: items, perPage: layout.columns * layout.rows) { page in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cell.width), spacing: spacing), count: layout.columns),
                          alignment: .leading, spacing: spacing) {
                    ForEach(page) { item in
                        MusicTile(item: item, size: layout.cell, playing: isPlaying(item))
                    }
                }
            }
        }
        .id(state.tab)  // fresh pager (back to page 1) per tab
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Play on").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("tap to play only there · ＋ to add a speaker").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
                Spacer()
                TouchButton(symbol: "xmark", size: 40) { state.showOutputs = false }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                ForEach(music.devices) { device in
                    HStack(spacing: 8) {
                        Button { music.playOnly(device) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: device.symbol).font(.system(size: 22)).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                                    Text(device.kind.capitalized).font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(device.selected ? Color.black.opacity(0.6) : Theme.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(device.selected ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .frame(height: 60)
                            .background(device.selected ? accent : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        TouchButton(symbol: device.selected ? "minus" : "plus", tint: device.selected ? Theme.secondaryText : accent, size: 44,
                                    enabled: !(device.selected && music.devices.filter(\.selected).count <= 1)) {
                            music.toggle(device)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    private var volumeBar: some View {
        HStack(spacing: 12) {
            TouchButton(symbol: "speaker.fill", tint: Theme.secondaryText, size: 40) { music.setVolume(music.volume - 10) }
            TouchSlider(value: Double(music.volume) / 100, tint: accent) { music.setVolume(Int(($0 * 100).rounded())) }
                .frame(height: 40)
            TouchButton(symbol: "speaker.wave.3.fill", tint: Theme.secondaryText, size: 40) { music.setVolume(music.volume + 10) }
            Text("\(music.volume)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func prompt(symbol: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Theme.secondaryText)
            Text(message).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isPlaying(_ item: MusicItem) -> Bool {
        guard music.isPlaying, let current = music.currentPlaylist else { return false }
        switch item {
        case .playlist(let p): return p.name == current
        case .shuffleAll: return current == "Library" && music.shuffle
        case .album: return false
        }
    }

    /// Square-ish tiles (artwork plus a caption) at ≥140 pt, as many as fit.
    static func layout(count: Int, in size: CGSize, spacing: CGFloat) -> (columns: Int, rows: Int, cell: CGSize) {
        let caption: CGFloat = 44
        let pagerControls: CGFloat = 44
        var best = (columns: 1, rows: 1, cell: CGSize(width: 140, height: 140 + caption))
        // Biggest artwork that shows everything on one page…
        for rows in 1...4 {
            let artHeight = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows) - caption
            guard artHeight >= 120 else { break }
            let columns = max(1, Int((size.width + spacing) / (artHeight + spacing)))
            if columns * rows >= count {
                return (columns, rows, CGSize(width: (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns), height: artHeight + caption))
            }
        }
        // …else page through 140 pt tiles, leaving room for the pager.
        let usable = size.height - pagerControls
        let rows = max(1, Int((usable + spacing) / (140 + caption + spacing)))
        let art = (usable - CGFloat(rows - 1) * spacing) / CGFloat(rows) - caption
        let columns = max(1, Int((size.width + spacing) / (art + spacing)))
        best = (columns, rows, CGSize(width: (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns), height: art + caption))
        return best
    }
}

enum MusicItem: Identifiable {
    case shuffleAll
    case playlist(MusicModel.Playlist)
    case album(MusicModel.Album)

    var id: String {
        switch self {
        case .shuffleAll: "shuffle-all"
        case .playlist(let p): "p:" + p.id
        case .album(let a): "a:" + a.id
        }
    }
}

private struct MusicTile: View {
    @EnvironmentObject var music: MusicModel
    let item: MusicItem
    let size: CGSize
    let playing: Bool

    var body: some View {
        let art = size.height - 44
        SwipeAwareButton(action: play) {
            VStack(alignment: .leading, spacing: 4) {
                artwork
                    .frame(width: art, height: art)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if playing {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 30, height: 30)
                                .background(Theme.accent(for: .music), in: Circle())
                                .padding(8)
                        }
                    }
                    .overlay {
                        if playing {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent(for: .music), lineWidth: 2)
                        }
                    }
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onAppear {
            switch item {
            case .playlist(let p): music.requestArtwork(playlist: p)
            case .album(let a): music.requestArtwork(album: a)
            case .shuffleAll: break
            }
        }
    }

    private var title: String {
        switch item {
        case .shuffleAll: "Shuffle All"
        case .playlist(let p): p.name
        case .album(let a): a.name
        }
    }

    private var subtitle: String {
        switch item {
        case .shuffleAll: "Your whole library"
        case .playlist(let p): "\(p.trackCount) songs"
        case .album(let a): a.artist
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let key: String? = switch item {
        case .shuffleAll: nil
        case .playlist(let p): p.id
        case .album(let a): a.id
        }
        if let key, let image = music.artwork[key] {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: isFavorites ? [Color(hex: "#FF6B8A"), Color(hex: "#FF375F")] : [Color(hex: "#FC3C44"), Color(hex: "#A8326E")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: isShuffle ? "shuffle" : isFavorites ? "heart.fill" : "music.note.list")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Music's own Favourite Songs playlist: its catalog tracks expose no artwork to AppleScript.
    private var isFavorites: Bool {
        if case .playlist(let p) = item { ["Favourite Songs", "Favorite Songs"].contains(p.name) } else { false }
    }

    private var isShuffle: Bool { if case .shuffleAll = item { true } else { false } }

    private func play() {
        switch item {
        case .shuffleAll: music.shuffleAll()
        case .playlist(let p): music.play(p)
        case .album(let a): music.play(a)
        }
    }
}

/// Round icon button that shows an on/off state.
private struct ToggleIcon: View {
    let symbol: String
    let on: Bool
    let tint: Color
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(!enabled ? Color.white.opacity(0.25) : on ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(on && enabled ? tint : Theme.tileRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

/// Horizontal slider for touch: tap anywhere to jump there, or hold and drag. Commits
/// on release so Music isn't sent a command per pixel.
struct TouchSlider: View {
    @EnvironmentObject var swipe: SwipeState
    let value: Double
    let tint: Color
    let onCommit: (Double) -> Void
    @StateObject private var drag = SliderDragState()

    var body: some View {
        GeometryReader { geo in
            let shown = drag.value ?? value
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tileRaised).frame(height: 10)
                Capsule().fill(tint).frame(width: max(10, geo.size.width * shown), height: 10)
                Circle().fill(.white).frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: min(max(geo.size.width * shown - 13, 0), geo.size.width - 26))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged {
                    swipe.heldByControl = true
                    drag.value = min(max($0.location.x / geo.size.width, 0), 1)
                }
                .onEnded { g in
                    // After the page swipe has seen this drag end too (their order isn't fixed).
                    DispatchQueue.main.async { swipe.heldByControl = false }
                    let v = min(max(g.location.x / geo.size.width, 0), 1)
                    drag.value = nil
                    onCommit(v)
                })
        }
    }
}

final class SliderDragState: ObservableObject {
    @Published var value: Double?
}
