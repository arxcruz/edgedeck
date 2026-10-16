import AppKit
import CoreGraphics

/// How performing an Action went. Scripts and Shortcuts report their exit status and output.
struct ActionResult {
    var ok: Bool
    /// Why it failed, or the exit status of a script.
    var message: String?
    /// The first few KB of a script's stdout and stderr.
    var output = ""
}

/// Executes the actions bound to launcher buttons.
enum ActionRunner {
    /// Turns the Dashboard off (the Plain display Action); set by the app model.
    static var showPlainDisplay: () -> Void = {}

    static func run(_ action: ActionConfig, guest: GuestAppManager, completion: ((ActionResult) -> Void)? = nil) {
        let done = completion ?? { _ in }
        switch action.type {
        case .openApp:
            AppLocator.open(action.value) { app in
                done(app == nil ? ActionResult(ok: false, message: "App not found: \(action.value)") : ActionResult(ok: true))
            }
        case .openURL:
            guard let url = url(from: action.value) else {
                return done(ActionResult(ok: false, message: "Not a URL: \(action.value)"))
            }
            let opened = NSWorkspace.shared.open(url)
            done(opened ? ActionResult(ok: true) : ActionResult(ok: false, message: "Nothing opens \(url.scheme ?? "") links"))
        case .shell:
            spawn("/bin/zsh", ["-lc", action.value], completion: done)
        case .shortcut:
            spawn("/usr/bin/shortcuts", ["run", action.value], completion: done)
        case .appleScript:
            spawn("/usr/bin/osascript", ["-e", action.value], completion: done)
        case .keys:
            done(KeySender.send(action.value) ? ActionResult(ok: true) : ActionResult(ok: false, message: "Unknown keys: \(action.value)"))
        case .bringToEdge:
            guard AppLocator.url(for: action.value) != nil else {
                return done(ActionResult(ok: false, message: "App not found: \(action.value)"))
            }
            guard guest.screenFrame != .zero else { return done(ActionResult(ok: false, message: "The Edge isn't connected")) }
            guest.bringToEdge(action.value)
            done(ActionResult(ok: true))
        case .plainDisplay:
            showPlainDisplay()
            done(ActionResult(ok: true))
        }
    }

    /// The URL an openURL Action opens. Text with a scheme ("http://localhost", "slack://…",
    /// "mailto:…") is used as is; anything else is a web address and gets https://.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        // "host:8080" is a port, not a scheme; schemes have no dots ("www.x.com:443").
        let hasScheme = text.contains("://")
            || text.range(of: #"^[A-Za-z][A-Za-z0-9+\-]*:(?!\d)"#, options: .regularExpression) != nil
        guard let url = URL(string: hasScheme ? text : "https://" + text), url.scheme != nil else { return nil }
        if !hasScheme && (url.host ?? "").isEmpty { return nil }
        return url
    }

    /// Runs a process, reporting its exit status and the start of its output when it exits.
    private static func spawn(_ path: String, _ arguments: [String], completion: @escaping (ActionResult) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputBuffer()
        // Keep draining until EOF (children may hold the pipe open), but only remember the start.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { output.append(data) }
        }
        process.terminationHandler = { process in
            // Give the last output a moment to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let status = process.terminationStatus
                completion(ActionResult(ok: status == 0, message: "Exit status \(status)", output: output.text))
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("EdgeDeck: failed to run \(path): \(error)")
            completion(ActionResult(ok: false, message: error.localizedDescription))
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 8192 { data.append(more.prefix(8192 - data.count)) }
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Resolves "com.apple.Safari", "Safari" or "/Applications/Safari.app" to an app.
enum AppLocator {
    static func url(for identifier: String) -> URL? {
        if identifier.hasPrefix("/") || identifier.hasPrefix("~") {
            return URL(fileURLWithPath: (identifier as NSString).expandingTildeInPath)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        let name = identifier.hasSuffix(".app") ? identifier : identifier + ".app"
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        for root in roots {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func running(_ identifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == identifier
                || $0.localizedName?.caseInsensitiveCompare(identifier) == .orderedSame
                || $0.bundleURL?.path == identifier
        }
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(for identifier: String) -> NSImage? {
        if let cached = iconCache.object(forKey: identifier as NSString) { return cached }
        guard let url = url(for: identifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: identifier as NSString)
        return icon
    }

    static func open(_ identifier: String, completion: ((NSRunningApplication?) -> Void)? = nil) {
        guard let url = url(for: identifier) else {
            NSLog("EdgeDeck: app not found: \(identifier)")
            completion?(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            DispatchQueue.main.async { completion?(app) }
        }
    }
}

/// Posts keyboard shortcuts ("cmd+shift+4") and media keys ("playpause") to the frontmost app.
/// Needs the Accessibility permission.
enum KeySender {
    private static let arrowKeys: Set<String> = ["left", "right", "up", "down"]

    /// Returns false when the spec names an unknown key. With `pid`, the key goes to that app
    /// only, even if it isn't frontmost.
    @discardableResult
    static func send(_ spec: String, to pid: pid_t? = nil) -> Bool {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last else { return false }

        if parts.count == 1, let media = mediaKeys[keyName] {
            postMediaKey(media)
            return true
        }
        guard let keyCode = keyCodes[keyName] else {
            NSLog("EdgeDeck: unknown key '\(keyName)' in '\(spec)'")
            return false
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                NSLog("EdgeDeck: unknown modifier '\(modifier)'")
                return false
            }
        }
        // A real keyboard's arrow keys carry these two flags, and macOS's own shortcuts on them
        // (App Exposé ⌃↓, Mission Control ⌃↑, switching Spaces) only match when they're there.
        if arrowKeys.contains(keyName) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            if let pid { event?.postToPid(pid) } else { event?.post(tap: .cghidEventTap) }
        }
        return true
    }

    /// The spec for a key pressed on the keyboard ("cmd+shift+4"), or nil for a key EdgeDeck can't send.
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let name = keyNames[CGKeyCode(keyCode)] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }

    /// "cmd+shift+4" as "⌘⇧4", media keys by name ("Play/Pause").
    static func display(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let media = mediaKeyTitles[parts[0]] { return media }
        let symbols: [String: String] = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "opt": "⌥", "option": "⌥",
                                         "shift": "⇧", "cmd": "⌘", "command": "⌘", "fn": "fn "]
        let keys: [String: String] = ["return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "delete": "⌫",
                                      "backspace": "⌫", "forwarddelete": "⌦", "escape": "⎋", "esc": "⎋",
                                      "left": "←", "right": "→", "up": "↑", "down": "↓",
                                      "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘"]
        let modifiers = parts.dropLast().map { symbols[$0] ?? $0 }.joined()
        let key = parts.last.map { keys[$0] ?? $0.uppercased() } ?? ""
        return modifiers + key
    }

    /// Media keys in the order the Button view offers them.
    static let mediaKeyOrder = ["playpause", "previous", "next", "volumedown", "volumeup", "mute", "brightnessdown", "brightnessup"]

    static let mediaKeyTitles: [String: String] = [
        "playpause": "Play/Pause", "previous": "Previous", "next": "Next", "volumedown": "Volume Down",
        "volumeup": "Volume Up", "mute": "Mute", "brightnessdown": "Brightness Down", "brightnessup": "Brightness Up",
    ]

    private static let keyNames: [CGKeyCode: String] = {
        var names: [CGKeyCode: String] = [:]
        for (name, code) in keyCodes.sorted(by: { $0.key < $1.key }) where names[code] == nil { names[code] = name }
        // Prefer these where several names share a key code.
        names[36] = "return"; names[51] = "delete"; names[53] = "escape"
        return names
    }()

    private static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (key << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let mediaKeys: [String: Int] = [
        "volumeup": 0, "volumedown": 1, "brightnessup": 2, "brightnessdown": 3,
        "mute": 7, "playpause": 16, "next": 17, "previous": 18,
    ]

    // ANSI virtual key codes from HIToolbox/Events.h
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
