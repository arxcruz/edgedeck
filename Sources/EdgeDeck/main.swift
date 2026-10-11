import AppKit
import Combine
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: EdgePanel!
    private var menuBarCover: EdgePanel!
    private var cancellables = Set<AnyCancellable>()
    private lazy var scrollRecognizer = ScrollSwipeRecognizer(model: model, swipe: model.swipe)
    private var statusItem: NSStatusItem!
    private var editItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just above the desktop: always visible on the Edge, but any window you
        // move there (e.g. Slack as the Guest app) sits on top of it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.contentView = FirstMouseHostingView(rootView: DashboardView().environmentObject(model).environmentObject(model.swipe))

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
            guard let panel = self?.panel else { return }
            panel.acceptsKeyboard = on
            if on { panel.makeKey() }
        }

        setUpStatusItem()
        placePanel()
        NotificationCenter.default.addObserver(self, selector: #selector(placePanel),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.configStore.$config
            .map(\.display.match)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.placePanel() }
            .store(in: &cancellables)

        model.start()

        // Touch swipes arrive as scroll gestures (see ScrollSwipeRecognizer).
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel, let view = self.panel.contentView else { return event }
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
            // EDGEDECK_SNAPSHOT_LAUNCHER_EDITOR=1 opens the Launcher editor of the page's first Launcher.
            if ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_LAUNCHER_EDITOR"] == "1" {
                model.launcherEditorWidgetID = model.currentPage.widgets.first { $0.kind == .launcher }?.id
            }
            // EDGEDECK_SNAPSHOT_CITY_EDITOR=weather|worldClock opens the City editor of the page's first such widget.
            if let kind = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_CITY_EDITOR"].flatMap(WidgetKind.init(rawValue:)) {
                model.cityEditorWidgetID = model.currentPage.widgets.first { $0.kind == kind }?.id
            }
        }
    }

    private func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        if model.player.isOpen {
            model.player.snapshot(to: (path as NSString).deletingPathExtension + "-player.png")
        }
    }

    /// Finds the Edge by name, falling back to the smallest secondary display.
    private func targetScreen() -> NSScreen? {
        let match = model.config.display.match
        if let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(match) }) {
            return screen
        }
        let secondary = NSScreen.screens.dropFirst()
        return secondary.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    @objc private func placePanel() {
        if let screen = targetScreen() {
            // Stop below the menu bar the Edge shows when displays have separate Spaces.
            var frame = screen.frame
            frame.size.height = screen.visibleFrame.maxY - screen.frame.minY
            panel.setFrame(frame, display: true)
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
        } else if let main = NSScreen.main {
            // No Edge connected: show a preview strip on the main display.
            let size = NSSize(width: min(main.frame.width - 80, 1600), height: 450)
            let frame = NSRect(x: main.frame.midX - size.width / 2, y: main.frame.minY + 40, width: size.width, height: size.height)
            panel.setFrame(frame, display: true)
            model.guest.screenFrame = .zero
            menuBarCover.orderOut(nil)
        }
        panel.orderFrontRegardless()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "EdgeDeck")

        let menu = NSMenu()
        editItem = NSMenuItem(title: "Edit Layout", action: #selector(toggleEditing), keyEquivalent: "e")
        menu.addItem(editItem)
        menu.addItem(NSMenuItem(title: "Open config.json", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Send Back Guest App", action: #selector(sendBack), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        model.$editing.sink { [weak self] editing in self?.editItem.state = editing ? .on : .off }.store(in: &cancellables)
    }

    @objc private func toggleEditing() { model.editing.toggle() }
    @objc private func openConfig() { model.openConfigFile() }
    @objc private func reloadConfig() { model.configStore.reload() }
    @objc private func sendBack() { model.guest.sendBack() }
    @objc private func openAccessibility() { model.openAccessibilitySettings() }

    func applicationWillTerminate(_ notification: Notification) {
        model.guest.sendBack()
        model.nowPlaying.stop()
        model.player.close()
    }
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
