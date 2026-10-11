import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.03, green: 0.03, blue: 0.04)
    static let tile = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let tileRaised = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let secondaryText = Color.white.opacity(0.55)

    static func accent(for type: WidgetKind) -> Color {
        switch type {
        case .cpu: Color(hex: "#5E9EFF")
        case .gpu: Color(hex: "#BF5AF2")
        case .memory: Color(hex: "#30D158")
        case .disk: Color(hex: "#FF9F0A")
        case .network: Color(hex: "#64D2FF")
        case .notifications: Color(hex: "#FF453A")
        case .launcher: Color(hex: "#FFD60A")
        case .runningApps: Color(hex: "#5E9EFF")
        case .nowPlaying: Color(hex: "#FF375F")
        case .worldClock: Color(hex: "#66D4CF")
        case .weather: Color(hex: "#FFC94D")
        case .calendar: Color(hex: "#FF7A59")
        case .music: Color(hex: "#FC3C44")
        case .ai: Color(hex: "#D97757")
        }
    }

    static func load(_ fraction: Double) -> Color {
        fraction > 0.85 ? Color(hex: "#FF453A") : fraction > 0.6 ? Color(hex: "#FF9F0A") : Color(hex: "#30D158")
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let value = UInt64(cleaned, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    /// Fill behind the content; the Weather widget passes `.clear` and draws its own sky.
    var background: Color = Theme.tile
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(accent)
                Text(title.uppercased()).tracking(1.2)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Filled area chart of the last N samples. `maxValue` nil auto-scales.
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = 1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.000_001)
            let count = max(StatsSampler.historyLength - 1, 1)
            let step = geo.size.width / CGFloat(count)
            let start = CGFloat(StatsSampler.historyLength - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step,
                        y: geo.size.height * (1 - CGFloat(min(value / top, 1))))
            }
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct BigValue: View {
    let text: String
    var unit: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let unit {
                Text(unit).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

struct Ring: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 36

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.badge").font(.system(size: size * 0.6)).frame(width: size, height: size).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Large, touch-sized round icon button.
///
/// Note: never dim a Button with `.opacity()` — on macOS 27 that stops it receiving
/// clicks. Dim the colours inside the label instead (as `enabled` does here).
struct TouchButton: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 44
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(enabled ? tint : tint.opacity(0.3))
                .frame(width: size, height: size)
                .background(Theme.tileRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

/// Visible press feedback, important on a touchscreen without hover.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

final class PageState: ObservableObject {
    @Published var page = 0
    /// Where the pager is on screen, to match vertical scroll swipes to it. Not published:
    /// it's written during layout.
    var frame: CGRect = .zero
}

extension View {
    /// Calls `action(forward)` for vertical scroll swipes (see ScrollSwipeRecognizer)
    /// that start inside this view, whose on-screen frame is tracked in `frame`.
    func onVerticalSwipe(frame: @escaping (CGRect) -> Void, contains: @escaping (CGPoint) -> Bool,
                         _ action: @escaping (Bool) -> Void) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { frame(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, new in frame(new) }
        })
        .onReceive(NotificationCenter.default.publisher(for: .edgeDeckVerticalSwipe)) { note in
            guard let location = note.userInfo?["location"] as? CGPoint, contains(location),
                  let forward = note.userInfo?["forward"] as? Bool else { return }
            action(forward)
        }
    }
}

/// Splits items into pages that fit the available space. Touch input arrives as
/// mouse drags, not scroll events, so lists page with buttons/swipes instead of
/// scrolling. Only vertical swipes are used; horizontal ones switch dashboard pages.
struct Pager<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let perPage: Int
    @ViewBuilder let layout: ([Item]) -> Cell
    // @State is a macro in the macOS 27 SDK and its plugin ships only with Xcode,
    // so plain Command Line Tools builds keep view state in an ObservableObject.
    @StateObject private var state = PageState()
    private var page: Int {
        get { state.page }
        nonmutating set { state.page = newValue }
    }

    var body: some View {
        let pages = max(1, Int(ceil(Double(items.count) / Double(max(perPage, 1)))))
        let current = min(page, pages - 1)
        let slice = Array(items.dropFirst(current * max(perPage, 1)).prefix(max(perPage, 1)))

        VStack(spacing: 8) {
            layout(slice)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dy) > abs(dx) else { return }
                    let forward = dy < -40
                    let back = dy > 40
                    if forward { page = min(current + 1, pages - 1) } else if back { page = max(current - 1, 0) }
                })
            if pages > 1 {
                HStack(spacing: 14) {
                    TouchButton(symbol: "chevron.up", size: 36, enabled: current > 0) { page = max(current - 1, 0) }
                    HStack(spacing: 6) {
                        ForEach(0..<pages, id: \.self) { index in
                            Circle().fill(index == current ? Color.white : Color.white.opacity(0.25)).frame(width: 7, height: 7)
                        }
                    }
                    TouchButton(symbol: "chevron.down", size: 36, enabled: current < pages - 1) { page = min(current + 1, pages - 1) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onVerticalSwipe(frame: { state.frame = $0 }, contains: { state.frame.contains($0) }) { forward in
            page = forward ? min(current + 1, pages - 1) : max(current - 1, 0)
        }
    }
}

/// A wrapping row of chips that reorder by dragging: the chip follows the finger, the others make
/// room, and `onMove(from, to)` is called once when it's let go. `trailing` ends the row (e.g. "+ New").
struct ReorderableChips<Item: Identifiable, Chip: View, Trailing: View>: View {
    let items: [Item]
    var minChipWidth: CGFloat = 230
    let onMove: (_ from: Int, _ to: Int) -> Void
    @ViewBuilder let chip: (Item) -> Chip
    @ViewBuilder var trailing: () -> Trailing

    @State private var dragging: Item.ID?
    @State private var location: CGPoint = .zero
    /// The order while a chip is being dragged.
    @State private var order: [Item.ID]?
    @State private var frames: [Item.ID: CGRect] = [:]

    private let space = "reorderableChips"

    var body: some View {
        let shown = order.map { order in order.compactMap { id in items.first { $0.id == id } } } ?? items
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minChipWidth), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(shown) { item in
                chip(item)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ChipFrames.self, value: [AnyHashable(item.id): geo.frame(in: .named(space))])
                    })
                    // The slot the dragged chip will land in. (Not `.opacity`: it stops Buttons taking clicks.)
                    .overlay {
                        if dragging == item.id {
                            Capsule().fill(Theme.background.opacity(0.85))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        }
                    }
                    .highPriorityGesture(drag(item))
            }
            trailing()
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(ChipFrames.self) { all in
            frames = Dictionary(uniqueKeysWithValues: all.compactMap { key, frame in (key.base as? Item.ID).map { ($0, frame) } })
        }
        .overlay(alignment: .topLeading) {
            if let id = dragging, let item = items.first(where: { $0.id == id }), let frame = frames[id] {
                chip(item)
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(1.06)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .position(location)
                    .allowsHitTesting(false)
            }
        }
    }

    private func drag(_ item: Item) -> some Gesture {
        // Big enough that a finger's wobble during a Tap doesn't count as a drag.
        DragGesture(minimumDistance: 8, coordinateSpace: .named(space))
            .onChanged { value in
                if dragging == nil {
                    dragging = item.id
                    order = items.map(\.id)
                }
                location = value.location
                guard var current = order, let from = current.firstIndex(of: item.id),
                      let target = frames.first(where: { $0.key != item.id && $0.value.contains(value.location) })?.key,
                      let to = current.firstIndex(of: target) else { return }
                current.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
                withAnimation(.easeOut(duration: 0.15)) { order = current }
            }
            .onEnded { _ in
                if let order, let from = items.firstIndex(where: { $0.id == item.id }),
                   let to = order.firstIndex(of: item.id), from != to {
                    onMove(from, to)
                }
                dragging = nil
                order = nil
            }
    }
}

private struct ChipFrames: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] { [:] }
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension Array {
    /// Moves the element at `from` so it ends up at index `to`.
    mutating func move(from: Int, to: Int) {
        guard indices.contains(from), indices.contains(to), from != to else { return }
        insert(remove(at: from), at: to)
    }
}

/// The line above a chip row saying its chips can be dragged.
struct ReorderHint: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "hand.draw")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
    }
}

// MARK: Long-press

extension View {
    /// A Long-press: a held touch (EdgeDeck's own touch handling delivers it as a held mouse
    /// button, so it fires while the finger is still down) or a right click.
    func onLongPress(perform action: @escaping () -> Void, onPressingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        onLongPressGesture(minimumDuration: 0.45, perform: action, onPressingChanged: onPressingChanged)
            .overlay(RightClickCatcher(action: action))
    }
}

/// Takes right clicks only; every other event passes through to the views below.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
}
