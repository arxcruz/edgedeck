import SwiftUI

final class TimingEditorState: ObservableObject {
    /// The title being typed, nil when not editing it.
    @Published var titleDraft: String?
}

/// The Editor of a Timer (its preset chips) or a Pomodoro (its lengths and Rounds), plus the
/// title and the Ringing sound of either.
struct TimingEditor: View {
    @EnvironmentObject var model: AppModel
    let widgetID: UUID
    @StateObject private var state = TimingEditorState()
    @FocusState private var titleFocused: Bool

    static let presetChoices = [1, 2, 3, 5, 10, 15, 20, 25, 30, 45, 60, 90, 120]
    /// More chips than this don't fit a Timer's default size.
    static let maxPresets = 6

    var body: some View {
        let widget = model.widget(widgetID)
        let kind = widget?.kind ?? .timer
        let accent = Theme.accent(for: kind)

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol).foregroundStyle(accent)
                Text(kind.displayName).font(.system(size: 20, weight: .bold, design: .rounded))
                titleField(current: widget?.title ?? "", placeholder: kind.displayName, accent: accent)
                Spacer()
                Button { model.timingEditorWidgetID = nil } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 110, height: 44)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            if let widget {
                if kind == .timer {
                    presets(widget, accent: accent)
                } else {
                    pomodoro(widget.pomodoro ?? PomodoroLengths(), accent: accent)
                }
                sounds(widget.sound ?? Chime.defaultSound, accent: accent)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    // MARK: Timer

    private func presets(_ widget: WidgetConfig, accent: Color) -> some View {
        let chosen = widget.presets ?? WidgetConfig.defaultPresets
        return section("Chips", detail: "Up to \(Self.maxPresets); tapping one on the Timer starts it") {
            ForEach(Self.presetChoices, id: \.self) { minutes in
                let selected = chosen.contains(minutes)
                choice(Countdown.minutes(minutes), selected: selected, multi: true, accent: accent,
                       enabled: selected || chosen.count < Self.maxPresets) {
                    model.updateWidget(widgetID) { widget in
                        var list = widget.presets ?? WidgetConfig.defaultPresets
                        if let index = list.firstIndex(of: minutes) {
                            // A Timer always keeps one chip.
                            if list.count > 1 { list.remove(at: index) }
                        } else if list.count < Self.maxPresets {
                            list.append(minutes)
                        }
                        widget.presets = list.sorted()
                    }
                }
            }
        }
    }

    // MARK: Pomodoro

    private func pomodoro(_ lengths: PomodoroLengths, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            lengthRow("Work", [15, 20, 25, 30, 45, 50, 60], lengths.work, accent: accent) { $0.work = $1 }
            lengthRow("Break", [3, 5, 10, 15], lengths.shortBreak, accent: accent) { $0.shortBreak = $1 }
            lengthRow("Last Break of the Cycle", [10, 15, 20, 30], lengths.longBreak, accent: accent) { $0.longBreak = $1 }
            section("Rounds per Cycle", detail: nil) {
                ForEach([2, 3, 4, 5, 6], id: \.self) { rounds in
                    choice("\(rounds)", selected: lengths.rounds == rounds, multi: false, accent: accent) {
                        model.updateWidget(widgetID) { widget in
                            var lengths = widget.pomodoro ?? PomodoroLengths()
                            lengths.rounds = rounds
                            widget.pomodoro = lengths
                        }
                    }
                }
            }
        }
    }

    private func lengthRow(_ title: String, _ choices: [Int], _ current: Int, accent: Color,
                           set: @escaping (inout PomodoroLengths, Int) -> Void) -> some View {
        section(title, detail: nil) {
            ForEach(choices, id: \.self) { minutes in
                choice(Countdown.minutes(minutes), selected: current == minutes, multi: false, accent: accent) {
                    model.updateWidget(widgetID) { widget in
                        var lengths = widget.pomodoro ?? PomodoroLengths()
                        set(&lengths, minutes)
                        widget.pomodoro = lengths
                    }
                }
            }
        }
    }

    // MARK: Sound

    /// Picking a sound plays it once.
    private func sounds(_ current: String, accent: Color) -> some View {
        section("Sound when Ringing", detail: "Plays three times at the Mac's volume") {
            ForEach(Chime.sounds, id: \.self) { name in
                choice(name, selected: current == name, multi: false, accent: accent) {
                    model.updateWidget(widgetID) { $0.sound = name == Chime.defaultSound ? nil : name }
                    model.timing.chime.preview(name)
                }
            }
        }
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                if let detail {
                    Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    /// Editor convention: multi-choice ⊕ → ✓, single-choice ○ → ✓, in the Widget kind's colour.
    private func choice(_ title: String, selected: Bool, multi: Bool, accent: Color, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : multi ? "plus.circle" : "circle").font(.system(size: 18))
            }
            .foregroundStyle(selected ? Color.black : enabled ? Color.white : Theme.secondaryText)
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(selected ? accent : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    /// The title, edited in place as in the Launcher editor: tap to type on the Mac keyboard,
    /// then Save or Cancel. Empty means the Widget shows its kind's name.
    @ViewBuilder
    private func titleField(current: String, placeholder: String, accent: Color) -> some View {
        TextField("Title (\(placeholder))", text: Binding(get: { state.titleDraft ?? current }, set: { state.titleDraft = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(width: 300, height: 44)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(titleFocused ? accent : .clear, lineWidth: 2))
            .focused($titleFocused)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if state.titleDraft == nil { state.titleDraft = current }
                model.beginTyping()
                DispatchQueue.main.async { titleFocused = true }
            })
            .onSubmit { finishTitle(save: true) }
        if state.titleDraft != nil {
            Button { finishTitle(save: false) } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.tileRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            Button { finishTitle(save: true) } label: {
                Text("Save")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func finishTitle(save: Bool) {
        if save, let draft = state.titleDraft?.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.updateWidget(widgetID) { $0.title = draft.isEmpty ? nil : draft }
        }
        state.titleDraft = nil
        titleFocused = false
        model.endTyping()
    }
}
