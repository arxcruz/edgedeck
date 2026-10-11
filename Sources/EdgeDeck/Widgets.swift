import AppKit
import SwiftUI

struct WidgetView: View {
    let widget: WidgetConfig

    var body: some View {
        switch widget.kind {
        case .cpu: CPUWidget()
        case .gpu: GPUWidget()
        case .memory: MemoryWidget()
        case .disk: DiskWidget()
        case .network: NetworkWidget()
        case .notifications: NotificationsWidget()
        case .launcher: LauncherWidget(widget: widget)
        case .runningApps: RunningAppsWidget(widget: widget)
        case .nowPlaying: NowPlayingWidget()
        case .worldClock: WorldClockWidget(widget: widget)
        case .weather: WeatherWidget(widget: widget)
        case .calendar: CalendarWidget(widget: widget)
        case .music: MusicWidget(widget: widget)
        case .ai: AIWidget(widget: widget)
        }
    }
}

struct CPUWidget: View {
    @EnvironmentObject var stats: StatsSampler

    var body: some View {
        Tile(title: "CPU", symbol: WidgetKind.cpu.symbol, accent: Theme.accent(for: .cpu)) {
            VStack(alignment: .leading, spacing: 10) {
                BigValue(text: String(format: "%.0f", stats.cpu * 100), unit: "%")
                Sparkline(values: stats.cpuHistory, color: Theme.accent(for: .cpu))
                // One bar per core.
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(stats.cpuCores.enumerated()), id: \.offset) { _, load in
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.load(load))
                                    .frame(height: max(2, geo.size.height * load))
                            }
                        }
                    }
                }
                .frame(height: 34)
            }
        }
    }
}

struct GPUWidget: View {
    @EnvironmentObject var stats: StatsSampler

    var body: some View {
        Tile(title: "GPU", symbol: WidgetKind.gpu.symbol, accent: Theme.accent(for: .gpu)) {
            VStack(alignment: .leading, spacing: 10) {
                if let gpu = stats.gpu {
                    BigValue(text: String(format: "%.0f", gpu * 100), unit: "%")
                    Sparkline(values: stats.gpuHistory, color: Theme.accent(for: .gpu))
                } else {
                    Text("Unavailable").foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

struct MemoryWidget: View {
    @EnvironmentObject var stats: StatsSampler

    var body: some View {
        let gb = 1_073_741_824.0
        Tile(title: "Memory", symbol: WidgetKind.memory.symbol, accent: Theme.accent(for: .memory)) {
            VStack(alignment: .leading, spacing: 10) {
                BigValue(text: String(format: "%.1f", Double(stats.memoryUsed) / gb), unit: String(format: "/ %.0f GB", Double(stats.memoryTotal) / gb))
                Sparkline(values: stats.memoryHistory, color: Theme.accent(for: .memory))
            }
        }
    }
}

struct DiskWidget: View {
    @EnvironmentObject var stats: StatsSampler

    var body: some View {
        let used = stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : 0
        Tile(title: "Disk", symbol: WidgetKind.disk.symbol, accent: Theme.accent(for: .disk)) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Ring(fraction: used, color: Theme.accent(for: .disk), lineWidth: 12)
                    VStack(spacing: 0) {
                        Text(Format.percent(used)).font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("used").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(width: 104, height: 104)
                .frame(maxWidth: .infinity)
                Text("\(Format.bytes(Double(stats.diskTotal - stats.diskUsed))) free")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                RateRow(symbol: "arrow.down.doc", label: "Read", value: stats.diskRead)
                RateRow(symbol: "square.and.arrow.down", label: "Write", value: stats.diskWrite)
                Sparkline(values: stats.diskHistory, maxValue: nil, color: Theme.accent(for: .disk))
            }
            .foregroundStyle(.white)
        }
    }
}

struct NetworkWidget: View {
    @EnvironmentObject var stats: StatsSampler

    var body: some View {
        let peak = max(stats.netInHistory.max() ?? 0, stats.netOutHistory.max() ?? 0, 1)
        Tile(title: "Network", symbol: WidgetKind.network.symbol, accent: Theme.accent(for: .network)) {
            VStack(alignment: .leading, spacing: 10) {
                RateRow(symbol: "arrow.down.circle.fill", label: "Down", value: stats.netIn, big: true, tint: Theme.accent(for: .network))
                RateRow(symbol: "arrow.up.circle.fill", label: "Up", value: stats.netOut, big: true, tint: Color(hex: "#FF9F0A"))
                ZStack {
                    Sparkline(values: stats.netInHistory, maxValue: peak, color: Theme.accent(for: .network))
                    Sparkline(values: stats.netOutHistory, maxValue: peak, color: Color(hex: "#FF9F0A"))
                }
            }
        }
    }
}

struct RateRow: View {
    let symbol: String
    let label: String
    let value: Double
    var big = false
    var tint: Color = Theme.secondaryText

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(Format.rate(value))
                .font(.system(size: big ? 26 : 16, weight: big ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .font(.system(size: big ? 20 : 14))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityLabel("\(label) \(Format.rate(value))")
    }
}

struct NotificationsWidget: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.notifications.items
        Tile(title: "Notifications", symbol: WidgetKind.notifications.symbol, accent: Theme.accent(for: .notifications)) {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash").font(.system(size: 34))
                    Text("No notifications").font(.system(size: 16, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let perPage = max(1, Int((geo.size.height - 52) / 92))
                    Pager(items: items, perPage: perPage) { page in
                        VStack(spacing: 8) {
                            ForEach(page) { NotificationCard(notification: $0) }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button("Clear") { model.notifications.clearAll() }
                        .buttonStyle(PressableStyle())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .offset(y: -34)
                }
            }
        }
    }
}

struct NotificationCard: View {
    @EnvironmentObject var model: AppModel
    let notification: EdgeNotification
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Button { model.open(notification) } label: {
                HStack(alignment: .top, spacing: 12) {
                    AppIcon(image: AppLocator.running(notification.app)?.icon ?? AppLocator.icon(for: notification.app), size: compact ? 28 : 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(notification.title.isEmpty ? notification.app : notification.title)
                                .font(.system(size: compact ? 14 : 17, weight: .semibold, design: .rounded))
                            Spacer(minLength: 4)
                            Text(notification.date, style: .time)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if !notification.subtitle.isEmpty {
                            Text(notification.subtitle).font(.system(size: compact ? 12 : 14, weight: .medium)).foregroundStyle(Theme.secondaryText)
                        }
                        Text(notification.body)
                            .font(.system(size: compact ? 12 : 15))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(compact ? 2 : 2)
                    }
                    .lineLimit(1)
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if !compact {
                TouchButton(symbol: "xmark", tint: Theme.secondaryText, size: 40) { model.notifications.close(notification) }
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : 84, alignment: .leading)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct LauncherWidget: View {
    @EnvironmentObject var model: AppModel
    let widget: WidgetConfig

    private let spacing: CGFloat = 10

    /// Picks the column count that gives the biggest square buttons for all items
    /// on one page; falls back to paging with 112pt buttons if they'd get too small.
    static func grid(count: Int, in size: CGSize, spacing: CGFloat) -> (columns: Int, rows: Int, cell: CGFloat) {
        var best = (columns: 1, rows: max(count, 1), cell: CGFloat(0))
        for columns in 1...max(count, 1) {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let height = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let cell = min(width, height)
            if cell > best.cell { best = (columns, rows, cell) }
        }
        if best.cell >= 96 { return (best.columns, best.rows, min(best.cell, 190)) }
        let cell: CGFloat = 112
        let columns = max(1, Int((size.width + spacing) / (cell + spacing)))
        let rows = max(1, Int((size.height - 44 + spacing) / (cell + spacing)))
        return (columns, rows, cell)
    }

    var body: some View {
        let buttons = widget.buttons ?? []
        Tile(title: widget.title ?? "Launcher", symbol: WidgetKind.launcher.symbol, accent: Theme.accent(for: .launcher)) {
            if buttons.isEmpty {
                Button { model.launcherEditorWidgetID = widget.id } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle").font(.system(size: 34))
                        Text("Add apps").font(.system(size: 16, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            } else {
                GeometryReader { geo in
                    let grid = Self.grid(count: buttons.count, in: geo.size, spacing: spacing)
                    Pager(items: buttons, perPage: grid.columns * grid.rows) { page in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: grid.columns), spacing: spacing) {
                            ForEach(page) { LauncherButton(button: $0, height: grid.cell) }
                        }
                    }
                }
            }
        }
    }
}

struct LauncherButton: View {
    @EnvironmentObject var model: AppModel
    let button: ButtonConfig
    let height: CGFloat

    var body: some View {
        let tint = button.color.map { Color(hex: $0) } ?? .white
        let appTarget = [.openApp, .bringToEdge].contains(button.action.type) && !button.action.value.isEmpty ? button.action.value : nil
        let missing = appTarget.map { AppLocator.url(for: $0) == nil } ?? false
        let failed = model.failedButtons.contains(button.id)
        Button { model.run(button) } label: {
            VStack(spacing: 8) {
                icon(tint: tint)
                if !button.title.isEmpty {
                    Text(button.title)
                        .font(.system(size: height > 150 ? 16 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(button.color == nil ? Theme.tileRaised : tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                // The Action just failed.
                if failed {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: "#FF453A").opacity(0.45))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: "#FF453A"), lineWidth: 3))
                }
            }
            .animation(.easeOut(duration: 0.2), value: failed)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .top) {
                if missing {
                    Text("Not installed")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.top, 8)
                }
            }
            .opacity(missing ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(missing)
    }

    private func icon(tint: Color) -> some View {
        ButtonIcon(button: button, size: max(48, height * 0.45), tint: tint)
    }
}

final class SelectionState: ObservableObject {
    @Published var selected: pid_t?
    @Published var pressing: pid_t?
}

/// Apps that are currently open. Tap to bring forward; long-press for
/// Move to Edge / Hide / Quit.
struct RunningAppsWidget: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var running: RunningAppsModel
    let widget: WidgetConfig
    @StateObject private var state = SelectionState()

    private let spacing: CGFloat = 10

    var body: some View {
        let apps = running.apps
        Tile(title: widget.title ?? "Running", symbol: WidgetKind.runningApps.symbol, accent: Theme.accent(for: .runningApps)) {
            GeometryReader { geo in
                let grid = LauncherWidget.grid(count: apps.count, in: geo.size, spacing: spacing)
                Pager(items: apps, perPage: grid.columns * grid.rows) { page in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: grid.columns), spacing: spacing) {
                        ForEach(page) { RunningAppTile(item: $0, height: grid.cell, state: state) }
                    }
                }
            }
            .overlay {
                if let pid = state.selected, let item = apps.first(where: { $0.id == pid }) {
                    actionSheet(for: item)
                }
            }
        }
        // Close the action sheet if the app quit.
        .onChange(of: apps.map(\.id)) { _, ids in
            if let pid = state.selected, !ids.contains(pid) { state.selected = nil }
        }
    }

    private func actionSheet(for item: RunningApp) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                AppIcon(image: item.icon, size: 44)
                Text(item.name).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
            }
            HStack(spacing: 10) {
                SheetButton(title: "Bring to Edge", symbol: "rectangle.portrait.and.arrow.right", tint: Color(hex: "#BF5AF2")) {
                    state.selected = nil
                    model.bringToEdge(item)
                }
                SheetButton(title: "Hide", symbol: "eye.slash", tint: Color(hex: "#5E9EFF")) {
                    state.selected = nil
                    running.hide(item)
                }
                SheetButton(title: "Quit", symbol: "xmark.octagon", tint: Color(hex: "#FF453A")) {
                    state.selected = nil
                    running.quit(item)
                }
            }
            Button("Cancel") { state.selected = nil }
                .buttonStyle(PressableStyle())
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .frame(minHeight: 40)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.tile.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SheetButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct RunningAppTile: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var running: RunningAppsModel
    let item: RunningApp
    let height: CGFloat
    @ObservedObject var state: SelectionState

    var body: some View {
        let onEdge = model.guest.current?.pid == item.id
        let pressed = state.pressing == item.id
        VStack(spacing: 8) {
            AppIcon(image: item.icon, size: max(48, height * 0.45))
                .overlay(alignment: .topTrailing) {
                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                            .background(Color(hex: "#FF453A"), in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
            Text(item.name)
                .font(.system(size: height > 150 ? 16 : 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // Dim the content, not the tile: .opacity() on the tapped view breaks hit-testing on macOS 27.
        .opacity(item.isHidden ? 0.5 : 1)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            // Frontmost app gets an outline; the Guest app gets a purple one.
            if onEdge || item.isActive {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(onEdge ? Color(hex: "#BF5AF2") : Color.white.opacity(0.6), lineWidth: 2)
            }
        }
        .scaleEffect(pressed ? 0.94 : 1)
        .brightness(pressed ? 0.12 : 0)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { running.bringToFront(item) }
        .onLongPress {
            state.selected = item.id
        } onPressingChanged: { isPressing in
            state.pressing = isPressing ? item.id : nil
        }
    }
}

struct NowPlayingWidget: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nowPlaying: NowPlayingModel

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.3
            // Text and controls grow with the widget; 1.0 ≈ a 2-row widget.
            let scale = min(max(geo.size.height / 300, 0.85), 1.6)
            ZStack {
                // Pinned to the widget's size: an aspect-filled image would otherwise
                // grow the ZStack and push the controls out of view.
                background.frame(width: geo.size.width, height: geo.size.height).clipped()
                if let info = nowPlaying.info {
                    if wide {
                        HStack(spacing: 22 * scale) {
                            artworkView(maxWidth: geo.size.width * 0.42, maxHeight: geo.size.height - 36)
                            details(info, scale: scale)
                        }
                        .padding(18)
                    } else {
                        VStack(spacing: 14) {
                            artworkView(maxWidth: geo.size.width - 36, maxHeight: geo.size.height * 0.42)
                            details(info, scale: scale)
                        }
                        .padding(18)
                    }
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    /// Blurred artwork wash behind the controls.
    private var background: some View {
        ZStack {
            Theme.tile
            if let backdrop = nowPlaying.backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .overlay(Color.black.opacity(0.35))
            }
        }
    }

    /// Artwork keeps its own aspect ratio (video thumbnails are 16:9) and is never
    /// blown up past 3× — browser artwork is often tiny.
    private func artworkView(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        let image = nowPlaying.artwork
        let pixelSize = image?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
        let aspect = pixelSize.width > 0 && pixelSize.height > 0 ? pixelSize.width / pixelSize.height : 1
        var height = min(maxHeight, maxWidth / aspect)
        if pixelSize.height > 0 { height = min(height, max(pixelSize.height * 3, maxHeight * 0.6)) }
        let width = height * aspect

        return Button { nowPlaying.bringSourceToFront() } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.tileRaised
                        Image(systemName: "music.note").font(.system(size: height * 0.35)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(width: max(width, 0), height: max(height, 0))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(PressableStyle())
        .frame(maxHeight: .infinity)
    }

    private func details(_ info: NowPlayingInfo, scale: CGFloat) -> some View {
        // While the video plays in EdgeDeck's own player, credit the browser it came from.
        let onEdge = model.player.isOpen && info.isWebKitPlayer
        let source = onEdge ? model.player.source : info.mediaSource
        return VStack(alignment: .leading, spacing: 12 * scale) {
            VStack(alignment: .leading, spacing: 4 * scale) {
                if let source {
                    HStack(spacing: 6) {
                        AppIcon(image: source.icon, size: 18 * scale)
                        Text((source.localizedName ?? "") + (onEdge ? " · on the Edge" : ""))
                            .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.secondaryText)
                }
                Text(info.title)
                    .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                    .lineLimit(2)
                if let subtitle = [info.artist, info.album].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                    Text(subtitle)
                        .font(.system(size: 16 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            ProgressRow(info: info, scale: scale)
            controls(info, scale: scale)
            if onEdge {
                HStack(spacing: 10 * scale) {
                    PillButton(title: "Back to \(source?.localizedName ?? "browser")", symbol: "arrow.uturn.backward", scale: scale, prominent: true) {
                        model.sendBackVideo()
                    }
                    PillButton(title: "Close player", symbol: "xmark", scale: scale) { model.player.close() }
                }
            } else if let source {
                HStack(spacing: 10 * scale) {
                    PillButton(title: "Open in \(source.localizedName ?? "app")", symbol: "arrow.up.forward.app", scale: scale) {
                        nowPlaying.bringSourceToFront()
                    }
                    if BrowserTab.isBrowser(source) {
                        PillButton(title: "Watch on Edge", symbol: "play.rectangle.on.rectangle", scale: scale, prominent: true) {
                            model.watchOnEdge()
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        // Content sits together in the middle instead of being spread to the edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func controls(_ info: NowPlayingInfo, scale: CGFloat) -> some View {
        HStack(spacing: 24 * scale) {
            Spacer(minLength: 0)
            TouchButton(symbol: "backward.fill", size: 50 * scale) { nowPlaying.previous() }
            Button { nowPlaying.togglePlayPause() } label: {
                Image(systemName: info.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 28 * scale, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 66 * scale, height: 66 * scale)
                    .background(Color.white, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            TouchButton(symbol: "forward.fill", size: 50 * scale) { nowPlaying.next() }
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note").font(.system(size: 36))
            Text(nowPlaying.unavailableReason ?? "Nothing playing")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.secondaryText)
        .padding()
    }
}

private struct PillButton: View {
    let title: String
    let symbol: String
    var scale: CGFloat = 1
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 14 * scale)
                .frame(height: 40 * scale)
                .background(prominent ? Color.white : Color.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Progress bar with elapsed/remaining times; tap anywhere on it to seek.
private struct ProgressRow: View {
    @EnvironmentObject var nowPlaying: NowPlayingModel
    let info: NowPlayingInfo
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = info.position(at: context.date)
            let duration = info.duration ?? 0
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let fraction = duration > 0 ? min(position / duration, 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 6 * scale)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard duration > 0 else { return }
                        nowPlaying.seek(to: duration * min(max(location.x / geo.size.width, 0), 1))
                    }
                }
                .frame(height: 22)
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text(duration > 0 ? "-" + Self.time(duration - position) : "")
                }
                .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
