import AppKit
import CoreGraphics

/// Executes the actions bound to launcher buttons.
enum ActionRunner {
    static func run(_ action: ActionConfig, guest: GuestAppManager) {
        switch action.type {
        case .openApp:
            AppLocator.open(action.value)
        case .openURL:
            if let url = URL(string: action.value) { NSWorkspace.shared.open(url) }
        case .shell:
            spawn("/bin/zsh", ["-lc", action.value])
        case .shortcut:
            spawn("/usr/bin/shortcuts", ["run", action.value])
        case .appleScript:
            spawn("/usr/bin/osascript", ["-e", action.value])
        case .keys:
            KeySender.send(action.value)
        case .bringToEdge:
            guest.bringToEdge(action.value)
        }
    }

    private static func spawn(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("EdgeDeck: failed to run \(path): \(error)")
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
    static func send(_ spec: String) {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last else { return }

        if parts.count == 1, let media = mediaKeys[keyName] {
            postMediaKey(media)
            return
        }
        guard let keyCode = keyCodes[keyName] else {
            NSLog("EdgeDeck: unknown key '\(keyName)' in '\(spec)'")
            return
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: NSLog("EdgeDeck: unknown modifier '\(modifier)'")
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

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
