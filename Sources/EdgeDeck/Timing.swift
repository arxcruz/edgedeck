import AppKit
import Combine

/// The countdown of one Timer or Pomodoro Widget. A running one is kept as when it ends, not as
/// how much is left, so it keeps real time across restarts and sleep (and rings late, on wake,
/// if it ran out meanwhile).
struct Countdown: Codable, Equatable {
    /// A Pomodoro's phase. `rest` is the Break ("break" is a Swift keyword).
    enum Phase: String, Codable { case work, rest }

    enum State: Equatable {
        case ready
        case running(endsAt: Date)
        case paused(left: TimeInterval)
        case ringing
    }

    /// Seconds the countdown started from. A Timer starts it again from a Tap on its digits.
    var duration: TimeInterval
    var endsAt: Date?
    /// Paused: what was left.
    var remaining: TimeInterval?
    var ringingSince: Date?
    /// Pomodoro only.
    var phase: Phase = .work
    /// Pomodoro only: the Round within the Cycle, from 0.
    var round = 0

    var state: State {
        if ringingSince != nil { return .ringing }
        if let endsAt { return .running(endsAt: endsAt) }
        if let remaining { return .paused(left: remaining) }
        return .ready
    }

    var isRunning: Bool { endsAt != nil && ringingSince == nil }

    /// Seconds left at `now`.
    func left(at now: Date) -> TimeInterval {
        switch state {
        case .ready: duration
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        case .paused(let left): left
        case .ringing: 0
        }
    }

    /// "4:59", "1:02:03": whole seconds rounded up, so it never shows 0:00 before Ringing.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "5m", "1h", "1h30", where there's little room.
    static func shortMinutes(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)"
    }

    /// "5 min", "1 h", "1 h 30".
    static func minutes(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
    }
}

/// Every Timer's and Pomodoro's countdown, Ringing, and their sound. Countdowns are kept in
/// timers.json beside config.json, not in it: they change on every Tap, the settings don't.
final class TimingModel: ObservableObject {
    @Published private(set) var countdowns: [UUID: Countdown] = [:]
    /// Ringing Widgets whose Toast was closed with ✕: silent, but they pulse until Tapped.
    @Published private(set) var silenced: Set<UUID> = []

    /// The Timer and Pomodoro Widgets in the config, by id; set by AppModel.
    var widgets: [UUID: WidgetConfig] = [:] {
        didSet { prune() }
    }

    private let url = ConfigStore.directory.appendingPathComponent("timers.json")
    private var nextEnd: Timer?
    private var wakeObserver: NSObjectProtocol?
    let chime = Chime()

    func start() {
        load()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkEnds()
        }
        checkEnds()
    }

    // MARK: Reading

    /// The Widget's countdown; ready at its first length when it has never run.
    func countdown(_ widget: WidgetConfig) -> Countdown {
        if let stored = countdowns[widget.id] {
            // A ready Pomodoro follows its lengths as they're edited.
            guard widget.kind == .pomodoro, stored.state == .ready else { return stored }
            var ready = stored
            ready.duration = Self.length(of: stored.phase, round: stored.round, widget.pomodoro ?? PomodoroLengths())
            return ready
        }
        switch widget.kind {
        case .pomodoro:
            return Countdown(duration: Self.length(of: .work, round: 0, widget.pomodoro ?? PomodoroLengths()))
        default:
            return Countdown(duration: TimeInterval((widget.presets ?? WidgetConfig.defaultPresets).first ?? 5) * 60)
        }
    }

    /// Ringing Widgets, the earliest first.
    var ringing: [WidgetConfig] {
        countdowns.compactMap { id, countdown in countdown.ringingSince.map { (id, $0) } }
            .sorted { $0.1 < $1.1 }
            .compactMap { widgets[$0.0] }
    }

    /// What the Toast lists: Ringing minus what ✕ silenced.
    var toastRinging: [WidgetConfig] { ringing.filter { !silenced.contains($0.id) } }

    static func length(of phase: Countdown.Phase, round: Int, _ lengths: PomodoroLengths) -> TimeInterval {
        switch phase {
        case .work: TimeInterval(lengths.work * 60)
        case .rest: TimeInterval((round >= lengths.rounds - 1 ? lengths.longBreak : lengths.shortBreak) * 60)
        }
    }

    // MARK: Timer

    /// Starts a Timer from `minutes`, whatever it was doing.
    func start(_ id: UUID, minutes: Int) {
        let duration = TimeInterval(minutes * 60)
        change(id) { $0 = Countdown(duration: duration, endsAt: Date().addingTimeInterval(duration)) }
    }

    /// A Tap on the digits: start (Timer: its last length; Pomodoro: the phase it's on), pause
    /// or resume, or stop Ringing.
    func tap(_ widget: WidgetConfig) {
        let current = countdown(widget)
        switch current.state {
        case .ready:
            change(widget.id) {
                $0 = current
                $0.endsAt = Date().addingTimeInterval(current.duration)
            }
        case .running(let endsAt):
            change(widget.id) {
                $0.endsAt = nil
                $0.remaining = max(1, endsAt.timeIntervalSinceNow)
            }
        case .paused(let left):
            change(widget.id) {
                $0.remaining = nil
                $0.endsAt = Date().addingTimeInterval(left)
            }
        case .ringing:
            acknowledge(widget.id)
        }
    }

    /// +1 min on a running Timer.
    func addMinute(_ id: UUID) {
        change(id) {
            guard let endsAt = $0.endsAt else { return }
            $0.endsAt = endsAt.addingTimeInterval(60)
            $0.duration += 60
        }
    }

    /// Back to ready, keeping a Timer's length (a Pomodoro: see `resetCycle`).
    func reset(_ id: UUID) {
        change(id) { $0 = Countdown(duration: $0.duration) }
    }

    // MARK: Pomodoro

    /// The next phase, ready to start with a Tap.
    func skip(_ widget: WidgetConfig) {
        let next = Self.next(after: countdown(widget), widget.pomodoro ?? PomodoroLengths())
        change(widget.id) { $0 = next }
    }

    /// Back to the first Round's Work, ready.
    func resetCycle(_ id: UUID) {
        countdowns[id] = nil
        save()
        checkEnds()
    }

    private static func next(after current: Countdown, _ lengths: PomodoroLengths) -> Countdown {
        var next = Countdown(duration: 0)
        switch current.phase {
        case .work:
            next.phase = .rest
            next.round = current.round
        case .rest:
            next.phase = .work
            next.round = current.round + 1 >= lengths.rounds ? 0 : current.round + 1
        }
        next.duration = length(of: next.phase, round: next.round, lengths)
        return next
    }

    // MARK: Ringing

    /// Tapping something Ringing: a Timer goes back to ready, a Pomodoro starts its next phase.
    func acknowledge(_ id: UUID) {
        guard let widget = widgets[id], let current = countdowns[id], current.ringingSince != nil else { return }
        silenced.remove(id)
        if widget.kind == .pomodoro {
            var next = Self.next(after: current, widget.pomodoro ?? PomodoroLengths())
            next.endsAt = Date().addingTimeInterval(next.duration)
            change(id) { $0 = next }
        } else {
            change(id) { $0 = Countdown(duration: current.duration) }
        }
        if toastRinging.isEmpty { chime.stop() }
    }

    /// ✕ on the Toast: everything Ringing goes quiet and leaves the Toast, but keeps pulsing.
    func silenceAll() {
        silenced.formUnion(ringing.map(\.id))
        chime.stop()
    }

    // MARK: Keeping time

    private func change(_ id: UUID, _ update: (inout Countdown) -> Void) {
        guard let widget = widgets[id] else { return }
        var countdown = countdown(widget)
        update(&countdown)
        countdowns[id] = countdown
        save()
        checkEnds()
    }

    /// Rings whatever has run out and arms a timer for the next end.
    private func checkEnds() {
        nextEnd?.invalidate()
        let now = Date()
        var rang: [UUID] = []
        for (id, countdown) in countdowns where countdown.isRunning {
            guard let endsAt = countdown.endsAt, endsAt <= now else { continue }
            countdowns[id]?.endsAt = nil
            countdowns[id]?.ringingSince = endsAt
            rang.append(id)
        }
        if let first = rang.first {
            save()
            chime.play(widgets[first]?.sound)
        }
        guard let soonest = countdowns.values.filter(\.isRunning).compactMap(\.endsAt).min() else { return }
        let timer = Timer(fire: soonest, interval: 0, repeats: false) { [weak self] _ in self?.checkEnds() }
        RunLoop.main.add(timer, forMode: .common)
        nextEnd = timer
    }

    /// Forgets countdowns of Widgets that were removed.
    private func prune() {
        guard !widgets.isEmpty else { return }
        let gone = countdowns.keys.filter { widgets[$0] == nil }
        guard !gone.isEmpty else { return }
        gone.forEach { countdowns[$0] = nil }
        silenced.subtract(gone)
        save()
        if toastRinging.isEmpty { chime.stop() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Countdown].self, from: data) else { return }
        countdowns = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: countdowns.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(stored).write(to: url, options: .atomic)
    }
}

/// The sound of Ringing: a macOS system sound, three times, at the system volume (so a muted
/// Mac stays silent).
final class Chime: NSObject, NSSoundDelegate {
    static let defaultSound = "Glass"
    static let repeats = 3

    /// The system sounds to choose from, by name.
    static let sounds: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let found = names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
        return found.isEmpty ? [defaultSound] : found
    }()

    private var sound: NSSound?
    private var left = 0

    func play(_ name: String?) {
        stop()
        left = Self.repeats
        sound = Self.load(name)
        sound?.delegate = self
        playOnce()
    }

    /// Plays a sound once, e.g. when it's picked in the Editor.
    func preview(_ name: String) {
        stop()
        left = 1
        sound = Self.load(name)
        sound?.delegate = self
        playOnce()
    }

    func stop() {
        left = 0
        sound?.delegate = nil
        sound?.stop()
        sound = nil
    }

    private func playOnce() {
        guard left > 0, let sound else { return }
        left -= 1
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        guard finished, sound === self.sound, left > 0 else { return }
        // A short gap, so three chimes read as a ring rather than one long sound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, sound === self.sound else { return }
            self.playOnce()
        }
    }

    private static func load(_ name: String?) -> NSSound? {
        let name = name ?? defaultSound
        let path = "/System/Library/Sounds/\(name).aiff"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: NSSound.Name(defaultSound))?.copy() as? NSSound
    }
}
