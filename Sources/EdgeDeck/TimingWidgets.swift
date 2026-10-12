import AppKit
import SwiftUI

/// Where a Timer or Pomodoro is too small for digits and chips together: it shows the digits
/// while counting and the chips otherwise.
private func isCompact(_ size: CGSize) -> Bool { size.height < 140 || size.width < 240 }

// MARK: Timer

struct TimerWidget: View {
    @EnvironmentObject var timing: TimingModel
    let widget: WidgetConfig

    var body: some View {
        let accent = Theme.accent(for: .timer)
        let countdown = timing.countdown(widget)
        Tile(title: widget.title ?? "Timer", symbol: WidgetKind.timer.symbol, accent: accent) {
            GeometryReader { geo in
                let compact = isCompact(geo.size)
                VStack(spacing: 12) {
                    if !compact || countdown.state != .ready {
                        CountdownDigits(countdown: countdown, color: accent) { timing.tap(widget) }
                    }
                    if !compact || !countdown.isRunning && countdown.state != .ringing {
                        controls(countdown, accent: accent, compact: compact)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ringing(countdown.state == .ringing, color: accent) { timing.acknowledge(widget.id) }
    }

    @ViewBuilder
    private func controls(_ countdown: Countdown, accent: Color, compact: Bool) -> some View {
        HStack(spacing: 8) {
            switch countdown.state {
            case .ready:
                ForEach(widget.presets ?? WidgetConfig.defaultPresets, id: \.self) { minutes in
                    CountdownChip(title: compact ? Countdown.shortMinutes(minutes) : Countdown.minutes(minutes), tint: accent) { timing.start(widget.id, minutes: minutes) }
                }
            case .running:
                CountdownChip(title: "+1 min", symbol: "plus", tint: accent) { timing.addMinute(widget.id) }
            case .paused:
                CountdownChip(title: "Resume", symbol: "play.fill", tint: accent) { timing.tap(widget) }
                CountdownChip(title: "Reset", symbol: "arrow.counterclockwise", tint: .white) { timing.reset(widget.id) }
            case .ringing:
                EmptyView()
            }
        }
    }
}

// MARK: Pomodoro

struct PomodoroWidget: View {
    @EnvironmentObject var timing: TimingModel
    let widget: WidgetConfig

    var body: some View {
        let lengths = widget.pomodoro ?? PomodoroLengths()
        let countdown = timing.countdown(widget)
        let color = Self.color(countdown.phase)
        Tile(title: widget.title ?? "Pomodoro", symbol: WidgetKind.pomodoro.symbol, accent: Theme.accent(for: .pomodoro)) {
            GeometryReader { geo in
                let compact = isCompact(geo.size)
                VStack(spacing: 10) {
                    HStack {
                        Text(countdown.phase == .work ? "Work" : "Break")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(color)
                        Spacer(minLength: 8)
                        RoundDots(countdown: countdown, rounds: lengths.rounds, color: color)
                    }
                    if !compact || countdown.isRunning || countdown.state == .ringing {
                        CountdownDigits(countdown: countdown, color: color) { timing.tap(widget) }
                    }
                    if !compact || !countdown.isRunning && countdown.state != .ringing {
                        controls(countdown, color: color)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ringing(countdown.state == .ringing, color: color) { timing.acknowledge(widget.id) }
    }

    /// Work in the Pomodoro's own colour, Break in green.
    static func color(_ phase: Countdown.Phase) -> Color {
        phase == .work ? Theme.accent(for: .pomodoro) : Color(hex: "#30D158")
    }

    @ViewBuilder
    private func controls(_ countdown: Countdown, color: Color) -> some View {
        HStack(spacing: 8) {
            switch countdown.state {
            case .ready:
                CountdownChip(title: countdown.phase == .work ? "Start Work" : "Start Break", symbol: "play.fill", tint: color) { timing.tap(widget) }
            case .running:
                // The digits pause it; nothing else to do while it counts.
                Text("Tap the time to pause")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(height: 48)
            case .paused:
                CountdownChip(title: "Resume", symbol: "play.fill", tint: color) { timing.tap(widget) }
                CountdownChip(title: "Skip", symbol: "forward.end.fill", tint: .white) { timing.skip(widget) }
                CountdownChip(title: "Reset Cycle", symbol: "arrow.counterclockwise", tint: .white) { timing.resetCycle(widget.id) }
            case .ringing:
                EmptyView()
            }
        }
    }
}

/// One dot per Round of the Cycle: done ones filled, the current one ringed.
private struct RoundDots: View {
    let countdown: Countdown
    let rounds: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(rounds, 1), id: \.self) { index in
                // A Round is done once its Work is.
                let done = index < countdown.round || index == countdown.round && countdown.phase == .rest
                Circle()
                    .fill(done ? color : Color.white.opacity(0.18))
                    .overlay(Circle().strokeBorder(index == countdown.round ? color : .clear, lineWidth: 2))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

// MARK: Parts

/// The time left, as large as the space allows, with a bar showing how much has gone. Tapping
/// it starts, pauses or resumes. Ticks once a second only while running.
private struct CountdownDigits: View {
    let countdown: Countdown
    let color: Color
    let action: () -> Void

    var body: some View {
        SwipeAwareButton(action: action) {
            Group {
                if case .running(let endsAt) = countdown.state {
                    // Ticks on the whole seconds before the end, so the digits change in step with it.
                    let anchor = endsAt.addingTimeInterval(-endsAt.timeIntervalSinceNow.rounded(.up))
                    TimelineView(.periodic(from: anchor, by: 1)) { context in
                        content(left: countdown.left(at: context.date))
                    }
                } else {
                    content(left: countdown.left(at: Date()))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func content(left: TimeInterval) -> some View {
        let paused = if case .paused = countdown.state { true } else { false }
        let fraction = countdown.duration > 0 ? left / countdown.duration : 0
        return VStack(spacing: 8) {
            Text(Countdown.format(left))
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(paused ? Theme.secondaryText : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(paused ? Theme.secondaryText : color).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }
}

/// A touch-sized pill on a Timer or Pomodoro.
private struct CountdownChip: View {
    let title: String
    var symbol: String?
    let tint: Color
    let action: () -> Void

    var body: some View {
        SwipeAwareButton(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .background(tint == .white ? Theme.tileRaised : tint.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

extension View {
    /// While Ringing: the Widget pulses, and a Tap anywhere on it stops it.
    func ringing(_ on: Bool, color: Color, tap: @escaping () -> Void) -> some View {
        overlay {
            if on {
                ZStack {
                    RingingPulse(color: NSColor(color))
                    SwipeAwareButton(action: tap) {
                        Color.clear.contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}

/// The Ringing pulse: a glowing border fading in and out. Core Animation, so it runs in the
/// window server for however long the Widget rings, at no cost to the app.
private struct RingingPulse: NSViewRepresentable {
    let color: NSColor

    final class PulseView: NSView {
        var color: NSColor = .white { didSet { style() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            style()
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let layer, layer.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.15
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }

        private func style() {
            layer?.cornerRadius = 22
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 4
            layer?.borderColor = color.cgColor
            layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        }
    }

    func makeNSView(context: Context) -> PulseView {
        let view = PulseView()
        view.color = color
        return view
    }

    func updateNSView(_ view: PulseView, context: Context) {
        if view.color != color { view.color = color }
    }
}

// MARK: Toast

/// The Toast listing every Timer and Pomodoro that is Ringing. Tapping one stops it and shows its
/// Page; ✕ silences them all, but each keeps pulsing until it's Tapped.
struct RingingToastView: View {
    @EnvironmentObject var model: AppModel
    let widgets: [WidgetConfig]
    /// Floating over other apps' windows (Plain display): see AgentToastView.
    var floating = false

    var body: some View {
        let accent = Theme.accent(for: widgets.first?.kind ?? .timer)
        HStack(spacing: 16) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 56, height: 56)
                .background(accent.opacity(0.18), in: Circle())
            VStack(spacing: 8) {
                ForEach(widgets) { widget in row(widget) }
            }
            TouchButton(symbol: "xmark", tint: Theme.secondaryText, size: 48) { model.timing.silenceAll() }
        }
        .padding(14)
        .frame(width: 760)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            if floating { shape.fill(Theme.tile) } else { shape.fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(accent.opacity(0.8), lineWidth: 1.5))
        .shadow(color: .black.opacity(floating ? 0.45 : 0.6), radius: floating ? 12 : 30, y: floating ? 4 : 0)
    }

    private func row(_ widget: WidgetConfig) -> some View {
        let countdown = model.timing.countdown(widget)
        let color = widget.kind == .pomodoro ? PomodoroWidget.color(countdown.phase) : Theme.accent(for: .timer)
        return Button { model.acknowledgeRinging(widget.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: widget.kind.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
                Text(Self.name(of: widget, countdown))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(Self.next(of: widget, countdown))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(color.opacity(0.2), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// "Tea", "Timer · 5 min", "Pomodoro · Work done".
    static func name(of widget: WidgetConfig, _ countdown: Countdown) -> String {
        if widget.kind == .pomodoro {
            let done = countdown.phase == .work ? "Work done" : "Break over"
            return "\(widget.title ?? "Pomodoro") · \(done)"
        }
        return widget.title ?? "Timer · \(Countdown.minutes(Int((countdown.duration / 60).rounded())))"
    }

    /// What a Tap does.
    static func next(of widget: WidgetConfig, _ countdown: Countdown) -> String {
        guard widget.kind == .pomodoro else { return "Tap to stop" }
        return countdown.phase == .work ? "Tap to start Break" : "Tap to start Work"
    }
}
