import AppKit
import SwiftUI

/// Live Claude Code / OpenCode sessions with their state, plus Claude plan limits
/// and OpenCode's usage today.
struct AIWidget: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AIModel
    let widget: WidgetConfig

    private let rowHeight: CGFloat = 64
    private let spacing: CGFloat = 8

    private var visible: Bool {
        model.currentPage.widgets.contains { $0.id == widget.id } && model.guest.current == nil && !model.player.isOpen
    }

    var body: some View {
        Tile(title: widget.title ?? "AI Agents", symbol: WidgetKind.ai.symbol, accent: Theme.accent(for: .ai)) {
            VStack(spacing: 10) {
                if ai.needsConnect && !ai.profiles.isEmpty { connectBanner }
                if !ai.claudeUsage.isEmpty || (ai.openCodeUsage?.messages ?? 0) > 0 { usage }
                sessions
            }
        }
        .onAppear { ai.setVisible(widget.id, visible) }
        .onChange(of: visible) { _, now in ai.setVisible(widget.id, now) }
        .onDisappear { ai.setVisible(widget.id, false) }
    }

    private var connectBanner: some View {
        Button { ai.connectEditorOpen = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus").font(.system(size: 18, weight: .semibold))
                Text("Connect Claude for plan usage and tool details")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("Connect").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.accent(for: .ai), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(Theme.accent(for: .ai).opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var usage: some View {
        VStack(spacing: 6) {
            ForEach(ai.claudeUsage, id: \.profile) { u in
                HStack(spacing: 10) {
                    AppIcon(image: AppLocator.icon(for: "com.anthropic.claudefordesktop"), size: 22)
                    Text(ai.claudeUsage.count > 1 || ai.profiles.count > 1 ? u.profile : "Claude")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(width: 74, alignment: .leading)
                        .lineLimit(1)
                    LimitBar(label: "5h", percent: u.fiveHour, resets: u.fiveHourResets)
                    LimitBar(label: "Week", percent: u.sevenDay, resets: u.sevenDayResets)
                }
            }
            if let oc = ai.openCodeUsage, oc.messages > 0 {
                HStack(spacing: 10) {
                    OpenCodeIcon(size: 22)
                    Text("OpenCode").font(.system(size: 14, weight: .bold, design: .rounded)).frame(width: 74, alignment: .leading)
                    Text("Today  \(Self.tokens(oc.tokens)) tokens · \(oc.messages) replies" + (model.config.ai.showCost ? String(format: " · $%.2f", oc.cost) : ""))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Theme.tileRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var sessions: some View {
        if ai.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 30))
                Text("No agents running").font(.system(size: 16, weight: .medium, design: .rounded))
                Text("Claude Code and OpenCode sessions show up here").font(.system(size: 13, design: .rounded))
            }
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let fitsAll = CGFloat(ai.sessions.count) * (rowHeight + spacing) - spacing <= geo.size.height
                let perPage = max(1, Int((geo.size.height - 44 + spacing) / (rowHeight + spacing)))
                Pager(items: ai.sessions, perPage: fitsAll ? ai.sessions.count : perPage) { page in
                    VStack(spacing: spacing) {
                        ForEach(page) { AgentRow(session: $0, height: rowHeight) }
                    }
                }
            }
        }
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}

private struct LimitBar: View {
    let label: String
    let percent: Double?
    let resets: Date?

    var body: some View {
        let value = (percent ?? 0) / 100
        let color = Theme.load(value)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.secondaryText)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").foregroundStyle(.white)
                Spacer(minLength: 0)
                if let resets, resets > Date() {
                    Text("resets \(resets.formatted(date: Calendar.current.isDateInToday(resets) ? .omitted : .abbreviated, time: .shortened))")
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(color).frame(width: max(6, geo.size.width * min(value, 1)))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AIModel
    let session: AgentSession
    let height: CGFloat

    var body: some View {
        let color = Color(hex: session.state.color)
        let needsYou = session.state.needsYou
        Button { ai.focus(session) } label: {
            HStack(spacing: 12) {
                Group {
                    if session.tool == .claude {
                        AppIcon(image: AppLocator.icon(for: "com.anthropic.claudefordesktop"), size: 36)
                    } else {
                        OpenCodeIcon(size: 36)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.project.isEmpty ? "—" : session.project)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        if let profile = session.profile {
                            Text(profile)
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Image(systemName: session.state.symbol).font(.system(size: 13, weight: .bold))
                    Text(session.state.label).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                }
                .foregroundStyle(session.state == .idle ? Theme.secondaryText : color)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(color.opacity(session.state == .idle ? 0.12 : 0.2), in: Capsule())
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(Self.elapsed(since: session.since, now: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if needsYou {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let title = session.title, !title.isEmpty { parts.append(title) }
        if let agent = session.agent, !agent.isEmpty { parts.append(agent) }
        if case .needsYou(let tool?) = session.state { parts.append("approve \(tool)") }
        if let context = session.contextPercent { parts.append("context \(Int(context.rounded()))%") }
        if model.config.ai.showCost, let cost = session.cost {
            // Claude on a plan isn't billed per token: its cost is an estimate at API prices.
            parts.append((session.tool == .claude ? "≈" : "") + String(format: "$%.2f", cost))
        }
        if parts.isEmpty { parts.append(session.tool == .claude ? "Claude Code" : "OpenCode") }
        return parts.joined(separator: " · ")
    }

    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        switch s {
        case ..<10: return "now"
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        default: return "\(s / 86_400)d"
        }
    }
}

/// OpenCode has no app icon to borrow; a terminal-style badge stands in.
private struct OpenCodeIcon: View {
    let size: CGFloat

    var body: some View {
        Text("oc")
            .font(.system(size: size * 0.42, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#1C1C1E")], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.white.opacity(0.2)))
    }
}

// MARK: Connect editor

/// Full-screen: every Claude profile found and OpenCode, what's installed in each, and
/// connect / disconnect buttons.
struct ConnectEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: WidgetKind.ai.symbol).foregroundStyle(Theme.accent(for: .ai))
                Text("Connect agents").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Claude Code: adds EdgeDeck's statusline + hooks to each profile's settings.json (backed up first). OpenCode: adds a small plugin. Nothing leaves this Mac.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                Spacer()
                Button {
                    ai.connectEditorOpen = false
                    ai.connectionMessage = nil
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 110, height: 44)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            if ai.profiles.isEmpty {
                Text("No Claude Code profiles found (looked for ~/.claude and ~/.claude-*).")
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 14) {
                Button { model.addClaudeFolder() } label: {
                    Label("Add folder…", systemImage: "folder.badge.plus")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Theme.tileRaised, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                Text("Using CLAUDE_CONFIG_DIR? Start a session once and it appears here, or tap Add folder… (opens on the Mac's screen).")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(ai.profiles) { profile in
                    ProfileCard(profile: profile, status: ai.connectionStatus[profile.key])
                }
                if let status = ai.openCodeStatus { OpenCodeCard(status: status) }
            }

            if !ai.hiddenProfiles.isEmpty {
                HStack(spacing: 10) {
                    Text("Hidden:")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                    ForEach(ai.hiddenProfiles) { profile in
                        Button { model.showProfile(profile) } label: {
                            Label("Show \(profile.name)", systemImage: "eye")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(Theme.tileRaised, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }

            toastSetting
            costSetting

            if let message = ai.connectionMessage {
                Text(message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.tileRaised, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear { ai.refreshProfiles() }
    }

    // Settings here are app-wide, not per Widget: they're about Sessions, so two AI Widgets can't disagree.

    private var toastSetting: some View {
        setting(on: model.config.ai.toastOnNeedsYou, symbol: AgentState.needsYou(nil).symbol, color: AgentState.needsYou(nil).color,
                title: "Toast when a Session needs you", detail: "Claude Code profiles and OpenCode must be connected for this.") {
            $0.ai.toastOnNeedsYou.toggle()
        }
    }

    private var costSetting: some View {
        setting(on: model.config.ai.showCost, symbol: "dollarsign.circle.fill", color: "#30D158",
                title: "Show cost", detail: "Each Session's cost so far. Claude's (≈) is an estimate at API prices; connected profiles only.") {
            $0.ai.showCost.toggle()
        }
    }

    private func setting(on: Bool, symbol: String, color: String, title: String, detail: String,
                         toggle: @escaping (inout AppConfig) -> Void) -> some View {
        Button {
            model.configStore.update(toggle)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(hex: color))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                Text(on ? "On" : "Off")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? .black : .white)
                    .frame(width: 88, height: 44)
                    .background(on ? Theme.accent(for: .ai) : Theme.tile, in: Capsule())
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct ProfileCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AIModel
    let profile: ClaudeProfile
    let status: ClaudeConnection.Status?

    var body: some View {
        let connected = status?.connected ?? false
        HStack(spacing: 14) {
            AppIcon(image: AppLocator.icon(for: "com.anthropic.claudefordesktop"), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(profile.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    Check(label: "Statusline", on: status?.statusline ?? false)
                    Check(label: "Hooks", on: status?.hooks ?? false)
                    if status?.settingsExists == false { Check(label: "no settings.json yet", on: false) }
                }
            }
            Spacer(minLength: 8)
            Button { model.hideProfile(profile) } label: {
                pill(status?.hooks == true || status?.statusline == true ? "Disconnect & hide" : "Hide", fill: Theme.tile, text: Theme.secondaryText)
            }
            .buttonStyle(PressableStyle())
            if connected {
                Button { ai.disconnect(profile) } label: { pill("Disconnect", fill: Theme.tile, text: .white) }
                    .buttonStyle(PressableStyle())
            } else {
                Button { ai.connect(profile) } label: {
                    pill(status?.statusline == true || status?.hooks == true ? "Reconnect" : "Connect", fill: Theme.accent(for: .ai), text: .black)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(connected ? Color(hex: "#30D158").opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private func pill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(text)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
    }
}

private struct OpenCodeCard: View {
    @EnvironmentObject var ai: AIModel
    let status: OpenCodeConnection.Status

    var body: some View {
        let connected = status == .connected
        HStack(spacing: 14) {
            OpenCodeIcon(size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenCode").font(.system(size: 17, weight: .bold, design: .rounded))
                Text(OpenCodeConnection.pluginURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Check(label: status == .outdated ? "Plugin (outdated)" : "Plugin", on: connected)
            }
            Spacer(minLength: 8)
            if connected {
                Button { ai.disconnectOpenCode() } label: { pill("Disconnect", fill: Theme.tile, text: .white) }
                    .buttonStyle(PressableStyle())
            } else {
                Button { ai.connectOpenCode() } label: {
                    pill(status == .outdated ? "Reconnect" : "Connect", fill: Theme.accent(for: .ai), text: .black)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(connected ? Color(hex: "#30D158").opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private func pill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(text)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
    }
}

private struct Check: View {
    let label: String
    let on: Bool

    var body: some View {
        Label(label, systemImage: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(on ? Color(hex: "#30D158") : Theme.secondaryText)
    }
}
