import AppKit
import SwiftUI

/// The Launcher editor's view of one Button: its Action, title, colour and icon, with Try.
/// Changes are made to a draft: Save applies them (adding a new Button to the Launcher), Cancel drops them.
/// Text is typed on the Mac's keyboard: tapping a field lets the panel take keystrokes.
struct ButtonDetail: View {
    @EnvironmentObject var model: AppModel
    let widgetID: UUID
    let apps: [InstalledApp]
    let shortcuts: [String]
    let close: () -> Void

    /// The Action kinds as the Button view offers them: Open and Bring to Edge are one "App" choice.
    enum Kind: String, CaseIterable, Identifiable {
        case app = "App", url = "URL", shortcut = "Shortcut", keys = "Keys", shell = "Shell", appleScript = "AppleScript"
        case plainDisplay = "Plain Display"
        var id: String { rawValue }

        init(_ type: ActionConfig.Kind) {
            switch type {
            case .openApp, .bringToEdge: self = .app
            case .openURL: self = .url
            case .shortcut: self = .shortcut
            case .keys: self = .keys
            case .shell: self = .shell
            case .appleScript: self = .appleScript
            case .plainDisplay: self = .plainDisplay
            }
        }
    }

    enum Field: Hashable { case title, url, keys, shell, appleScript, appSearch, shortcutSearch, iconSearch }

    /// The Button being edited, saved to the Launcher only by Save. Its id is the Button's
    /// identity: the view is re-created on every redraw, so it can't come from `init`.
    @State private var draft: ButtonConfig
    @State private var kind: Kind
    @State private var bringToEdge: Bool
    // What each kind's input holds, so switching kinds back and forth loses nothing. A kind's
    // value becomes the Button's Action only once it isn't empty.
    @State private var appValue: String
    @State private var urlText: String
    @State private var shortcutValue: String
    @State private var keysText: String
    @State private var shellText: String
    @State private var scriptText: String

    @State private var appSearch = ""
    @State private var shortcutSearch = ""
    @State private var iconSearch = ""
    @State private var appPage = 0
    @State private var shortcutPage = 0
    @State private var iconPage = 0
    @State private var symbols: [(name: String, keywords: [String])] = []
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var trying = false
    @State private var tryResult: ActionResult?
    @FocusState private var focus: Field?

    private var accent: Color { Theme.accent(for: .launcher) }

    /// `initial` is the Button to edit, or nil for a new one.
    init(widgetID: UUID, initial: ButtonConfig?, apps: [InstalledApp], shortcuts: [String], close: @escaping () -> Void) {
        self.widgetID = widgetID
        self.apps = apps
        self.shortcuts = shortcuts
        self.close = close
        let button = initial ?? ButtonConfig(title: "", action: .init(type: .openApp, value: ""))
        _draft = State(initialValue: button)
        let action = button.action
        func value(_ types: ActionConfig.Kind...) -> String { types.contains(action.type) ? action.value : "" }
        _kind = State(initialValue: Kind(action.type))
        _bringToEdge = State(initialValue: action.type == .bringToEdge)
        _appValue = State(initialValue: value(.openApp, .bringToEdge))
        _urlText = State(initialValue: value(.openURL))
        _shortcutValue = State(initialValue: value(.shortcut))
        _keysText = State(initialValue: value(.keys))
        _shellText = State(initialValue: value(.shell))
        _scriptText = State(initialValue: value(.appleScript))
    }

    private var buttonID: UUID { draft.id }
    private var stored: ButtonConfig? { model.widget(widgetID)?.buttons?.first { $0.id == buttonID } }
    private var button: ButtonConfig { draft }
    private var onLauncher: Bool { stored != nil }
    private var hasAction: Bool { !draft.action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSave: Bool { hasAction && draft != stored }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 20) {
                previewColumn.frame(width: 320)
                actionColumn.frame(maxWidth: .infinity)
                lookColumn.frame(width: 780)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear { SymbolCatalog.load { symbols = $0 } }
        .onDisappear {
            stopRecording()
            model.endTyping()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Label("Cancel", systemImage: "xmark")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.tileRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            Text(onLauncher ? "Button" : "New Button").font(.system(size: 20, weight: .bold, design: .rounded))
            Text(hasAction ? (canSave ? "Save keeps your changes, Cancel drops them" : "no changes") : "choose an Action first")
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if model.typing {
                Button { model.endTyping(); focus = nil } label: {
                    Label("Typing on the Mac keyboard · Stop", systemImage: "keyboard")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(accent.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            if onLauncher {
                pill("Remove", symbol: "trash", tint: Color(hex: "#FF453A")) {
                    model.updateWidget(widgetID) { [buttonID] in $0.buttons?.removeAll { $0.id == buttonID } }
                    back()
                }
            }
            Button(action: save) {
                Text(onLauncher ? "Save" : "Add to Launcher")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(canSave ? Color.black : Color.black.opacity(0.35))
                    .padding(.horizontal, 28)
                    .frame(minWidth: 110)
                    .frame(height: 44)
                    .background(canSave ? Color.white : Color.white.opacity(0.35), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSave)
        }
    }

    private func save() {
        let saved = draft
        model.updateWidget(widgetID) { widget in
            var list = widget.buttons ?? []
            if let index = list.firstIndex(where: { $0.id == saved.id }) { list[index] = saved } else { list.append(saved) }
            widget.buttons = list
        }
        back()
    }

    private func back() {
        stopRecording()
        model.endTyping()
        close()
    }

    // MARK: Preview and Try

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Preview")
            LauncherButton(button: button, height: 170)
                .allowsHitTesting(false)
                .frame(width: 200)
                .frame(maxWidth: .infinity)
            pill(trying ? "Running…" : "Try", symbol: "play.fill", tint: Color(hex: "#30D158"), enabled: hasAction && !trying, wide: true, action: tryAction)
            if let result = tryResult {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.ok ? "Worked" : (result.message ?? "Failed"), systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(result.ok ? Color(hex: "#30D158") : Color(hex: "#FF453A"))
                    if result.ok, let message = result.message, [.shell, .appleScript, .shortcut].contains(button.action.type) {
                        Text(message).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
                    }
                    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !output.isEmpty {
                        Text(output.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tryAction() {
        let action = button.action
        trying = true
        tryResult = nil
        let run = {
            ActionRunner.run(action, guest: model.guest) { result in
                trying = false
                tryResult = result
            }
        }
        if action.type == .keys && model.typing {
            // Keystrokes go to whatever has the keyboard: give it back to the previous app first.
            model.endTyping()
            focus = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: run)
        } else {
            run()
        }
    }

    // MARK: Action

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Action")
            HStack(spacing: 8) {
                ForEach(Kind.allCases) { option in
                    chip(option.rawValue, selected: option == kind) {
                        stopRecording()
                        kind = option
                        commit()
                    }
                }
            }
            switch kind {
            case .app: appInput
            case .url:
                VStack(alignment: .leading, spacing: 8) {
                    field("www.example.com, http://localhost:8080 or any app link (slack://…)", text: $urlText, field: .url)
                    if let url = ActionRunner.url(from: urlText) {
                        hint("Opens \(url.absoluteString)")
                    } else {
                        hint("Without a scheme, https:// is used. Type http:// for local servers.")
                    }
                }
            case .shortcut: shortcutInput
            case .keys: keysInput
            case .shell: scriptInput(text: $shellText, field: .shell, hint: "Runs with zsh -lc. Exit status 0 means it worked.")
            case .appleScript: scriptInput(text: $scriptText, field: .appleScript, hint: "Runs with osascript.")
            case .plainDisplay: hint("Turns the Dashboard off so the Edge is a normal monitor (touch keeps working). Swipe in from the Edge's right edge to bring it back.")
            }
        }
        .onChange(of: urlText) { _, _ in commit() }
        .onChange(of: keysText) { _, _ in commit() }
        .onChange(of: shellText) { _, _ in commit() }
        .onChange(of: scriptText) { _, _ in commit() }
    }

    /// The selected kind's input as an Action, or nil while it's empty.
    private var draftAction: ActionConfig? {
        let action: ActionConfig = switch kind {
        case .app: .init(type: bringToEdge ? .bringToEdge : .openApp, value: appValue)
        case .url: .init(type: .openURL, value: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        case .shortcut: .init(type: .shortcut, value: shortcutValue)
        case .keys: .init(type: .keys, value: keysText.trimmingCharacters(in: .whitespaces).lowercased())
        case .shell: .init(type: .shell, value: shellText)
        case .appleScript: .init(type: .appleScript, value: scriptText)
        case .plainDisplay: .init(type: .plainDisplay, value: "on")
        }
        return action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : action
    }

    /// Makes the selected kind's input the Button's Action, once it isn't empty. The title and
    /// icon follow the Action unless the user has chosen their own.
    private func commit() {
        guard let action = draftAction, action != button.action else { return }
        update { button in
            if button.title == ButtonDefaults.title(for: button.action) { button.title = ButtonDefaults.title(for: action) }
            if button.symbol == nil, button.app != nil, button.app == ButtonDefaults.iconApp(for: button.action) { button.app = nil }
            button.action = action
        }
    }

    private func update(_ change: (inout ButtonConfig) -> Void) {
        change(&draft)
    }

    private var appInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip("Open", selected: !bringToEdge) { bringToEdge = false; commit() }
                chip("Bring to Edge", selected: bringToEdge) { bringToEdge = true; commit() }
                field("Search apps", text: $appSearch, field: .appSearch)
            }
            let query = appSearch.trimmingCharacters(in: .whitespaces)
            let list = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
            let chosen = AppLocator.url(for: appValue)?.standardizedFileURL.path
            PagedGrid(items: list, cellSize: CGSize(width: 220, height: 56), page: $appPage) { app in
                pickCell(app.name, selected: app.url.standardizedFileURL.path == chosen) {
                    AppIcon(image: InstalledApps.icon(app), size: 36)
                } action: {
                    appValue = app.identifier
                    commit()
                }
            }
            .onChange(of: appSearch) { _, _ in appPage = 0 }
        }
    }

    private var shortcutInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Search shortcuts", text: $shortcutSearch, field: .shortcutSearch)
            let query = shortcutSearch.trimmingCharacters(in: .whitespaces)
            let list = (query.isEmpty ? shortcuts : shortcuts.filter { $0.localizedCaseInsensitiveContains(query) }).map(NamedItem.init)
            if shortcuts.isEmpty {
                hint("No shortcuts found in Shortcuts.app")
            }
            PagedGrid(items: list, cellSize: CGSize(width: 260, height: 56), page: $shortcutPage) { item in
                pickCell(item.name, selected: item.name == shortcutValue) {
                    AppIcon(image: AppLocator.icon(for: "com.apple.shortcuts"), size: 32)
                } action: {
                    shortcutValue = item.name
                    commit()
                }
            }
            .onChange(of: shortcutSearch) { _, _ in shortcutPage = 0 }
        }
    }

    private var keysInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(keysText.isEmpty ? "No keys yet" : KeySender.display(keysText))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(keysText.isEmpty ? Theme.secondaryText : .white)
                    .frame(minWidth: 200, alignment: .leading)
                pill(recording ? "Press the keys… (Esc cancels)" : "Record", symbol: recording ? "record.circle.fill" : "record.circle",
                     tint: Color(hex: "#FF453A"), filled: recording) {
                    recording ? stopRecording() : startRecording()
                }
            }
            hint("Record presses the combo on the Mac keyboard. Combos macOS keeps for itself (⌘Space…) can be typed instead, e.g. cmd+shift+4.")
            field("cmd+shift+4", text: $keysText, field: .keys)
            sectionLabel("Media keys")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
                ForEach(KeySender.mediaKeyOrder, id: \.self) { key in
                    let sample = ButtonConfig(title: "", action: .init(type: .keys, value: key))
                    pickCell(KeySender.mediaKeyTitles[key] ?? key, selected: keysText == key) {
                        ButtonIcon(button: sample, size: 32)
                    } action: {
                        stopRecording()
                        keysText = key
                    }
                }
            }
        }
    }

    private func scriptInput(text: Binding<String>, field: Field, hint text2: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: text)
                .font(.system(size: 15, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focus == field ? accent : .clear, lineWidth: 2))
                .focused($focus, equals: field)
                .simultaneousGesture(TapGesture().onEnded { startTyping(field) })
            hint(text2)
        }
    }

    private func startRecording() {
        focus = nil
        model.beginTyping()
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode != 53 || !modifiers.isEmpty, let spec = KeySender.spec(keyCode: event.keyCode, modifiers: modifiers) {
                keysText = spec
            }
            stopRecording()
            model.endTyping()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = false
    }

    // MARK: Title, colour and icon

    private var lookColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Title")
            HStack(spacing: 8) {
                field("No title: the Button shows only its icon", text: Binding(get: { button.title }, set: { value in update { $0.title = value } }), field: .title)
                let defaultTitle = ButtonDefaults.title(for: button.action)
                pill("Default", symbol: "arrow.uturn.backward", enabled: !defaultTitle.isEmpty && button.title != defaultTitle) {
                    update { $0.title = defaultTitle }
                }
                pill("Icon only", symbol: "textformat.size", enabled: !button.title.isEmpty) { update { $0.title = "" } }
            }
            sectionLabel("Colour")
            HStack(spacing: 10) {
                swatch(nil)
                ForEach(ButtonDefaults.colors, id: \.self) { swatch($0) }
            }
            HStack(spacing: 8) {
                sectionLabel("Icon")
                Spacer()
                field("Search all symbols", text: $iconSearch, field: .iconSearch).frame(width: 360)
            }
            let query = iconSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let names = query.isEmpty ? ButtonDefaults.curatedSymbols
                : symbols.filter { $0.name.contains(query) || $0.keywords.contains { $0.contains(query) } }.map(\.name)
            let items = [NamedItem(name: "")] + names.map(NamedItem.init)
            PagedGrid(items: items, cellSize: CGSize(width: 60, height: 56), page: $iconPage) { item in
                iconCell(item.name)
            }
            .onChange(of: iconSearch) { _, _ in iconPage = 0 }
        }
    }

    private func swatch(_ hex: String?) -> some View {
        let selected = button.color == hex
        let color = hex.map { Color(hex: $0) } ?? Theme.tileRaised
        return Button { update { $0.color = hex } } label: {
            ZStack {
                Circle().fill(color)
                if hex == nil { Image(systemName: "nosign").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.secondaryText) }
                if selected { Circle().strokeBorder(.white, lineWidth: 3) }
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    /// One icon choice; the empty name is "Auto", the icon that follows the Action.
    private func iconCell(_ name: String) -> some View {
        let auto = name.isEmpty
        let selected = auto ? button.symbol == nil : button.symbol == name
        return Button {
            update { button in
                button.symbol = auto ? nil : name
                if auto { button.app = nil }
            }
        } label: {
            Group {
                if auto {
                    VStack(spacing: 0) {
                        ButtonIcon(button: ButtonConfig(title: "", color: button.color, action: button.action), size: 28)
                        Text("Auto").font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                } else {
                    Image(systemName: name).font(.system(size: 22, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.black : (button.color.map { Color(hex: $0) } ?? .white))
            .frame(width: 60, height: 56)
            .background(selected ? accent : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Pieces

    private func startTyping(_ field: Field) {
        stopRecording()
        model.beginTyping()
        DispatchQueue.main.async { focus = field }
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focus == field ? accent : .clear, lineWidth: 2))
            .focused($focus, equals: field)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { startTyping(field) })
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondaryText)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.secondaryText)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(selected ? Color.white : Theme.tileRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func pill(_ title: String, symbol: String, tint: Color = .white, filled: Bool = false, enabled: Bool = true,
                      wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? .white : enabled ? tint : tint.opacity(0.3))
                .padding(.horizontal, 16)
                .frame(maxWidth: wide ? .infinity : nil)
                .frame(height: 44)
                .background(filled ? tint : Theme.tileRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    private func pickCell(_ title: String, selected: Bool, @ViewBuilder icon: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)) }
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? accent : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct NamedItem: Identifiable {
    let name: String
    var id: String { name }
}

/// A grid that fills the space it's given and pages with touch-sized ▲ ▼ buttons.
struct PagedGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let cellSize: CGSize
    @Binding var page: Int
    @ViewBuilder let cell: (Item) -> Cell

    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - 56 + spacing) / (cellSize.width + spacing)))
            let rows = max(1, Int((geo.size.height + spacing) / (cellSize.height + spacing)))
            let perPage = columns * rows
            let pages = max(1, Int(ceil(Double(items.count) / Double(perPage))))
            let current = min(page, pages - 1)
            HStack(alignment: .top, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize.width), spacing: spacing), count: columns),
                          alignment: .leading, spacing: spacing) {
                    ForEach(Array(items.dropFirst(current * perPage).prefix(perPage))) { item in
                        cell(item).frame(width: cellSize.width, height: cellSize.height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    if value.translation.height < -40 { page = min(current + 1, pages - 1) }
                    if value.translation.height > 40 { page = max(current - 1, 0) }
                })
                if pages > 1 {
                    VStack(spacing: 8) {
                        TouchButton(symbol: "chevron.up", size: 44, enabled: current > 0) { page = current - 1 }
                        Text("\(current + 1)/\(pages)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondaryText)
                        TouchButton(symbol: "chevron.down", size: 44, enabled: current < pages - 1) { page = current + 1 }
                    }
                    .frame(width: 48)
                }
            }
        }
    }
}
