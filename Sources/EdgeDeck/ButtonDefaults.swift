import AppKit
import SwiftUI

/// What a Button shows until the user picks something else: a title and icon that follow its Action.
enum ButtonDefaults {
    static func title(for action: ActionConfig) -> String {
        let value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.type {
        case .openApp, .bringToEdge:
            guard !value.isEmpty else { return "" }
            guard let url = AppLocator.url(for: value) else { return value }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        case .openURL:
            guard let url = ActionRunner.url(from: value), let host = url.host, !host.isEmpty else { return value }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        case .shortcut: return value
        case .keys: return value.isEmpty ? "" : KeySender.display(value)
        case .shell: return "Shell"
        case .appleScript: return "AppleScript"
        }
    }

    /// The app whose icon an automatic icon shows, if any.
    static func iconApp(for action: ActionConfig) -> String? {
        switch action.type {
        case .openApp, .bringToEdge: action.value.isEmpty ? nil : action.value
        case .shortcut: "com.apple.shortcuts"
        default: nil
        }
    }

    /// The SF Symbol an automatic icon shows when there's no app to show.
    static func symbol(for action: ActionConfig) -> String {
        switch action.type {
        case .openApp, .bringToEdge: "app.dashed"
        case .openURL: "link"
        case .shortcut: "square.2.layers.3d"
        case .keys:
            switch action.value.lowercased() {
            case "playpause": "playpause.fill"
            case "previous": "backward.fill"
            case "next": "forward.fill"
            case "volumedown": "speaker.wave.1.fill"
            case "volumeup": "speaker.wave.3.fill"
            case "mute": "speaker.slash.fill"
            case "brightnessdown": "sun.min.fill"
            case "brightnessup": "sun.max.fill"
            default: "keyboard"
            }
        case .shell: "terminal"
        case .appleScript: "applescript"
        }
    }

    /// The swatches the Button view offers.
    static let colors = ["#FF453A", "#FF9F0A", "#FFD60A", "#34C759", "#64D2FF", "#5E9EFF", "#5E5CE6", "#BF5AF2", "#FF375F", "#8E8E93"]

    /// The icons the Button view shows before any search.
    static let curatedSymbols = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "sparkles", "wand.and.stars", "lightbulb.fill", "bell.fill",
        "house.fill", "briefcase.fill", "folder.fill", "doc.fill", "doc.text.fill", "tray.full.fill", "archivebox.fill", "paperplane.fill",
        "envelope.fill", "message.fill", "bubble.left.and.bubble.right.fill", "phone.fill", "video.fill", "person.fill", "person.2.fill", "calendar",
        "clock.fill", "timer", "alarm.fill", "globe", "map.fill", "location.fill", "link", "safari.fill",
        "cart.fill", "creditcard.fill", "gift.fill", "bag.fill", "book.fill", "bookmark.fill", "newspaper.fill", "graduationcap.fill",
        "music.note", "headphones", "mic.fill", "speaker.wave.3.fill", "play.fill", "pause.fill", "playpause.fill", "forward.fill",
        "backward.fill", "camera.fill", "photo.fill", "film.fill", "tv.fill", "gamecontroller.fill", "paintbrush.fill", "pencil",
        "scissors", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "slider.horizontal.3", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "keyboard", "command", "magnifyingglass", "lock.fill", "key.fill", "shield.fill", "eye.fill", "power",
        "moon.fill", "sun.max.fill", "cloud.fill", "drop.fill", "leaf.fill", "cup.and.saucer.fill", "fork.knife", "car.fill",
        "airplane", "bicycle", "figure.walk", "dumbbell.fill", "cpu", "memorychip", "network", "wifi",
        "printer.fill", "display", "laptopcomputer", "iphone", "arrow.clockwise", "trash.fill", "xmark.octagon.fill", "checkmark.circle.fill",
    ]
}

/// Every SF Symbol on this Mac with its search keywords, read from the system's CoreGlyphs bundle.
enum SymbolCatalog {
    private static var cache: [(name: String, keywords: [String])]?

    static func load(completion: @escaping ([(name: String, keywords: [String])]) -> Void) {
        if let cache { return completion(cache) }
        DispatchQueue.global(qos: .userInitiated).async {
            let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
            func plist(_ name: String) -> [String: Any] {
                (try? Data(contentsOf: resources.appendingPathComponent(name)))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            }
            let names = (plist("name_availability.plist")["symbols"] as? [String: Any]).map { Array($0.keys) } ?? []
            let keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
            // Localised variants ("character.ja") only clutter a search.
            let locales: Set<String> = ["ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "my", "km", "bn", "gu", "kn", "ml",
                                        "mr", "or", "pa", "sat", "si", "ta", "te", "el", "ru", "mni", "tr", "fr", "de", "es"]
            let list = names
                .filter { !locales.contains(String($0.split(separator: ".").last ?? "")) }
                .sorted()
                .map { (name: $0, keywords: keywords[$0] ?? []) }
            DispatchQueue.main.async {
                cache = list
                completion(list)
            }
        }
    }
}

/// A Button's icon: its chosen symbol or app icon, else one that follows its Action.
struct ButtonIcon: View {
    let button: ButtonConfig
    var size: CGFloat
    /// Overrides the symbol colour (e.g. black on a selected tile).
    var tint: Color?

    var body: some View {
        let color = tint ?? button.color.map { Color(hex: $0) } ?? .white
        if let symbol = button.symbol {
            Image(systemName: symbol).font(.system(size: size * 0.62, weight: .semibold)).foregroundStyle(color).frame(width: size, height: size)
        } else if let app = button.app ?? ButtonDefaults.iconApp(for: button.action), let image = AppLocator.icon(for: app) {
            AppIcon(image: image, size: size)
        } else {
            Image(systemName: ButtonDefaults.symbol(for: button.action))
                .font(.system(size: size * 0.62, weight: .semibold)).foregroundStyle(color).frame(width: size, height: size)
        }
    }
}
