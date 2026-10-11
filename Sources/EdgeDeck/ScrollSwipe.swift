import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted for a vertical swipe on the dashboard. userInfo: "location" (CGPoint in
    /// SwiftUI global coordinates) and "forward" (Bool, true when the finger moved up).
    static let edgeDeckVerticalSwipe = Notification.Name("EdgeDeckVerticalSwipe")
}

/// Horizontal page-swipe offset, shared by the dashboard and the scroll recognizer.
/// Kept out of AppModel so a swipe doesn't re-render everything observing the model.
final class SwipeState: ObservableObject {
    @Published var offset: CGFloat = 0
    /// A control (e.g. a slider) owns the current drag, so it mustn't change pages.
    var heldByControl = false
}

/// Turns scroll-wheel gestures into swipes.
///
/// Touch drivers like Edgetap (and trackpads) deliver a one-finger swipe as phased,
/// pixel-precise scroll events rather than mouse drags, so SwiftUI drag gestures
/// never see them. Horizontal gestures switch dashboard pages with the page
/// following the finger; vertical ones page the list under the finger. Momentum
/// events after the finger lifts are ignored so a flick moves one page.
final class ScrollSwipeRecognizer {
    private let model: AppModel
    private let swipe: SwipeState

    private enum Axis { case horizontal, vertical }

    private var active = false
    private var start = CGPoint.zero
    private var total = CGSize.zero
    private var axis: Axis?
    private var idleTimer: Timer?

    /// Finger travel needed to change page or list page.
    private let pageThreshold: CGFloat = 140
    private let listThreshold: CGFloat = 40

    init(model: AppModel, swipe: SwipeState) {
        self.model = model
        self.swipe = swipe
    }

    /// `view` is the dashboard's root view; used to convert to SwiftUI's top-left coordinates.
    func handle(_ event: NSEvent, in view: NSView) {
        guard event.momentumPhase.isEmpty else { return }
        let phase = event.phase

        if phase.contains(.began) || (!active && (phase.isEmpty || phase.contains(.changed))) {
            begin(at: CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y))
        }
        if phase.contains(.began) || phase.contains(.changed) || phase.isEmpty {
            accumulate(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            end()
        } else if phase.isEmpty {
            // Plain mouse wheels have no phases: treat a pause as the end of the gesture.
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.end() }
        }
    }

    private func begin(at location: CGPoint) {
        active = true
        start = location
        total = .zero
        axis = nil
    }

    private func accumulate(dx: CGFloat, dy: CGFloat) {
        total.width += dx
        total.height += dy
        if axis == nil, max(abs(total.width), abs(total.height)) > 10 {
            axis = abs(total.width) > abs(total.height) ? .horizontal : .vertical
        }
        // Full-screen overlays (Editors) shouldn't flip pages underneath.
        guard axis == .horizontal, !model.editorOpen else { return }
        // Rubber-band past the first/last page.
        let current = model.currentPageIndex
        let atEdge = (current == 0 && total.width > 0) || (current == model.pages.count - 1 && total.width < 0)
        swipe.offset = atEdge ? total.width / 4 : total.width
    }

    private func end() {
        guard active else { return }
        active = false
        idleTimer?.invalidate()

        switch axis {
        case .horizontal where !model.editorOpen:
            let current = model.currentPageIndex
            if total.width < -pageThreshold {
                model.showPage(current + 1)
            } else if total.width > pageThreshold {
                model.showPage(current - 1)
            }
        case .vertical where abs(total.height) > listThreshold:
            NotificationCenter.default.post(name: .edgeDeckVerticalSwipe, object: nil,
                                            userInfo: ["location": start, "forward": total.height < 0])
        default:
            break
        }
        if swipe.offset != 0 {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { swipe.offset = 0 }
        }
    }
}
