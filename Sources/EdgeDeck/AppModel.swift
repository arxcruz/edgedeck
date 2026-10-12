import AppKit
import ApplicationServices
import Combine

/// Shared state for the dashboard.
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let stats = StatsSampler()
    let notifications = NotificationWatcher()
    let guest = GuestAppManager()
    let runningApps = RunningAppsModel()
    let nowPlaying = NowPlayingModel()
    let player = EdgePlayer()
    let weather = WeatherModel()
    let calendar = CalendarModel()
    let music = MusicModel()
    let ai = AIModel()
    let touch = TouchController()
    let swipe = SwipeState()
    let remoteHost = RemoteHost()
    let remoteSource = RemoteSource()
    /// Grabbing another Mac's keyboard for the Guest app, and lending this Mac's.
    let keyboard = KeyboardGrabber()
    let keyboardLender = KeyboardLender()

    /// Whether the Xeneon Edge is plugged in; set by the app delegate.
    @Published var edgeConnected = true
    @Published var editing = false {
        didSet { if !editing { endTyping() } }
    }
    @Published private(set) var currentPageIndex = 0
    /// The Dashboard is off and the Edge is used as a normal monitor (touch still works).
    /// Remembered across launches.
    @Published var plainDisplay = UserDefaults.standard.bool(forKey: "plainDisplay") {
        didSet {
            UserDefaults.standard.set(plainDisplay, forKey: "plainDisplay")
            touch.plainDisplay = plainDisplay
            if plainDisplay {
                editing = false
                cityEditorWidgetID = nil
                launcherEditorWidgetID = nil
                ai.connectEditorOpen = false
            }
        }
    }
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private var cancellables = Set<AnyCancellable>()

    init() {
        configStore.$config
            .sink { [weak self] config in
                self?.notifications.settings = config.notifications
                self?.guest.railWidth = config.display.railWidth
                self?.ai.settings = config.ai
            }
            .store(in: &cancellables)

        // One Takeover at a time: bringing a Guest app to the Edge sends the Edge player back; the
        // video goes back to the browser where it left off, as with "Back to …".
        guest.$current
            .sink { [weak self] current in
                if current != nil, self?.player.isOpen == true { self?.sendBackVideo() }
            }
            .store(in: &cancellables)

        ai.learnedProfile = { [weak self] path in self?.addClaudeDir(path) }
        ai.showMessage = { [weak self] text in self?.flashPlayerMessage(text) }
        // Bringing an app to the Edge can fail out of sight (no window, no Accessibility for it): say so.
        guest.$lastError.compactMap { $0 }.sink { [weak self] text in self?.flashPlayerMessage(text) }.store(in: &cancellables)
        touch.plainDisplay = plainDisplay
        touch.onEdgeSwipe = { [weak self] in self?.plainDisplay = false }
        ActionRunner.showPlainDisplay = { [weak self] in self?.plainDisplay = true }
        // Bringing something to the Edge ends a Plain display, so its Rail (and Send back) show.
        guest.$current
            .sink { [weak self] current in if current != nil { self?.plainDisplay = false } }
            .store(in: &cancellables)
        player.$isOpen
            .sink { [weak self] open in if open { self?.plainDisplay = false } }
            .store(in: &cancellables)
        // A Takeover or a Plain display on the Host ends a Remote view.
        guest.$current
            .sink { [weak self] current in if current != nil { self?.remoteHost.end() } }
            .store(in: &cancellables)
        player.$isOpen
            .sink { [weak self] open in if open { self?.remoteHost.end() } }
            .store(in: &cancellables)
        $plainDisplay
            .sink { [weak self] plain in if plain { self?.remoteHost.end() } }
            .store(in: &cancellables)
        ai.$sessions
            .sink { [weak self] _ in DispatchQueue.main.async { self?.finishAnswering() } }
            .store(in: &cancellables)

        remoteHost.onProblem = { [weak self] text in self?.flashPlayerMessage(text) }
        keyboard.onProblem = { [weak self] text in self?.flashPlayerMessage(text) }
        keyboard.onGrabbed = { [weak self] in self?.guest.activate() }
        // A grabbed keyboard belongs to one Guest app: released when it goes or another replaces it.
        guest.$current
            .map { $0?.pid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.keyboard.release() }
            .store(in: &cancellables)
        $editing
            .sink { [weak self] editing in self?.remoteSource.editing = editing }
            .store(in: &cancellables)
        $typing
            .sink { [weak self] typing in self?.remoteSource.typing = typing }
            .store(in: &cancellables)

        music.$message
            .compactMap { $0 }
            .sink { [weak self] text in self?.flashPlayerMessage(text) }
            .store(in: &cancellables)

        notifications.suppressesToast = { [weak self] notification in
            self?.ai.needingYouTerminals.contains(notification.app.lowercased()) ?? false
        }

        // Forward nested changes so views observing the model refresh.
        for publisher in [configStore.objectWillChange, touch.objectWillChange, notifications.objectWillChange, guest.objectWillChange, player.objectWillChange, ai.objectWillChange, remoteHost.objectWillChange, remoteSource.objectWillChange, keyboard.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let granted = AXIsProcessTrusted()
            if self?.accessibilityGranted != granted { self?.accessibilityGranted = granted }
        }
    }

    var config: AppConfig { configStore.config }

    func start() {
        if !AXIsProcessTrusted() { requestAccessibility() }
        stats.start()
        notifications.start()
        runningApps.start()
        nowPlaying.start()
        weather.start()
        calendar.start()
        music.start()
        ai.start()
        touch.start()
        remoteHost.start()
        remoteSource.start()
        keyboard.start()
        keyboardLender.start()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// What System Settings calls the Accessibility permission: macOS 27 renamed it.
    static var accessibilityName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Tapping a notification: click the real banner (so the app opens the right
    /// conversation), then move the app onto the Edge if it's in `bringToEdgeOnTap`.
    func open(_ notification: EdgeNotification) {
        remoteHost.end()  // opening a Toast's app ends a Remote view
        let running = AppLocator.running(notification.app)
        if let banner = notifications.liveBanner(for: notification) {
            AX.perform(banner, kAXPressAction)
        } else if let running {
            running.activate()
        } else {
            AppLocator.open(notification.app)
        }
        notifications.remove(notification)

        let bringToEdge = config.notifications.bringToEdgeOnTap.contains { $0.caseInsensitiveCompare(notification.app) == .orderedSame }
        guard bringToEdge else { return }
        // Give the app a moment to switch to the conversation before grabbing its window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let app = running ?? AppLocator.running(notification.app) {
                self.guest.bringToEdgeWhenReady(app)
            } else {
                self.guest.bringToEdge(notification.app)
            }
        }
    }

    /// ✕ on a Needs-you Toast; a terminal's own notification about it goes too.
    func dismissAgentToast() {
        let terminals = ai.needingYouTerminals
        ai.dismissToast()
        if let toast = notifications.toast, terminals.contains(toast.app.lowercased()) { notifications.dismissToast() }
    }

    // MARK: Answering a Session on the Edge

    /// A Session brought to the Edge from its Needs-you Toast to be answered there, and whether
    /// the Edge was a Plain display before. Once it stops needing you, it's sent back.
    private var answering: (sessionID: String, terminalPID: pid_t, wasPlain: Bool, since: Date)?

    /// Brings the terminal tab of a Session that Needs you onto the Edge as the Guest app.
    func bringToEdge(_ session: AgentSession) {
        guard let app = ai.terminal(of: session) else {
            return flashPlayerMessage("Couldn't find the terminal running this session")
        }
        let wasPlain = plainDisplay
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.ai.selectTerminalTab(of: session)
            DispatchQueue.main.async {
                guard let self else { return }
                self.answering = (session.id, app.processIdentifier, wasPlain, Date())
                self.guest.bringToEdgeWhenReady(app)
            }
        }
    }

    /// The Session the Guest app is answering, while it still Needs you.
    var answeringSession: AgentSession? {
        guard let answering, guest.current?.pid == answering.terminalPID else { return nil }
        return ai.sessions.first { $0.id == answering.sessionID && $0.state.needsYou }
    }

    /// Answers a permission prompt with Claude Code's keys: "1" yes, "2" yes and don't ask
    /// again, "escape" no. Sent to the terminal only, so nothing else gets the key.
    func answer(_ key: String) {
        guard let answering else { return }
        KeySender.send(key, to: answering.terminalPID)
    }

    /// Sends the terminal back once its Session stops needing you, and returns the Edge to
    /// what it was (e.g. a Plain display).
    private func finishAnswering() {
        guard let current = answering else { return }
        guard guest.current?.pid == current.terminalPID else {
            // Still on its way to the Edge, or sent back by hand / replaced since.
            if Date().timeIntervalSince(current.since) > 5 { answering = nil }
            return
        }
        let stillNeeds = ai.sessions.contains { $0.id == current.sessionID && $0.state.needsYou }
        guard !stillNeeds else { return }
        answering = nil
        guest.sendBack()
        if current.wasPlain { plainDisplay = true }
    }

    // MARK: Claude Code Profiles

    /// Remembers a Profile folder in config.json; showing it again if it was hidden.
    func addClaudeDir(_ path: String) {
        let url = ClaudeProfile.url(fromConfig: path)
        configStore.update { config in
            config.ai.hiddenClaudeDirs.removeAll { ClaudeProfile.url(fromConfig: $0) == url }
            var dirs = config.ai.claudeDirs ?? []
            if !dirs.contains(where: { ClaudeProfile.url(fromConfig: $0) == url }) { dirs.append(path) }
            config.ai.claudeDirs = dirs
        }
    }

    /// Picks a Claude Code config folder in the standard folder panel, on the Mac's own screen.
    func addClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Choose a Claude Code config folder (the one CLAUDE_CONFIG_DIR points to)"
        panel.prompt = "Add Profile"
        NSApp.activate()
        // The primary screen (with the menu bar), never the Edge.
        if let screen = NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addClaudeDir(ClaudeProfile.configPath(url))
            self?.ai.connectionMessage = "Added \(ClaudeProfile(directory: url).name)"
        }
    }

    /// Hides a Profile; a Connected one is Disconnected first, or its hooks would keep
    /// writing events nobody reads.
    func hideProfile(_ profile: ClaudeProfile) {
        if let status = ai.connectionStatus[profile.key], status.hooks || status.statusline {
            ai.disconnect(profile)
        }
        configStore.update { config in
            if !config.ai.hiddenClaudeDirs.contains(where: { ClaudeProfile.url(fromConfig: $0) == profile.directory }) {
                config.ai.hiddenClaudeDirs.append(profile.configPath)
            }
        }
    }

    func showProfile(_ profile: ClaudeProfile) {
        configStore.update { $0.ai.hiddenClaudeDirs.removeAll { ClaudeProfile.url(fromConfig: $0) == profile.directory } }
    }

    func bringToEdge(_ item: RunningApp) {
        guard let app = item.app else { return }
        runningApps.bringToFront(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.guest.bringToEdgeWhenReady(app) }
    }

    // MARK: Widget settings

    /// World Clock or Weather widget whose City editor is open.
    @Published var cityEditorWidgetID: UUID?
    @Published var launcherEditorWidgetID: UUID? {
        didSet { if launcherEditorWidgetID == nil { endTyping() } }
    }
    /// A full-screen Editor is open, so horizontal swipes mustn't change pages.
    var editorOpen: Bool { cityEditorWidgetID != nil || launcherEditorWidgetID != nil || ai.connectEditorOpen }

    func widget(_ id: UUID) -> WidgetConfig? {
        pages.lazy.flatMap(\.widgets).first { $0.id == id }
    }

    func updateWidget(_ id: UUID, _ change: @escaping (inout WidgetConfig) -> Void) {
        configStore.update { config in
            for page in config.pages.indices {
                if let index = config.pages[page].widgets.firstIndex(where: { $0.id == id }) {
                    change(&config.pages[page].widgets[index])
                    return
                }
            }
        }
    }

    // MARK: Video on the Edge

    @Published var playerMessage: String?

    /// Moves the browser video that's Now Playing onto the Edge: pauses it in the
    /// browser and opens it in EdgeDeck's player at the same position.
    func watchOnEdge() {
        guard let info = nowPlaying.info, let source = info.mediaSource, BrowserTab.isBrowser(source) else { return }
        guard let url = BrowserTab.url(in: source, matching: info.title) else {
            flashPlayerMessage("Couldn't find the video's tab — make it the active tab in \(source.localizedName ?? "the browser")")
            return
        }
        guard guest.screenFrame != .zero else {
            flashPlayerMessage("The Edge isn't connected")
            return
        }
        let position = info.position(at: Date())
        if info.playing { nowPlaying.pause() }
        guest.sendBack()
        var frame = guest.screenFrame
        frame.size.width -= CGFloat(config.display.railWidth)
        player.open(url, at: position, title: info.title, source: source, frame: frame)
    }

    /// Closes the Edge player and resumes the video in the browser where it left off.
    func sendBackVideo() {
        player.currentTime { [weak self] time in
            guard let self else { return }
            self.player.close()
            // Give macOS a moment to hand Now Playing back to the browser.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let time { self.nowPlaying.seek(to: time) }
                self.nowPlaying.play()
            }
        }
    }

    func flashPlayerMessage(_ text: String) {
        playerMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.playerMessage == text { self?.playerMessage = nil }
        }
    }

    /// Buttons whose Action just failed; they flash red for a moment.
    @Published private(set) var failedButtons: Set<UUID> = []

    func run(_ button: ButtonConfig) {
        ActionRunner.run(button.action, guest: guest) { [weak self] result in
            guard !result.ok, let self else { return }
            NSLog("EdgeDeck: \(button.title) failed: \(result.message ?? "") \(result.output)")
            self.failedButtons.insert(button.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.failedButtons.remove(button.id) }
        }
    }

    // MARK: Typing

    /// Whether the dashboard panel takes keystrokes from the physical keyboard (only while a
    /// text field in an Editor is in use); set by the app delegate.
    var setKeyboardFocus: ((Bool) -> Void)?
    @Published private(set) var typing = false
    /// The app that had the keyboard before, to hand it back.
    private var typingReturnApp: NSRunningApplication?

    func beginTyping() {
        guard !typing else { return }
        typingReturnApp = NSWorkspace.shared.frontmostApplication
        typing = true
        setKeyboardFocus?(true)
    }

    func endTyping() {
        guard typing else { return }
        typing = false
        setKeyboardFocus?(false)
        typingReturnApp?.activate()
        typingReturnApp = nil
    }

    // MARK: Pages

    var pages: [PageConfig] { config.pages }

    var currentPage: PageConfig { pages[min(currentPageIndex, pages.count - 1)] }

    func showPage(_ index: Int) {
        let clamped = min(max(index, 0), pages.count - 1)
        if clamped != currentPageIndex { currentPageIndex = clamped }
    }

    func addPage() {
        configStore.update { $0.pages.insert(PageConfig(), at: currentPageIndex + 1) }
        showPage(currentPageIndex + 1)
    }

    func deletePage(_ id: UUID) {
        guard pages.count > 1 else { return }
        configStore.update { $0.pages.removeAll { $0.id == id } }
        showPage(currentPageIndex)
    }

    func movePage(_ id: UUID, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }), pages.indices.contains(index + offset) else { return }
        configStore.update { $0.pages.swapAt(index, index + offset) }
        showPage(index + offset)
    }

    // MARK: Layout editing

    private func updatePage(_ pageID: UUID, _ change: (inout PageConfig) -> Void) {
        configStore.update { config in
            guard let index = config.pages.firstIndex(where: { $0.id == pageID }) else { return }
            change(&config.pages[index])
        }
    }

    /// Moves/resizes a widget if the new frame is free; returns whether it was applied.
    @discardableResult
    func setFrame(_ frame: GridFrame, of widgetID: UUID, on pageID: UUID) -> Bool {
        guard let page = pages.first(where: { $0.id == pageID }), page.fits(frame, ignoring: widgetID) else { return false }
        updatePage(pageID) { page in
            guard let index = page.widgets.firstIndex(where: { $0.id == widgetID }) else { return }
            page.widgets[index].frame = frame
        }
        return true
    }

    func removeWidget(_ widgetID: UUID, from pageID: UUID) {
        updatePage(pageID) { $0.widgets.removeAll { $0.id == widgetID } }
    }

    /// Adds a widget to the current page in the first free spot; false if the page is full.
    @discardableResult
    func addWidget(_ type: WidgetKind) -> Bool {
        let page = currentPage
        let size = type.defaultSize
        guard let frame = page.freeFrame(w: size.w, h: size.h) else { return false }
        updatePage(page.id) { $0.widgets.append(WidgetConfig(kind: type, frame: frame, title: type == .launcher ? "Launcher" : nil)) }
        return true
    }

    func openConfigFile() {
        NSWorkspace.shared.open(configStore.url)
    }
}
