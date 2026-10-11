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

            if !model.accessibilityGranted { PermissionBanner().padding(.top, 20) }

            if let message = edit.message ?? model.playerMessage ?? model.configStore.lastError {
                Text(message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(hex: "#FF453A").opacity(0.9), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, model.editing ? Self.toolbarHeight + 12 : 16)
            }

            if let toast = model.notifications.toast, !railVisible {
                ToastView(notification: toast)
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            if railVisible { Rail().frame(width: railWidth) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.notifications.toast)
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
                guard abs(dx) > abs(value.translation.height) else { return }
                // Rubber-band past the first/last page.
                let atEdge = (current == 0 && dx > 0) || (current == pageCount - 1 && dx < 0)
                swipe.offset = atEdge ? dx / 4 : dx
            }
            .onEnded { value in
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
                RailButton(title: "Activate", symbol: "hand.tap") { model.guest.activate() }
                RailButton(title: "Send back", symbol: "arrow.uturn.backward") { model.guest.sendBack() }
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

struct RailButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.openAccessibilitySettings() } label: {
            Label("EdgeDeck needs Accessibility access for notifications, window moving and key presses. Tap to open Settings.",
                  systemImage: "lock.shield")
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
