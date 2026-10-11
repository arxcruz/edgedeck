import AppKit
import SwiftUI

/// An app found in the usual Applications folders.
struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?

    var id: String { url.path }
    /// What a launcher button stores to open it.
    var identifier: String { bundleID ?? url.path }
}

enum InstalledApps {
    private static var cache: [InstalledApp]?

    /// Apps in /Applications (and one folder level down), the system and user
    /// Applications folders and Utilities, sorted by name, one entry per bundle id.
    static func load(completion: @escaping ([InstalledApp]) -> Void) {
        if let cache { return completion(cache) }
        DispatchQueue.global(qos: .userInitiated).async {
            let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                         NSHomeDirectory() + "/Applications"]
            var seen = Set<String>()
            var apps: [InstalledApp] = []
            func add(_ url: URL) {
                let bundleID = Bundle(url: url)?.bundleIdentifier
                guard seen.insert(bundleID ?? url.path).inserted else { return }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApp(url: url, name: name, bundleID: bundleID))
            }
            for root in roots {
                let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for item in items {
                    if item.pathExtension == "app" {
                        add(item)
                    } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, item.lastPathComponent != "Utilities" {
                        // Vendor folders such as "/Applications/Microsoft Office".
                        let inner = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                        inner.filter { $0.pathExtension == "app" }.forEach(add)
                    }
                }
            }
            // Finder lives in CoreServices with other apps nobody launches by hand.
            add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                cache = apps
                completion(apps)
            }
        }
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(_ app: InstalledApp) -> NSImage {
        if let cached = iconCache.object(forKey: app.id as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        iconCache.setObject(icon, forKey: app.id as NSString)
        return icon
    }
}

/// Ready-made non-app buttons offered in the editor's Controls tab.
enum LauncherPresets {
    static var controls: [ButtonConfig] {
        let media = "#34C759", sound = "#FF9F0A", system = "#5E9EFF", danger = "#FF453A"
        func key(_ title: String, _ symbol: String, _ color: String, _ keys: String) -> ButtonConfig {
            ButtonConfig(title: title, symbol: symbol, color: color, action: .init(type: .keys, value: keys))
        }
        return [
            key("Play/Pause", "playpause.fill", media, "playpause"),
            key("Previous", "backward.fill", media, "previous"),
            key("Next", "forward.fill", media, "next"),
            key("Volume Down", "speaker.wave.1.fill", sound, "volumedown"),
            key("Volume Up", "speaker.wave.3.fill", sound, "volumeup"),
            key("Mute", "speaker.slash.fill", sound, "mute"),
            key("Brightness Down", "sun.min.fill", "#FFD60A", "brightnessdown"),
            key("Brightness Up", "sun.max.fill", "#FFD60A", "brightnessup"),
            key("Screenshot", "camera.viewfinder", system, "cmd+shift+4"),
            key("Screen Capture", "record.circle", system, "cmd+shift+5"),
            key("Spotlight", "magnifyingglass", system, "cmd+space"),
            key("Mission Control", "rectangle.3.group", system, "ctrl+up"),
            key("App Windows", "macwindow.on.rectangle", system, "ctrl+down"),
            key("Emoji", "face.smiling", system, "ctrl+cmd+space"),
            key("Force Quit", "xmark.octagon.fill", danger, "cmd+alt+escape"),
            ButtonConfig(title: "Display Sleep", symbol: "moon.fill", color: "#BF5AF2", action: .init(type: .shell, value: "pmset displaysleepnow")),
            key("Lock", "lock.fill", danger, "ctrl+cmd+q"),
        ]
    }

    static func shortcut(_ name: String) -> ButtonConfig {
        ButtonConfig(title: name, app: "com.apple.shortcuts", action: .init(type: .shortcut, value: name))
    }
}

enum ShortcutsList {
    private static var cache: [String]?

    /// Names of the user's Shortcuts.app shortcuts, from `shortcuts list`.
    static func load(completion: @escaping ([String]) -> Void) {
        if let cache { return completion(cache) }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            DispatchQueue.main.async {
                cache = names
                completion(names)
            }
        }
    }
}

/// One entry in the editor's grid: an installed app or a ready-made button.
struct LauncherEditorItem: Identifiable {
    enum Kind {
        case app(InstalledApp)
        case preset(ButtonConfig)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .app(let app): "app:" + app.id
        case .preset(let button): "preset:\(button.action.type.rawValue):\(button.action.value)"
        }
    }

    var title: String {
        switch kind {
        case .app(let app): app.name
        case .preset(let button): button.title
        }
    }
}

final class LauncherEditorState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "All Apps", running = "Running", controls = "Controls", shortcuts = "Shortcuts"
        var id: String { rawValue }
    }

    /// EDGEDECK_SNAPSHOT_LAUNCHER_TAB (e.g. "Controls") picks the first tab, for snapshots.
    @Published var tab: Tab = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_LAUNCHER_TAB"].flatMap(Tab.init(rawValue:)) ?? .all
    @Published var page = 0
    @Published var apps: [InstalledApp] = []
    @Published var shortcuts: [String]?
    /// The Launcher's title being edited, until Save or Cancel; nil when not editing.
    @Published var titleDraft: String?
    /// The Button open in the Button view, or a new one not yet on the Launcher.
    @Published var detail: ButtonDetailTarget?
    var gridFrame: CGRect = .zero
}

enum ButtonDetailTarget: Hashable {
    case existing(UUID)
    case new
}

/// Full-screen touch editor for a Launcher: the buttons it has (tap to edit, reorder, remove)
/// and every installed app, control (media keys, lock…) or shortcut to add or remove with a tap.
struct LauncherEditor: View {
    @EnvironmentObject var model: AppModel
    let widgetID: UUID
    @StateObject private var state = LauncherEditorState()
    @FocusState private var titleFocused: Bool

    private let cellSize = CGSize(width: 230, height: 64)
    private let spacing: CGFloat = 8
    private var accent: Color { Theme.accent(for: .launcher) }

    var body: some View {
        if let target = state.detail {
            ButtonDetail(widgetID: widgetID, initial: button(for: target), apps: state.apps, shortcuts: state.shortcuts ?? []) { state.detail = nil }
                .id(target)
                .onAppear {
                    InstalledApps.load { state.apps = $0 }
                    ShortcutsList.load { state.shortcuts = $0 }
                }
        } else {
            picker
        }
    }

    /// The Launcher's title, edited in place: tap to type on the Mac keyboard, then Save or Cancel.
    /// Empty means the Widget shows "Launcher".
    @ViewBuilder
    private func titleField(current: String) -> some View {
        let editing = state.titleDraft != nil
        TextField("Launcher", text: Binding(get: { state.titleDraft ?? current }, set: { state.titleDraft = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(width: 320, height: 44)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(titleFocused ? accent : .clear, lineWidth: 2))
            .focused($titleFocused)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if state.titleDraft == nil { state.titleDraft = current }
                model.beginTyping()
                DispatchQueue.main.async { titleFocused = true }
            })
        if editing {
            Button { finishTitle(save: false) } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.tileRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            Button { finishTitle(save: true) } label: {
                Text("Save")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func finishTitle(save: Bool) {
        if save, let draft = state.titleDraft?.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.updateWidget(widgetID) { $0.title = draft.isEmpty ? nil : draft }
        }
        state.titleDraft = nil
        titleFocused = false
        model.endTyping()
    }

    private func button(for target: ButtonDetailTarget) -> ButtonConfig? {
        guard case .existing(let id) = target else { return nil }
        return model.widget(widgetID)?.buttons?.first { $0.id == id }
    }

    @ViewBuilder
    private var picker: some View {
        let widget = model.widget(widgetID)
        let buttons = widget?.buttons ?? []
        let chosen = Self.chosenPaths(buttons)
        let items = visibleItems

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: WidgetKind.launcher.symbol).foregroundStyle(accent)
                titleField(current: widget?.title ?? "")
                Text("\(buttons.count) buttons · tap one to edit it, or tap below to add or remove").foregroundStyle(Theme.secondaryText)
                Spacer()
                Button { model.launcherEditorWidgetID = nil } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 110, height: 44)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            selectedRow(buttons)

            HStack(spacing: 8) {
                ForEach(LauncherEditorState.Tab.allCases) { tab in
                    let selected = tab == state.tab
                    Button {
                        state.tab = tab
                        state.page = 0
                    } label: {
                        Text(tab.rawValue)
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
                let pages = max(1, Int(ceil(Double(items.count) / Double(perPage))))
                let page = min(state.page, pages - 1)
                let slice = Array(items.dropFirst(page * perPage).prefix(perPage))

                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if items.isEmpty {
                            Text(state.tab == .shortcuts ? "No shortcuts found in Shortcuts.app" : "Nothing here")
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize.width), spacing: spacing), count: columns),
                                      alignment: .leading, spacing: spacing) {
                                ForEach(slice) { item in
                                    PickButton(item: item, selected: isSelected(item, buttons: buttons, chosenPaths: chosen), size: cellSize) {
                                        toggle(item)
                                    }
                                }
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
                        if items.count > perPage { letterIndex(items: items, perPage: perPage) }
                    }
                    .frame(width: 48)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            InstalledApps.load { state.apps = $0 }
            ShortcutsList.load { state.shortcuts = $0 }
            // EDGEDECK_SNAPSHOT_BUTTON=new|<index> opens the Button view, for snapshots.
            if let which = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_BUTTON"], state.detail == nil {
                if which == "new" {
                    state.detail = .new
                } else if let index = Int(which), buttons.indices.contains(index) {
                    state.detail = .existing(buttons[index].id)
                }
            }
        }
    }

    private var visibleItems: [LauncherEditorItem] {
        switch state.tab {
        case .all:
            return state.apps.map { LauncherEditorItem(kind: .app($0)) }
        case .running:
            let running = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.bundleURL?.standardizedFileURL.path })
            return state.apps.filter { running.contains($0.url.standardizedFileURL.path) }.map { LauncherEditorItem(kind: .app($0)) }
        case .controls:
            return LauncherPresets.controls.map { LauncherEditorItem(kind: .preset($0)) }
        case .shortcuts:
            return (state.shortcuts ?? []).map { LauncherEditorItem(kind: .preset(LauncherPresets.shortcut($0))) }
        }
    }

    private var isLoading: Bool {
        switch state.tab {
        case .all, .running: state.apps.isEmpty
        case .controls: false
        case .shortcuts: state.shortcuts == nil
        }
    }

    private func isSelected(_ item: LauncherEditorItem, buttons: [ButtonConfig], chosenPaths: Set<String>) -> Bool {
        switch item.kind {
        case .app(let app): chosenPaths.contains(app.url.standardizedFileURL.path)
        case .preset(let preset): buttons.contains { $0.action == preset.action }
        }
    }

    /// Paths of the apps the launcher's app buttons open (they may name apps by
    /// bundle id, name or path).
    static func chosenPaths(_ buttons: [ButtonConfig]) -> Set<String> {
        Set(buttons.compactMap { button in
            guard [.openApp, .bringToEdge].contains(button.action.type) else { return nil }
            return AppLocator.url(for: button.action.value)?.standardizedFileURL.path
        })
    }

    /// The launcher's buttons in order, each with move and remove controls; tap one to edit it.
    private func selectedRow(_ buttons: [ButtonConfig]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                HStack(spacing: 6) {
                    TouchButton(symbol: "chevron.left", size: 32, enabled: index > 0) { move(button.id, by: -1) }
                    Button { state.detail = .existing(button.id) } label: {
                        HStack(spacing: 6) {
                            ButtonIcon(button: button, size: 24)
                            Text(button.title.isEmpty ? "No title" : button.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(button.title.isEmpty ? Theme.secondaryText : .white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    TouchButton(symbol: "chevron.right", size: 32, enabled: index < buttons.count - 1) { move(button.id, by: 1) }
                    TouchButton(symbol: "xmark", tint: Color(hex: "#FF453A"), size: 32) { remove(button.id) }
                }
                .padding(.horizontal, 6)
                .frame(height: 44)
                .background(accent.opacity(0.15), in: Capsule())
            }
            Button { state.detail = .new } label: {
                Label("New Button", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Capsule().strokeBorder(accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }

    /// A–Z strip: jumps to the page holding the first item with that letter.
    private func letterIndex(items: [LauncherEditorItem], perPage: Int) -> some View {
        let letters = Array(Set(items.compactMap { $0.title.first.map { String($0).uppercased() } })).sorted()
        return VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    if let index = items.firstIndex(where: { $0.title.uppercased().hasPrefix(letter) }) {
                        state.page = index / max(perPage, 1)
                    }
                } label: {
                    Text(letter)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func toggle(_ item: LauncherEditorItem) {
        switch item.kind {
        case .app(let app): toggle(app)
        case .preset(let preset):
            model.updateWidget(widgetID) { widget in
                var list = widget.buttons ?? []
                if let existing = list.firstIndex(where: { $0.action == preset.action }) {
                    list.remove(at: existing)
                } else {
                    list.append(preset)
                }
                widget.buttons = list
            }
        }
    }

    private func toggle(_ app: InstalledApp) {
        let path = app.url.standardizedFileURL.path
        model.updateWidget(widgetID) { widget in
            var list = widget.buttons ?? []
            let existing = list.firstIndex { button in
                [.openApp, .bringToEdge].contains(button.action.type)
                    && AppLocator.url(for: button.action.value)?.standardizedFileURL.path == path
            }
            if let existing {
                list.remove(at: existing)
            } else {
                list.append(ButtonConfig(title: app.name, action: .init(type: .openApp, value: app.identifier)))
            }
            widget.buttons = list
        }
    }

    private func remove(_ id: UUID) {
        model.updateWidget(widgetID) { $0.buttons?.removeAll { $0.id == id } }
    }

    private func move(_ id: UUID, by offset: Int) {
        model.updateWidget(widgetID) { widget in
            guard var list = widget.buttons, let index = list.firstIndex(where: { $0.id == id }),
                  list.indices.contains(index + offset) else { return }
            list.swapAt(index, index + offset)
            widget.buttons = list
        }
    }
}

private struct PickButton: View {
    let item: LauncherEditorItem
    let selected: Bool
    let size: CGSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20))
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(width: size.width, height: size.height)
            .background(selected ? Theme.accent(for: .launcher) : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .app(let app):
            AppIcon(image: InstalledApps.icon(app), size: 40)
        case .preset(let button):
            if let symbol = button.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : (button.color.map { Color(hex: $0) } ?? .white))
                    .frame(width: 40, height: 40)
                    .background((button.color.map { Color(hex: $0) } ?? .white).opacity(selected ? 0 : 0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                AppIcon(image: button.app.flatMap { AppLocator.icon(for: $0) }, size: 40)
            }
        }
    }
}
