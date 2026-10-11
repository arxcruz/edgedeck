import SwiftUI

/// Transient state for edit mode (which widget is being dragged, palette, etc).
final class EditState: ObservableObject {
    enum Mode { case move, resize }

    @Published var dragging: UUID?
    @Published var mode: Mode = .move
    @Published var translation: CGSize = .zero
    /// EDGEDECK_SNAPSHOT_PALETTE=1 (with EDGEDECK_SNAPSHOT_EDIT=1) starts with it open, for snapshots.
    @Published var showPalette = ProcessInfo.processInfo.environment["EDGEDECK_SNAPSHOT_PALETTE"] == "1"
    @Published var confirmDeletePage: UUID?
    @Published var message: String?

    private var messageTimer: Timer?

    func flash(_ text: String) {
        message = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.message = nil }
    }
}

/// Maps grid cells to points for one page.
struct GridMetrics {
    let columns: Int
    let rows: Int
    let size: CGSize
    let gap: CGFloat = 12

    var pitchX: CGFloat { (size.width + gap) / CGFloat(columns) }
    var pitchY: CGFloat { (size.height + gap) / CGFloat(rows) }

    func rect(_ frame: GridFrame) -> CGRect {
        CGRect(x: CGFloat(frame.x) * pitchX, y: CGFloat(frame.y) * pitchY,
               width: CGFloat(frame.w) * pitchX - gap, height: CGFloat(frame.h) * pitchY - gap)
    }

    /// The snapped frame a drag would produce.
    func proposed(from frame: GridFrame, mode: EditState.Mode, translation: CGSize) -> GridFrame {
        let dx = Int((translation.width / pitchX).rounded())
        let dy = Int((translation.height / pitchY).rounded())
        var result = frame
        switch mode {
        case .move:
            result.x = min(max(frame.x + dx, 0), columns - frame.w)
            result.y = min(max(frame.y + dy, 0), rows - frame.h)
        case .resize:
            result.w = min(max(frame.w + dx, 1), columns - frame.x)
            result.h = min(max(frame.h + dy, 1), rows - frame.y)
        }
        return result
    }
}

struct PageGridView: View {
    static let space = "pageGrid"
    @EnvironmentObject var model: AppModel
    let page: PageConfig
    @ObservedObject var edit: EditState

    var body: some View {
        GeometryReader { geo in
            let grid = GridMetrics(columns: page.columns, rows: page.rows, size: geo.size)
            ZStack(alignment: .topLeading) {
                if model.editing {
                    cells(grid)
                    dropTarget(grid)
                }
                ForEach(page.widgets) { widget in
                    if let frame = widget.frame {
                        let rect = displayedRect(for: widget, frame: frame, grid: grid)
                        WidgetView(widget: widget)
                            .frame(width: rect.width, height: rect.height)
                            .overlay {
                                if model.editing { WidgetEditChrome(widget: widget, frame: frame, page: page, grid: grid, edit: edit) }
                            }
                            .offset(x: rect.minX, y: rect.minY)
                            .zIndex(edit.dragging == widget.id ? 1 : 0)
                    }
                }
            }
            .coordinateSpace(name: Self.space)
        }
    }

    /// While dragging, the widget follows the finger; it snaps when released.
    private func displayedRect(for widget: WidgetConfig, frame: GridFrame, grid: GridMetrics) -> CGRect {
        var rect = grid.rect(frame)
        guard edit.dragging == widget.id else { return rect }
        switch edit.mode {
        case .move:
            rect = rect.offsetBy(dx: edit.translation.width, dy: edit.translation.height)
        case .resize:
            rect.size.width = max(grid.pitchX - grid.gap, rect.width + edit.translation.width)
            rect.size.height = max(grid.pitchY - grid.gap, rect.height + edit.translation.height)
        }
        return rect
    }

    private func cells(_ grid: GridMetrics) -> some View {
        ForEach(0..<(page.columns * page.rows), id: \.self) { index in
            let rect = grid.rect(GridFrame(x: index % page.columns, y: index / page.columns, w: 1, h: 1))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    @ViewBuilder
    private func dropTarget(_ grid: GridMetrics) -> some View {
        if let id = edit.dragging, let widget = page.widgets.first(where: { $0.id == id }), let frame = widget.frame {
            let target = grid.proposed(from: frame, mode: edit.mode, translation: edit.translation)
            let ok = page.fits(target, ignoring: id)
            let rect = grid.rect(target)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill((ok ? Color(hex: "#30D158") : Color(hex: "#FF453A")).opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(ok ? Color(hex: "#30D158") : Color(hex: "#FF453A"), lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// Edit-mode overlay: tap to open the Widget's Editor, drag anywhere to move, drag the corner
/// handle to resize, ✕ to remove.
struct WidgetEditChrome: View {
    @EnvironmentObject var model: AppModel
    let widget: WidgetConfig
    let frame: GridFrame
    let page: PageConfig
    let grid: GridMetrics
    @ObservedObject var edit: EditState

    var body: some View {
        let accent = Theme.accent(for: widget.kind)
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.5))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 22, weight: .semibold))
                Text(widget.title ?? widget.kind.displayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(frame.w)×\(frame.h)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                if openEditor != nil {
                    Label("Tap to edit", systemImage: "pencil")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture { openEditor?() }
        .gesture(drag(.move))
        .overlay(alignment: .topTrailing) {
            TouchButton(symbol: "xmark", tint: Color(hex: "#FF453A"), size: 40) {
                model.removeWidget(widget.id, from: page.id)
            }
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 44, height: 44)
                .background(accent, in: Circle())
                .padding(6)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(.resize))
        }
    }

    /// Opens the Editor of Widgets that have one. Editors open only from Edit mode, so they
    /// can't be hit by accident during normal use.
    private var openEditor: (() -> Void)? {
        let id = widget.id
        switch widget.kind {
        case .launcher: return { model.launcherEditorWidgetID = id }
        case .worldClock, .weather: return { model.cityEditorWidgetID = id }
        case .ai: return { model.ai.connectEditorOpen = true }
        default: return nil
        }
    }

    private func drag(_ mode: EditState.Mode) -> some Gesture {
        // Big enough that a finger's wobble during a Tap doesn't count as a drag.
        // In the page's space, not the window's, so drags match the grid in the scaled preview too.
        DragGesture(minimumDistance: 8, coordinateSpace: .named(PageGridView.space))
            .onChanged { value in
                if edit.dragging != widget.id {
                    edit.dragging = widget.id
                    edit.mode = mode
                }
                edit.translation = value.translation
            }
            .onEnded { value in
                let target = grid.proposed(from: frame, mode: mode, translation: value.translation)
                if target != frame && !model.setFrame(target, of: widget.id, on: page.id) {
                    edit.flash("That spot overlaps another widget")
                }
                edit.dragging = nil
                edit.translation = .zero
            }
    }
}

struct EditToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var edit: EditState

    var body: some View {
        let page = model.currentPage
        let index = min(model.currentPageIndex, model.pages.count - 1)
        let confirming = edit.confirmDeletePage == page.id

        HStack(spacing: 10) {
            TouchButton(symbol: "chevron.left", size: 48, enabled: index > 0) { model.showPage(index - 1) }
            Group {
                if model.pages.count > 1 { PageDots(count: model.pages.count, current: index) }
            }
            .frame(minWidth: 130)
            TouchButton(symbol: "chevron.right", size: 48, enabled: index < model.pages.count - 1) { model.showPage(index + 1) }

            Divider().frame(height: 40).overlay(Color.white.opacity(0.15)).padding(.horizontal, 6)

            ToolbarButton(title: "Add Widget", symbol: "plus.square.on.square", tint: Color(hex: "#30D158")) { edit.showPalette = true }
            ToolbarButton(title: "Add Page", symbol: "plus.rectangle.on.rectangle") { model.addPage() }
            ToolbarButton(title: "Move Left", symbol: "arrow.left.to.line", enabled: index > 0) { model.movePage(page.id, by: -1) }
            ToolbarButton(title: "Move Right", symbol: "arrow.right.to.line", enabled: index < model.pages.count - 1) { model.movePage(page.id, by: 1) }
            ToolbarButton(title: confirming ? "Tap to confirm" : "Delete Page", symbol: "trash",
                          tint: Color(hex: "#FF453A"), filled: confirming, enabled: model.pages.count > 1) {
                if confirming {
                    edit.confirmDeletePage = nil
                    model.deletePage(page.id)
                } else {
                    edit.confirmDeletePage = page.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if edit.confirmDeletePage == page.id { edit.confirmDeletePage = nil }
                    }
                }
            }

            Spacer(minLength: 10)

            Button { model.editing = false; edit.showPalette = false } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 120, height: 50)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.tile)
        .foregroundStyle(.white)
    }
}

private struct ToolbarButton: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    var filled = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? .white : enabled ? tint : tint.opacity(0.3))
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(filled ? tint : Theme.tileRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

struct WidgetPalette: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var edit: EditState

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .onTapGesture { edit.showPalette = false }
            VStack(spacing: 16) {
                HStack {
                    Text("Add Widget").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    TouchButton(symbol: "xmark", size: 44) { edit.showPalette = false }
                }
                HStack(spacing: 12) {
                    ForEach(WidgetKind.allCases) { type in
                        Button {
                            if model.addWidget(type) {
                                edit.showPalette = false
                            } else {
                                edit.flash("No room on this page — shrink or remove a widget first")
                            }
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: type.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.accent(for: type))
                                Text(type.displayName).font(.system(size: 14, weight: .semibold, design: .rounded))
                            }
                            .frame(width: 128, height: 118)
                            .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(22)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .fixedSize()
        }
    }
}
