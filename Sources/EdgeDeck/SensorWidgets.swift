import EdgeSensors
import SwiftUI

extension HeatLevel {
    var color: Color {
        switch self {
        case .normal: Color(hex: "#30D158")
        case .warm: Color(hex: "#FF9F0A")
        case .hot: Color(hex: "#FF453A")
        }
    }
}

/// CPU and GPU temperatures. A Tap turns the card over between Celsius and Fahrenheit (the Unit flip),
/// for this Widget only, and it stays that way.
struct TemperatureWidget: View {
    @EnvironmentObject var sensors: SensorSampler
    @EnvironmentObject var model: AppModel
    let widget: WidgetConfig
    @State private var angle: Double

    init(widget: WidgetConfig) {
        self.widget = widget
        _angle = State(initialValue: widget.fahrenheit == true ? 180 : 0)
    }

    private var unit: TemperatureUnit { widget.fahrenheit == true ? .fahrenheit : .celsius }

    var body: some View {
        FlipCard(angle: angle, front: face(.celsius), back: face(.fahrenheit))
            .contentShape(Rectangle())
            .onTapGesture {
                let next = unit.toggled == .fahrenheit
                model.updateWidget(widget.id) { $0.fahrenheit = next }
            }
            .onChange(of: unit) { _, _ in
                withAnimation(.easeInOut(duration: 0.4)) { angle += 180 }
            }
    }

    private func face(_ unit: TemperatureUnit) -> some View {
        Tile(title: widget.title ?? "Temperature", symbol: WidgetKind.temperature.symbol, accent: Theme.accent(for: .temperature)) {
            if sensors.cpu == nil && sensors.gpu == nil {
                Text("Unavailable").foregroundStyle(Theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    reading("CPU", celsius: sensors.cpu, history: sensors.cpuHistory, unit: unit)
                    reading("GPU", celsius: sensors.gpu, history: sensors.gpuHistory, unit: unit)
                }
            }
        }
    }

    @ViewBuilder
    private func reading(_ label: String, celsius: Double?, history: [Double], unit: TemperatureUnit) -> some View {
        if let celsius {
            let color = HeatLevel(celsius: celsius).color
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                    BigValue(text: String(format: "%.0f", unit.value(fromCelsius: celsius)), unit: unit.symbol)
                }
                Sparkline(values: history.map { unit.value(fromCelsius: $0) }, maxValue: nil, color: color)
            }
        }
    }
}

/// Turns its content over around the vertical axis. The back shows the second view, the right way round.
struct FlipCard<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let turn = angle.truncatingRemainder(dividingBy: 360)
        ZStack {
            if turn > 90 && turn < 270 {
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                front
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

/// The speed of each fan. The icon stays still: an endless animation would cost more than the sensors do.
struct FansWidget: View {
    @EnvironmentObject var sensors: SensorSampler

    var body: some View {
        let accent = Theme.accent(for: .fans)
        Tile(title: "Fans", symbol: WidgetKind.fans.symbol, accent: accent) {
            if let fans = sensors.fans {
                if fans.isEmpty {
                    Text("No fans on this Mac").foregroundStyle(Theme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(fans.enumerated()), id: \.offset) { index, fan in
                            fanRow(fan, label: fans.count > 1 ? "Fan \(index + 1)" : nil, accent: accent)
                        }
                        Sparkline(values: sensors.fanHistory, maxValue: fans.map(\.maxRPM).max(), color: accent)
                    }
                }
            } else {
                Text("Unavailable").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func fanRow(_ fan: FanReading, label: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let label {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                if fan.isIdle {
                    Text("Idle")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    BigValue(text: String(format: "%.0f", fan.rpm), unit: "RPM")
                }
            }
            ProgressView(value: fan.fraction).tint(accent)
        }
    }
}
