import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var swipe: SwipeState
    @StateObject private var edit = EditState()

    private let spacing: CGFloat = 12
    static let toolbarHeight: CGFloat = 76

    var body: some View {
        let railVisible = model.guest.current != nil || model.player.isOpen
        let railWidth = railVisible ? CGFloat(model.config.display.railWidth) : 0
        let pages = model.pages
        let current = min(model.currentPageIndex, pages.count - 1)

        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            GeometryReader { geo in
                let width = geo.size.width
                HStack(spacing: 0) {
                    ForEach(pages) { page in
                        PageGridView(page: page, edit: edit)
                            .padding(spacing)
                            .frame(width: width, height: geo.size.height)
                    }
                }
                .offset(x: -CGFloat(current) * width + swipe.offset)
                .animation(.spring(response: 0.4, dampingFraction: 0.88), value: current)
                .contentShape(Rectangle())
                // Horizontal swipes change pages; widgets keep vertical swipes for
                // their own lists. Disabled while editing so drags move widgets.
                .simultaneousGesture(pageSwipe(width: width, pageCount: pages.count, current: current),
                                     including: model.editing ? .subviews : .all)
            }
            .clipped()
            .padding(.trailing, railWidth)
            .padding(.bottom, model.editing ? Self.toolbarHeight : 0)

            if pages.count > 1 && !model.editing {
                PageDots(count: pages.count, current: current)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 2)
            }

            if model.editing {
                EditToolbar(edit: edit)
                    .frame(height: Self.toolbarHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                if edit.showPalette { WidgetPalette(edit: edit) }
            }

            if !model.editing && !railVisible {
                EditLayoutButton { model.editing = true }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // Only on the Edge, and only with another Mac to switch to.
                if model.edgeConnected && !model.remoteHost.sources.isEmpty {
                    SourcePill().environmentObject(model.remoteHost)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            if model.remoteHost.chooserOpen && model.remoteHost.current == nil {
                SourceChooser().environmentObject(model.remoteHost)
            }

            if let id = model.cityEditorWidgetID, model.widget(id) != nil {
                CityEditor(widgetID: id)
            }

            if let id = model.launcherEditorWidgetID, model.widget(id) != nil {
                LauncherEditor(widgetID: id)
            }

            if model.ai.connectEditorOpen {
                ConnectEditor().environmentObject(model.ai)
            }

            if !model.accessibilityGranted {
                PermissionBanner(text: "EdgeDeck needs the \(AppModel.accessibilityName) permission for notifications, window moving, key presses and touch. Tap to open Settings.") {
                    model.openAccessibilitySettings()
                }
                .padding(.top, 20)
            } else if model.touch.status == .needsInputMonitoring {
                PermissionBanner(text: "Touch needs Input Monitoring: allow EdgeDeck in Settings, then touch works without moving the cursor. Tap to open.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                .padding(.top, 20)
            }

            if let message = edit.message ?? model.playerMessage ?? model.configStore.lastError {
                Text(message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(hex: "#FF453A").opacity(0.9), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, model.editing ? Self.toolbarHeight + 12 : 16)
            }

            // One Toast at a time; a Session that Needs you outranks a Notification.
            if !railVisible {
                if let session = model.ai.toastSessions.first {
                    AgentToastView(session: session, more: model.ai.toastSessions.count - 1)
                        .id(session.id)
                        .padding(.top, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let toast = model.notifications.toast {
                    ToastView(notification: toast)
                        .padding(.top, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            if !railVisible, let notice = model.keychainNotice {
                KeychainNoticeView(notice: notice, compact: false)
            }
        }
        .overlay(alignment: .trailing) {
            // During a Takeover only the Rail is visible, so the explanation takes its place.
            if railVisible {
                if let notice = model.keychainNotice {
                    KeychainNoticeView(notice: notice, compact: true).frame(width: railWidth)
                } else {
                    Rail().frame(width: railWidth)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.notifications.toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.ai.toastSessions)
        .environmentObject(model.stats)
        .environmentObject(model.runningApps)
        .environmentObject(model.nowPlaying)
        .environmentObject(model.weather)
        .environmentObject(model.calendar)
        .environmentObject(model.music)
        .environmentObject(model.ai)
        .preferredColorScheme(.dark)
    }

    private func pageSwipe(width: CGFloat, pageCount: Int, current: Int) -> some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { value in
                let dx = value.translation.width
                guard !swipe.heldByControl, abs(dx) > abs(value.translation.height) else { return }
                // Rubber-band past the first/last page.
                let atEdge = (current == 0 && dx > 0) || (current == pageCount - 1 && dx < 0)
                swipe.offset = atEdge ? dx / 4 : dx
            }
            .onEnded { value in
                guard !swipe.heldByControl else { return }
                let dx = value.predictedEndTranslation.width
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if horizontal && dx < -width * 0.2 {
                    model.showPage(current + 1)
                } else if horizontal && dx > width * 0.2 {
                    model.showPage(current - 1)
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { swipe.offset = 0 }
            }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.25))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel
    let notification: EdgeNotification

    var body: some View {
        let bringsToEdge = model.config.notifications.bringToEdgeOnTap.contains { $0.caseInsensitiveCompare(notification.app) == .orderedSame }
        HStack(spacing: 16) {
            NotificationCard(notification: notification)
            Button { model.open(notification) } label: {
                Label(bringsToEdge ? "Open here" : "Open", systemImage: bringsToEdge ? "rectangle.portrait.and.arrow.right" : "arrow.up.forward.app")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            TouchButton(symbol: "xmark", tint: Theme.secondaryText, size: 48) { model.notifications.dismissToast() }
        }
        .padding(14)
        .frame(width: 760)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.accent(for: .notifications).opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.6), radius: 30)
    }
}

/// The Toast for a Session that Needs you. It stays until the Session stops needing you
/// or ✕ is tapped.
struct AgentToastView: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    /// Other Sessions that also Need you.
    let more: Int
    /// Floating over other apps' windows (Plain display): a solid tile and a tighter shadow,
    /// since there's no Dashboard behind it to blur.
    var floating = false

    var body: some View {
        let color = Color(hex: session.state.color)
        HStack(spacing: 16) {
            Image(systemName: session.state.symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(color.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text([session.tool == .claude ? "Claude" : "OpenCode", session.profile].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if more > 0 {
                    Text("+\(more) more")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            // Bring to Edge: answer it here when the Mac's own screen isn't in front of you.
            // Not from a Remote view: this Mac (the Source) has no Edge to bring it to.
            if !model.remoteSource.isWatched {
            Button { model.bringToEdge(session) } label: {
                Label("Bring to Edge", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(color.opacity(0.35), in: Capsule())
            }
            .buttonStyle(PressableStyle())
            }
            Button { model.ai.focus(session) } label: {
                Label("Go to session", systemImage: "terminal")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            TouchButton(symbol: "xmark", tint: Theme.secondaryText, size: 48) { model.dismissAgentToast() }
        }
        .padding(14)
        .frame(width: 900)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            if floating { shape.fill(Theme.tile) } else { shape.fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(color.opacity(0.8), lineWidth: 1.5))
        .shadow(color: .black.opacity(floating ? 0.45 : 0.6), radius: floating ? 12 : 30, y: floating ? 4 : 0)
    }

    /// Room around a floating Toast for its shadow to fade out inside its window.
    static let floatingMargin: CGFloat = 32

    private var detail: String {
        let project = session.project.isEmpty ? "A session" : session.project
        if case .needsYou(let tool?) = session.state { return "\(project) — wants to run \(tool)" }
        return "\(project) — needs your input"
    }
}

/// On a Plain display or over a Remote view: this Mac's Toast, in its own floating panel over
/// whatever is on the Edge (on a Plain display, only Needs-you).
struct PlainDisplayToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let session = model.ai.toastSessions.first {
            AgentToastView(session: session, more: model.ai.toastSessions.count - 1, floating: true)
                .id(session.id)
                .padding(AgentToastView.floatingMargin)
                .fixedSize()
                .preferredColorScheme(.dark)
        } else if model.remoteHost.current != nil, let toast = model.notifications.toast {
            // Over a Remote view, this Mac's Notifications still show (on a Plain display they don't).
            ToastView(notification: toast)
                .padding(AgentToastView.floatingMargin)
                .fixedSize()
                .preferredColorScheme(.dark)
        }
    }
}

/// On a Plain display: a tab at the right edge, briefly, saying the Dashboard is a swipe away.
struct PullTab: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, height: 150)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.width < -40 { action() } })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// The Rail: controls on the right of the Edge during a Takeover (Guest app or Edge player).
struct Rail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if let guest = model.guest.current {
                AppIcon(image: guest.icon, size: 52).padding(.top, 8)
                Text(guest.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if model.answeringSession != nil {
                    // Claude Code's permission prompt, answered without the keyboard.
                    let orange = Color(hex: AgentState.needsYou(nil).color)
                    RailButton(title: "Yes", symbol: "checkmark", tint: Color(hex: "#30D158")) { model.answer("1") }
                    RailButton(title: "Always", symbol: "checkmark.seal", tint: orange) { model.answer("2") }
                    RailButton(title: "No", symbol: "xmark", tint: Color(hex: "#FF453A")) { model.answer("escape") }
                } else {
                    RailButton(title: "Activate", symbol: "hand.tap") { model.guest.activate() }
                }
                RailButton(title: "Send back", symbol: "arrow.uturn.backward") { model.guest.sendBack() }
                keyboardButtons
            } else if model.player.isOpen {
                AppIcon(image: model.player.source?.icon, size: 52).padding(.top, 8)
                Text(model.player.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                RailButton(title: "Play/Pause", symbol: "playpause.fill") { model.player.togglePlay() }
                RailButton(title: "Back to \(model.player.source?.localizedName ?? "browser")", symbol: "arrow.uturn.backward") {
                    model.sendBackVideo()
                }
                RailButton(title: "Close", symbol: "xmark") { model.player.close() }
            }
            // Stands in for the Needs-you Toast while the Dashboard is covered; ✕ doesn't hide it.
            if let session = model.ai.needingYou.first {
                let count = model.ai.needingYou.count
                RailButton(title: count > 1 ? "\(count) need you" : "Needs you", symbol: session.state.symbol,
                           tint: Color(hex: session.state.color)) { model.ai.focus(session) }
            }
            Divider().overlay(Color.white.opacity(0.15))
            // Newest notifications stay reachable while the dashboard is covered.
            ForEach(model.notifications.items.prefix(3)) { item in
                NotificationCard(notification: item, compact: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(Theme.tile)
    }
}

extension Rail {
    /// Grab keyboard: type into the Guest app with another Mac's keyboard (only Paired Macs
    /// running EdgeDeck nearby). With several, each button names its Mac.
    @ViewBuilder
    var keyboardButtons: some View {
        let keyboard = model.keyboard
        if let name = keyboard.grabbed, keyboard.waiting {
            // The other Mac is asking for its password before lending its keyboard.
            RailButton(title: "Waiting for \(name): answer there", symbol: "key.fill", tint: Color(hex: "#FF9F0A")) { keyboard.release() }
        } else if let name = keyboard.grabbed {
            RailButton(title: keyboard.paused ? "Keyboard paused" : "Release keyboard", symbol: "keyboard.chevron.compact.down",
                       tint: Color(hex: keyboard.paused ? "#FF9F0A" : "#0A84FF")) { keyboard.release() }
                .accessibilityLabel("Release \(name)'s keyboard")
        } else {
            ForEach(keyboard.lenders, id: \.self) { name in
                RailButton(title: keyboard.lenders.count > 1 ? "Grab \(name)'s keyboard" : "Grab keyboard", symbol: "keyboard") {
                    keyboard.grab(name)
                }
            }
        }
    }
}

/// Before macOS's password prompt for a Pairing secret saved by an earlier version: what's about
/// to happen and why, or Pair again instead. Full size over the Dashboard, or in the Rail.
struct KeychainNoticeView: View {
    @EnvironmentObject var model: AppModel
    let notice: AppModel.KeychainNotice
    let compact: Bool
    @State private var hideFromNowOn = false

    var body: some View {
        let text = "EdgeDeck keeps its Pairing with \(notice.name) in your keychain. An earlier version saved it, so macOS asks once before this one can use it. The dialog opens on this Mac's main screen: enter your password and choose Always Allow."
        Group {
            if compact {
                VStack(spacing: 12) {
                    Image(systemName: "key.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Color(hex: "#FF9F0A"))
                    Text("macOS will ask for your password").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    buttons
                }
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(maxHeight: .infinity)
                .background(Theme.tile)
            } else {
                ZStack {
                    Color.black.opacity(0.7).contentShape(Rectangle())
                    VStack(spacing: 16) {
                        Label("macOS will ask for your password", systemImage: "key.fill")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(text).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 820)
                        HStack(spacing: 14) { buttons }
                    }
                    .padding(28)
                    .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var buttons: some View {
        choice("Continue", fill: Theme.accent(for: .ai), text: .black) { notice.proceed() }
        choice("Pair again", fill: Theme.tile, text: .white) { notice.pairAgain() }
        choice("Cancel", fill: Theme.tile, text: Theme.secondaryText) {}
        Button { hideFromNowOn.toggle() } label: {
            Label("Don't show this again", systemImage: hideFromNowOn ? "checkmark.square.fill" : "square")
                .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(hideFromNowOn ? .white : Theme.secondaryText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func choice(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button {
            if hideFromNowOn { RemoteKeychain.noticeHidden = true }
            model.keychainNotice = nil
            action()
        } label: {
            Text(title)
                .font(.system(size: compact ? 14 : 17, weight: .bold, design: .rounded))
                .foregroundStyle(text)
                .padding(.horizontal, 20)
                .frame(maxWidth: compact ? .infinity : nil, minHeight: 50)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

struct RailButton: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(tint == .white ? Theme.tileRaised : tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PermissionBanner: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: "lock.shield")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(hex: "#FF453A").opacity(0.9), in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Enters edit mode. A labelled 48 pt pill with an invisible margin around it, so the
/// touch target is ~70 pt: the earlier 34 pt dimmed icon was too hard to hit.
struct EditLayoutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Edit", systemImage: "slider.horizontal.3")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                // Dimmed via colours: .opacity() on a Button stops it receiving clicks on macOS 27.
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(Theme.tileRaised.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// The dashboard at the Edge's size, scaled to fit the preview window, so it lays out exactly as on the Edge.
struct ScaledDashboard: View {
    let size: CGSize

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            DashboardView()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color.black)
    }
}
