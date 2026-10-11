import AppKit
import EventKit
import SwiftUI

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let color: Color
    let location: String?
    /// Zoom / Meet / Teams / Webex link found in the event, for the Join button.
    let joinURL: URL?

    func isOngoing(at date: Date) -> Bool { !isAllDay && start <= date && end > date }
}

/// Today's and the coming days' events from every calendar in macOS Calendar
/// (iCloud, Google, Exchange… whatever is set up in Internet Accounts).
final class CalendarModel: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [CalendarEvent] = []

    /// Widgets choose how many days they show, up to this.
    static let maxDays = 7

    private let store = EKEventStore()

    func start() {
        updateAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.reload() }
        // Every minute keeps "in 5 min" current and rolls the list over at midnight.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, error in
            if let error { NSLog("EdgeDeck: calendar access request failed: \(error)") }
            DispatchQueue.main.async {
                self?.updateAccess()
                self?.reload()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    func open(_ event: CalendarEvent) {
        // Calendar's own URL scheme shows the event; fall back to just opening the app.
        if let id = event.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            AppLocator.open("com.apple.iCal")
        }
    }

    private func updateAccess() {
        let next: Access = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
        if next != access { access = next }
    }

    private func reload() {
        updateAccess()
        guard access == .granted else {
            if !events.isEmpty { events = [] }
            return
        }
        let today = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: Self.maxDays, to: today) else { return }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { $0.status != .canceled && !Self.declined($0) }
            // By day, all-day events first, then by start time.
            .sorted {
                let cal = Calendar.current
                return (cal.startOfDay(for: $0.startDate), $0.isAllDay ? 0 : 1, $0.startDate)
                    < (cal.startOfDay(for: $1.startDate), $1.isAllDay ? 0 : 1, $1.startDate)
            }
            .map { event in
                CalendarEvent(
                    id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    eventIdentifier: event.eventIdentifier,
                    title: event.title?.isEmpty == false ? event.title! : "Untitled",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    calendar: event.calendar.title,
                    color: Color(nsColor: event.calendar.color ?? .systemBlue),
                    location: event.location?.isEmpty == false ? event.location : nil,
                    joinURL: Self.meetingURL(in: event))
            }
        if next != events { events = next }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static let meetingPattern = try! NSRegularExpression(
        pattern: #"https://[\w.-]*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|webex\.com/(meet|join|[\w.-]+/j\.php))[^\s<>"')]*"#,
        options: [.caseInsensitive])

    private static func meetingURL(in event: EKEvent) -> URL? {
        let sources = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in sources {
            let range = NSRange(text.startIndex..., in: text)
            if let match = meetingPattern.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}

// MARK: Widget

struct CalendarWidget: View {
    @EnvironmentObject var calendar: CalendarModel
    let widget: WidgetConfig

    private let rowHeight: CGFloat = 66
    private let spacing: CGFloat = 8

    var body: some View {
        Tile(title: widget.title ?? "Calendar", symbol: WidgetKind.calendar.symbol, accent: Theme.accent(for: .calendar)) {
            switch calendar.access {
            case .unknown:
                AccessPrompt(symbol: "calendar.badge.plus", message: "Show your events here", button: "Allow Calendar Access") { calendar.requestAccess() }
            case .denied:
                AccessPrompt(symbol: "calendar.badge.exclamationmark", message: "Calendar access is off", button: "Open Privacy Settings") { calendar.openPrivacySettings() }
            case .granted:
                TimelineView(.everyMinute) { context in
                    let events = visibleEvents(now: context.date)
                    if events.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.system(size: 34))
                            Text(days == 1 ? "Nothing else today" : "No upcoming events").font(.system(size: 16, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geo in
                            let perPage = max(1, Int((geo.size.height - 44 + spacing) / (rowHeight + spacing)))
                            let fitsAll = CGFloat(events.count) * (rowHeight + spacing) - spacing <= geo.size.height
                            let highlighted = events.first { !$0.isAllDay && $0.end > context.date }?.id
                            Pager(items: events, perPage: fitsAll ? events.count : perPage) { page in
                                VStack(spacing: spacing) {
                                    ForEach(page) { event in
                                        EventRow(event: event, now: context.date, highlighted: event.id == highlighted, height: rowHeight)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var days: Int { min(max(widget.days ?? 2, 1), CalendarModel.maxDays) }

    /// Events not yet over within the widget's day range, in its chosen calendars.
    private func visibleEvents(now: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now)) ?? now
        let names = widget.calendars.map { Set($0.map { $0.lowercased() }) }
        return calendar.events.filter { event in
            event.end > now && event.start < end && (names?.contains(event.calendar.lowercased()) ?? true)
        }
    }
}

private struct AccessPrompt: View {
    let symbol: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Theme.secondaryText)
            Text(message).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.accent(for: .calendar), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EventRow: View {
    @EnvironmentObject var calendar: CalendarModel
    let event: CalendarEvent
    let now: Date
    let highlighted: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Button { calendar.open(event) } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let day = dayLabel {
                            Text(day).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent(for: .calendar))
                        }
                        Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if !event.isAllDay, dayLabel == nil {
                            Text(event.end.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                                .monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                    .frame(width: 72, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4)
                        .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(highlighted ? Theme.accent(for: .calendar) : Theme.secondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if let url = event.joinURL, !event.isAllDay {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(highlighted ? .black : .white)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(highlighted ? Color(hex: "#30D158") : Theme.tile, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent(for: .calendar).opacity(0.7), lineWidth: 1.5)
            }
        }
    }

    /// "Tomorrow" / weekday for events not today.
    private var dayLabel: String? {
        let cal = Calendar.current
        if cal.isDateInToday(event.start) || (event.isAllDay && event.start < now) { return nil }
        if cal.isDateInTomorrow(event.start) { return "TOMORROW" }
        return event.start.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    private var subtitle: String {
        var parts: [String] = []
        if event.isOngoing(at: now) {
            parts.append("Now · \(Self.duration(event.end.timeIntervalSince(now))) left")
        } else if !event.isAllDay, event.start > now, event.start.timeIntervalSince(now) < 12 * 3600, Calendar.current.isDateInToday(event.start) {
            parts.append("In \(Self.duration(event.start.timeIntervalSince(now)))")
        }
        parts.append(event.location.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? event.calendar)
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
