import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Borderless panel that never takes focus from the app you're working in on
/// the main display, so taps on the Edge act like Stream Deck presses.
final class EdgePanel: NSPanel {
    /// True only while an Editor's text field is in use.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Accept the first click so a single touch triggers buttons even though the
/// panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    private var panel: EdgePanel!
    /// Remote view: the Source's Dashboard, over this Mac's own on the Edge.
    private var remotePanel: EdgePanel!
    /// While a Host watches this Mac (the Source) and there's no Edge here: the size to draw the
    /// Dashboard at, hidden under the wallpaper.
    private var remoteWatchSize: CGSize?
    private var remoteItem: NSMenuItem!
    /// While this Mac's keyboard types into the Source: the app that had it, to hand it back.
    private var remoteTypingReturnApp: NSRunningApplication?
    private var menuBarCover: EdgePanel!
    private var cancellables = Set<AnyCancellable>()
    private lazy var scrollRecognizer = ScrollSwipeRecognizer(model: model, swipe: model.swipe)
    private var statusItem: NSStatusItem!
    private var editItem: NSMenuItem!
    private var waitingItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    /// On the main screen while this Mac's keyboard types on another Mac.
    private var keyboardLabel: NSPanel?
    private var plainItem: NSMenuItem!
    /// On a Plain display: the pull-tab hint at the right edge, shown for a few seconds.
    private var pullTab: EdgePanel!
    private var pullTabHide: DispatchWorkItem?
    private let edgeResolution = EdgeResolution()
    private let settingsContext = SettingsContext()
    /// App-level settings in a normal window, never on the Edge unless it's the only display.
    private var settingsWindow: NSWindow?
    /// On a Plain display: Needs-you Toasts float over whatever windows are on the Edge.
    private var toastPanel: EdgePanel!
    /// The dashboard in a window on the main display, for looking and editing while the Edge
    /// isn't connected. Opened from the menu only.
    private var previewWindow: NSWindow?
    /// The dashboard's size on the Edge, so the preview lays out exactly the same.
    private var edgeSize = NSSize(width: 2560, height: 690)

    private static let panelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just above the desktop: always visible on the Edge, but any window you
        // move there (e.g. Slack as the Guest app) sits on top of it.
        panel.level = Self.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.contentView = FirstMouseHostingView(rootView: DashboardView().environmentObject(model).environmentObject(model.swipe))

        remotePanel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        remotePanel.level = panel.level
        remotePanel.collectionBehavior = panel.collectionBehavior
        remotePanel.hidesOnDeactivate = false
        remotePanel.isOpaque = true
        remotePanel.backgroundColor = .black
        remotePanel.hasShadow = false
        remotePanel.contentView = RemoteStreamView(host: model.remoteHost)
        model.remoteHost.$current
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.placePanel() } }
            .store(in: &cancellables)
        model.remoteSource.onWatch = { [weak self] size in
            guard let self else { return nil }
            self.remoteWatchSize = size
            self.placePanel()
            return self.panel
        }
        // A text field on the Source is in use: this Mac's keyboard goes to the stream, which
        // forwards it. Afterwards the keyboard goes back to the app that had it.
        model.remoteHost.$sourceTyping
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] typing in
                guard let self else { return }
                self.remotePanel.acceptsKeyboard = typing
                if typing {
                    self.remoteTypingReturnApp = NSWorkspace.shared.frontmostApplication
                    self.remotePanel.makeKey()
                    self.remotePanel.makeFirstResponder(self.remotePanel.contentView)
                } else {
                    self.remotePanel.resignKey()
                    self.remoteTypingReturnApp?.activate()
                    self.remoteTypingReturnApp = nil
                }
            }
            .store(in: &cancellables)
        model.remoteSource.onPairRequest = { [weak self] hostName, answer in self?.askForPairingCode(hostName, answer) }
        model.remoteSource.beforeReading = { [weak self] hostName, answer in self?.explainKeychain(hostName, answer) }
        model.keyboardLender.beforeReading = { [weak self] hostName, answer in self?.explainKeychain(hostName, answer) }

        // Blank cover over the menu bar on the Edge only. It's opaque to clicks so taps
        // there don't open invisible menus.
        menuBarCover = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menuBarCover.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        menuBarCover.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        menuBarCover.hidesOnDeactivate = false
        menuBarCover.isOpaque = true
        menuBarCover.hasShadow = false
        menuBarCover.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)

        model.setKeyboardFocus = { [weak self] on in
            guard let self else { return }
            if let preview = self.previewWindow {
                // The preview is an ordinary window: it just needs to be the key one.
                if on { NSApp.activate(); preview.makeKey() }
                return
            }
            self.panel.acceptsKeyboard = on
            if on { self.panel.makeKey() }
        }

        setUpStatusItem()
        setUpKeyboardLabel()
        // Before the first placePanel: starting on a Plain display shows the pull tab at once.
        setUpPlainDisplayPanels()
        placePanel()
        NotificationCenter.default.addObserver(self, selector: #selector(placePanel),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.configStore.$config
            .map(\.display.match)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.placePanel() }
            .store(in: &cancellables)

        model.touch.onEdgetapFound = { [weak self] in self?.edgetapFound() }
        model.$plainDisplay
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.placePanel() } }
            .store(in: &cancellables)
        // Needs-you Toasts follow the AI state; checked whenever the model changes.
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateToastPanel() } }
            .store(in: &cancellables)
        model.start()

        // Touch swipes arrive as scroll gestures (see ScrollSwipeRecognizer).
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = event.window, window === self.panel || window === self.previewWindow,
                  let view = window.contentView else { return event }
            self.scrollRecognizer.handle(event, in: view)
            return nil
        }

        // Debug aid: EDGEDECK_SNAPSHOT=/path/out.png renders the dashboard to a PNG every few
        // seconds, for checking the layout without access to the physical screen.
        if let path = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.snapshot(to: path) }
            // EDGEDECK_SNAPSHOT_PAGE=n starts on page n (0-based), to snapshot it without touch input.
            if let page = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_PAGE"].flatMap(Int.init) { model.showPage(page) }
            if ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_EDIT"] == "1" { model.editing = true }
            // EDGEDECK_SNAPSHOT_PREVIEW=1 opens the preview window (with EDGEDECK_NO_EDGE=1); it's saved as <path>-preview.png.
            if ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_PREVIEW"] == "1" { togglePreview() }
            // EDGEDECK_SNAPSHOT_LAUNCHER_EDITOR=1 opens the Launcher editor of the page's first Launcher.
            if ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_LAUNCHER_EDITOR"] == "1" {
                model.launcherEditorWidgetID = model.currentPage.widgets.first { $0.kind == .launcher }?.id
            }
            // EDGEDECK_SNAPSHOT_CONNECT=1 opens the AI Widget's Editor (Connect Claude Code).
            if ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_CONNECT"] == "1" { model.ai.connectEditorOpen = true }
            // EDGEDECK_SNAPSHOT_CITY_EDITOR=weather|worldClock opens the City editor of the page's first such widget.
            if let kind = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_CITY_EDITOR"].flatMap(WidgetKind.init(rawValue:)) {
                model.cityEditorWidgetID = model.currentPage.widgets.first { $0.kind == kind }?.id
            }
            // EDGEDECK_SNAPSHOT_TIMING_EDITOR=timer|pomodoro opens the Editor of the page's first such widget.
            if let kind = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_TIMING_EDITOR"].flatMap(WidgetKind.init(rawValue:)) {
                model.timingEditorWidgetID = model.currentPage.widgets.first { $0.kind == kind }?.id
            }
        }
    }

    private func snapshot(to path: String) {
        if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        if let view = previewWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-preview.png"))
        }
        if model.player.isOpen {
            model.player.snapshot(to: (path as NSString).deletingPathExtension + "-player.png")
        }
        // The floating Needs-you Toast on a Plain display.
        if toastPanel.isVisible, let view = toastPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-toast.png"))
        }
    }

    /// The Edge, found by name only: guessing (e.g. "the smallest other display") would put the
    /// dashboard over the MacBook's screen while the Edge is unplugged.
    private func targetScreen() -> NSScreen? {
        // EDGEDECK_NO_EDGE=1 behaves as if the Edge were unplugged, for testing.
        if ProcessInfo.processInfo.environment["EDGEDECK_NO_EDGE"] == "1" { return nil }
        let match = model.config.display.match
        return NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(match) }
    }

    @objc private func placePanel() {
        if let screen = targetScreen() {
            // Stop below the menu bar the Edge shows when displays have separate Spaces.
            var frame = screen.frame
            frame.size.height = screen.visibleFrame.maxY - screen.frame.minY
            panel.setFrame(frame, display: true)
            panel.level = Self.panelLevel
            model.remoteHost.dashboardSize = frame.size
            // visibleFrame excludes the menu bar shown on the Edge when displays have separate Spaces.
            model.guest.screenFrame = screen.visibleFrame

            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            if menuBarHeight > 0 {
                menuBarCover.setFrame(NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                                             width: screen.frame.width, height: menuBarHeight), display: true)
                menuBarCover.orderFrontRegardless()
            } else {
                menuBarCover.orderOut(nil)
            }
            edgeSize = frame.size
            model.touch.display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if model.config.display.fixResolution, let display = model.touch.display {
                // Switching raises another display change, which places the panel again.
                DispatchQueue.main.async { [weak self] in
                    self?.edgeResolution.check(display)
                    self?.updateResolutionState()
                }
            }
            if model.plainDisplay {
                // A normal monitor: no Dashboard and no cover over the Edge's menu bar.
                panel.orderOut(nil)
                menuBarCover.orderOut(nil)
                showPullTab(on: screen)
            } else {
                hidePullTab()
                panel.orderFrontRegardless()
            }
            if model.remoteHost.current != nil && !model.plainDisplay {
                remotePanel.setFrame(frame, display: true)
                remotePanel.orderFrontRegardless()
            } else {
                remotePanel.orderOut(nil)
            }
            model.edgeConnected = true
            previewWindow?.close()
        } else {
            // No Edge: nothing on screen until it's plugged in (or the preview is opened).
            model.guest.screenFrame = .zero
            model.touch.display = nil
            hidePullTab()
            panel.orderOut(nil)
            menuBarCover.orderOut(nil)
            remotePanel.orderOut(nil)
            model.edgeConnected = false
            if let size = remoteWatchSize, let screen = NSScreen.main {
                // A Host is watching: draw the Dashboard at the lowest window level, under the
                // wallpaper, where it can be captured but not seen. (Just below the desktop level
                // is still above the wallpaper on macOS 27.)
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
                panel.setFrame(NSRect(origin: screen.frame.origin, size: size), display: true)
                panel.orderFrontRegardless()
            }
        }
        updateStatusItem()
    }

    // MARK: Preview

    @objc private func togglePreview() {
        if let previewWindow {
            previewWindow.close()
            return
        }
        let size = edgeSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width * 0.6, height: size.height * 0.6),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "EdgeDeck Preview"
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.backgroundColor = .black
        window.contentView = FirstMouseHostingView(rootView: ScaledDashboard(size: size).environmentObject(model).environmentObject(model.swipe))
        window.delegate = self
        window.center()
        previewWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateStatusItem()
    }

    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === settingsWindow {
            settingsWindow = nil
            // The Dock icon and ⌘-Tab entry were only for the Settings window.
            DispatchQueue.main.async { if self.settingsWindow == nil { NSApp.setActivationPolicy(.accessory) } }
        }
        guard window === previewWindow else { return }
        model.endTyping()
        previewWindow = nil
        updateStatusItem()
    }

    // MARK: Settings

    @objc private func openSettings() {
        // An accessory app's window can't take focus properly, so EdgeDeck is a regular app while it's open.
        NSApp.setActivationPolicy(.regular)
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        settingsContext.tryResolutionAgain = { [weak self] in self?.fixResolution() }
        settingsContext.keepResolutionChanged = { [weak self] in
            guard let self, self.model.config.display.fixResolution else { return }
            self.placePanel()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "EdgeDeck Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model, context: settingsContext))
        window.delegate = self
        // Never on the Edge, unless it's the only display.
        let edge = targetScreen()
        let screen = NSScreen.screens.first { $0 != edge } ?? edge ?? NSScreen.main
        if let screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func fixResolution() {
        guard let display = model.touch.display else { return }
        edgeResolution.check(display, manual: true)
        updateResolutionState()
    }

    /// The Settings window shows the "couldn't fix it" state only when EdgeDeck has given up.
    private func updateResolutionState() {
        settingsContext.resolutionStuck = edgeResolution.stuck
        settingsContext.modeChanged()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "EdgeDeck")

        let menu = NSMenu()
        menu.delegate = self
        waitingItem = NSMenuItem(title: "Waiting for the Xeneon Edge…", action: nil, keyEquivalent: "")
        waitingItem.isEnabled = false
        menu.addItem(waitingItem)
        previewItem = NSMenuItem(title: "Show Preview", action: #selector(togglePreview), keyEquivalent: "p")
        menu.addItem(previewItem)
        editItem = NSMenuItem(title: "Edit Layout", action: #selector(toggleEditing), keyEquivalent: "e")
        menu.addItem(editItem)
        remoteItem = NSMenuItem(title: "Show on Edge", action: nil, keyEquivalent: "")
        remoteItem.submenu = NSMenu()
        remoteItem.submenu?.delegate = self
        menu.addItem(remoteItem)
        plainItem = NSMenuItem(title: "Use as Plain Display", action: #selector(togglePlainDisplay), keyEquivalent: "d")
        menu.addItem(plainItem)
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Send Back Guest App", action: #selector(sendBack), keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        model.$editing.sink { [weak self] editing in self?.editItem.state = editing ? .on : .off }.store(in: &cancellables)
        model.$plainDisplay.sink { [weak self] plain in self?.plainItem.state = plain ? .on : .off }.store(in: &cancellables)
    }

    /// The menu bar icon and menu say whether the Edge is connected.
    private func updateStatusItem() {
        guard let statusItem else { return }
        let connected = model.edgeConnected
        if let name = model.keyboardLender.lentTo {
            statusItem.button?.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "EdgeDeck: keyboard typing on \(name)")
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: connected ? "rectangle.split.3x1" : "rectangle.dashed",
                                               accessibilityDescription: connected ? "EdgeDeck" : "EdgeDeck: waiting for the Edge")
        }
        waitingItem.isHidden = connected
        previewItem.isHidden = connected
        previewItem.state = previewWindow != nil ? .on : .off
    }

    /// The submenu is filled when it opens, not every time the main menu does.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === remoteItem.submenu { fillRemoteMenu(menu) }
    }

    // MARK: Remote view

    /// Which Mac's Dashboard the Edge shows: this one, or a Source found on the network.
    private func fillRemoteMenu(_ menu: NSMenu) {
        let host = model.remoteHost
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(MenuAction("This Mac", checked: host.current == nil) { host.end() })
        for name in host.sources {
            menu.addItem(MenuAction(name, checked: host.current == name) { host.show(name) })
        }
        if host.sources.isEmpty {
            let none = MenuAction("No other Macs found") {}
            none.isEnabled = false
            menu.addItem(none)
        }
        remoteItem.isEnabled = model.edgeConnected
    }

    /// Another Mac connects, and reading the Pairing secret saved by an earlier EdgeDeck will make
    /// macOS ask for the password: say why first, or Pair again instead. Not a modal dialog: while
    /// one is up, macOS drops every touch on the Edge.
    private func explainKeychain(_ hostName: String, _ answer: @escaping (_ pairAgain: Bool) -> Void) {
        PromptWindow.show(title: "EdgeDeck", cancel: { answer(false) }) { close in
            KeychainPrompt(hostName: hostName) { pairAgain in close(); answer(pairAgain) }
        }
    }

    /// On the Source: a Host wants to Pair, and its Edge shows the code. Not modal (see above).
    private func askForPairingCode(_ hostName: String, _ answer: @escaping (String?) -> Void) {
        PromptWindow.show(title: "Pair with \(hostName)", cancel: { answer(nil) }) { close in
            PairingPrompt(hostName: hostName) { code in close(); answer(code) }
        }
    }

    // MARK: Keyboard

    private func setUpKeyboardLabel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 56), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: KeyboardLentLabel(lender: model.keyboardLender))
        keyboardLabel = panel
        model.keyboardLender.$lentTo
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                guard let self, let panel = self.keyboardLabel else { return }
                self.updateStatusItem()
                guard name != nil, let screen = NSScreen.screens.first else { return panel.orderOut(nil) }
                // Top centre of the main screen, just under the menu bar.
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 8))
                panel.orderFrontRegardless()
            }
            .store(in: &cancellables)
    }

    // MARK: Touch

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    static func quitEdgetap() {
        NSRunningApplication.runningApplications(withBundleIdentifier: TouchController.edgetapBundleID).forEach { $0.terminate() }
    }

    /// The old Edgetap app holds the touchscreen. Ask once; after a yes, quit it whenever it's found.
    private func edgetapFound() {
        let key = "touch.quitEdgetap"
        if UserDefaults.standard.bool(forKey: key) { return Self.quitEdgetap() }
        let alert = NSAlert()
        alert.messageText = "EdgeDeck now handles touch"
        alert.informativeText = "Edgetap is running and holding the Edge's touchscreen. Quit it now? EdgeDeck will also quit it whenever it finds it running.\n\nTo stop Edgetap opening at login, remove it in Login Items (opens next)."
        alert.addButton(withTitle: "Quit Edgetap")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: key)
        Self.quitEdgetap()
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func toggleEditing() { model.editing.toggle() }
    @objc private func togglePlainDisplay() { model.plainDisplay.toggle() }

    // MARK: Plain display

    private func setUpPlainDisplayPanels() {
        func floatingPanel() -> EdgePanel {
            let panel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            return panel
        }
        pullTab = floatingPanel()
        pullTab.contentView = FirstMouseHostingView(rootView: PullTab { [weak self] in self?.model.plainDisplay = false })
        toastPanel = floatingPanel()
        toastPanel.contentView = FirstMouseHostingView(rootView: PlainDisplayToast().environmentObject(model))
    }

    /// The hint that the Dashboard is a swipe away; fades after a few seconds so it never
    /// covers windows for good.
    private func showPullTab(on screen: NSScreen) {
        let size = NSSize(width: 44, height: 160)
        pullTab.setFrame(NSRect(x: screen.frame.maxX - size.width, y: screen.visibleFrame.midY - size.height / 2,
                                width: size.width, height: size.height), display: true)
        pullTab.alphaValue = 1
        pullTab.orderFrontRegardless()
        pullTabHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; self?.pullTab.animator().alphaValue = 0 }) {
                self?.pullTab.orderOut(nil)
            }
        }
        pullTabHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }

    private func hidePullTab() {
        pullTabHide?.cancel()
        pullTab?.orderOut(nil)
    }

    private func updateToastPanel() {
        guard let toastPanel else { return }
        // Over a Plain display or a Remote view, this Mac's Toasts float above whatever is on the Edge.
        let remote = model.remoteHost.current != nil && model.remoteHost.pairingCode == nil
        let show = (model.plainDisplay || remote) && model.edgeConnected
            && (!model.ai.toastSessions.isEmpty || (remote && model.notifications.toast != nil)
                || (model.plainDisplay && (!model.timing.toastRinging.isEmpty || !model.markets.toastPulsing.isEmpty)))
        guard show, let screen = targetScreen() else {
            if toastPanel.isVisible { toastPanel.orderOut(nil) }
            return
        }
        // As big as the Toast plus room for its shadow, so the shadow is never cut off.
        let size = toastPanel.contentView?.fittingSize ?? NSSize(width: 824, height: 150)
        let margin = AgentToastView.floatingMargin
        toastPanel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height + margin - 8,
                                   width: size.width, height: size.height), display: true)
        if !toastPanel.isVisible { toastPanel.orderFrontRegardless() }
    }
    @objc private func reloadConfig() { model.configStore.reload() }
    @objc private func sendBack() { model.guest.sendBack() }

    func applicationWillTerminate(_ notification: Notification) {
        model.touch.stop()
        model.guest.sendBack()
        model.nowPlaying.stop()
        model.player.close()
    }
}

// Debug aid: EDGEDECK_AI_DUMP=1 prints the AI Agents Sessions after a couple of polls and exits
// (EDGEDECK_OPENCODE_DB=<path> reads another OpenCode database).
if ProcessInfo.processInfo.environment["EDGEDECK_AI_DUMP"] == "1" {
    let ai = AIModel()
    ai.settings.opencodeDatabase = ProcessInfo.processInfo.environment["EDGEDECK_OPENCODE_DB"]
    ai.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    print("opencode plugin: \(ai.openCodeStatus.map { "\($0)" } ?? "OpenCode not installed")")
    for s in ai.sessions {
        print([s.tool.rawValue, s.profile ?? "-", s.project, s.title ?? "-", s.agent ?? "-", s.state.label,
               "\(s.state)", "cost \(s.cost.map { String(format: "%.2f", $0) } ?? "-")", "pid \(s.pid.map(String.init) ?? "-")", "terminal \(ai.terminal(of: s)?.localizedName ?? "-")"].joined(separator: " | "))
    }
    exit(0)
}

// Debug aid: EDGEDECK_CLAUDE_CONNECT=connect|disconnect|status EDGEDECK_CLAUDE_DIR=<dir> runs the
// AI widget's Connect on one profile directory and exits (for testing on a copy).
if let mode = ProcessInfo.processInfo.environment["EDGEDECK_CLAUDE_CONNECT"],
   let dir = ProcessInfo.processInfo.environment["EDGEDECK_CLAUDE_DIR"] {
    let profile = ClaudeProfile(directory: URL(fileURLWithPath: dir, isDirectory: true))
    do {
        switch mode {
        case "connect": print(try ClaudeConnection.connect(profile))
        case "disconnect": print(try ClaudeConnection.disconnect(profile))
        default: break
        }
        print("key=\(profile.key) name=\(profile.name) status=\(ClaudeConnection.status(profile))")
    } catch {
        print("error: \(error)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
