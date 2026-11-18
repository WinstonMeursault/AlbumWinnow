import AlbumWinnowCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ReviewAnimation: String, CaseIterable, Identifiable {
    static let defaultsKey = "AlbumWinnow.reviewAnimation"
    case slide, cover, fade, none

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .slide: "Slide"
        case .cover: "Cover"
        case .fade: "Fade"
        case .none: "None"
        }
    }
}

struct ReviewPager: View {
    let groups: [DuplicateGroup]
    @Binding var selectedID: AssetID?
    let model: ReviewModel
    let finishReview: () -> Void

    @AppStorage(ReviewAnimation.defaultsKey) private var preference = ReviewAnimation.slide.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var translation: CGFloat = 0
    @State private var settling = false
    @State private var transitionID = UUID()

    private var style: ReviewAnimation {
        let preferred = ReviewAnimation(rawValue: preference) ?? .slide
        return reduceMotion && preferred != .none ? .fade : preferred
    }

    var body: some View {
        GeometryReader { geometry in
            if let index = groups.firstIndex(where: { $0.id == selectedID }) {
                let width = max(1, geometry.size.width)
                let neighbors = groups[max(0, index - 1)..<min(groups.count, index + 2)]
                let previousID = index > 0 ? groups[index - 1].id : nil
                ZStack {
                    background
                    ForEach(neighbors) { group in
                        let relative = group.id == selectedID ? 0 : (group.id == previousID ? -1 : 1)
                        GroupReviewView(group: group, model: model, isActive: relative == 0) {
                            navigate(forward: true, width: width, index: index)
                        }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background { background }
                            .overlay {
                                Color.black.opacity(shade(relative: relative, width: width))
                                    .allowsHitTesting(false)
                            }
                            .offset(x: offset(relative: relative, width: width, index: index))
                            .opacity(opacity(relative: relative, width: width, index: index))
                            .zIndex(layer(relative: relative))
                            .allowsHitTesting(relative == 0 && !settling)
                            .accessibilityHidden(relative != 0)
                    }
                    if index == groups.count - 1 {
                        Label("Back to Overview", systemImage: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background { background }
                            .offset(x: offset(relative: 1, width: width, index: index))
                            .opacity(opacity(relative: 1, width: width, index: index))
                            .zIndex(layer(relative: 1))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .clipped()
                .contentShape(.rect)
                #if os(macOS)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { update($0.translation, width: width, index: index) }
                        .onEnded {
                            end($0.translation, velocity: $0.velocity.width, cancelled: false, width: width, index: index)
                        }
                )
                .background {
                    ReviewTrackpadSwipe(
                        onChange: { update($0, width: width, index: index) },
                        onEnd: { end($0, velocity: $1, cancelled: $2, width: width, index: index) }
                    )
                }
                #else
                .gesture(ReviewSwipe(
                    onChange: { update($0, width: width, index: index) },
                    onEnd: { end($0, velocity: $1, cancelled: $2, width: width, index: index) }
                ))
                #endif
                .accessibilityAction(named: Text("Previous Group")) { navigate(forward: false, width: width, index: index) }
                .accessibilityAction(named: Text("Next Group")) { navigate(forward: true, width: width, index: index) }
                .onChange(of: geometry.size) { reset() }
            }
        }
        .onChange(of: selectedID) { reset() }
        .onChange(of: groups) { reset() }
        .onChange(of: preference) { reset() }
        .onChange(of: reduceMotion) { reset() }
        .onDisappear { reset() }
    }

    private var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func offset(relative: Int, width: CGFloat, index: Int) -> CGFloat {
        switch style {
        case .slide: CGFloat(relative) * width + translation
        case .cover:
            relative == 0 ? (index == 0 && translation > 0 ? translation : 0) :
                CGFloat(relative) * width + translation
        case .fade, .none: 0
        }
    }

    private func opacity(relative: Int, width: CGFloat, index: Int) -> Double {
        let incoming = translation < 0 ? 1 : -1
        switch style {
        case .slide, .cover: return 1
        case .none: return relative == 0 ? 1 : 0
        case .fade:
            let progress = index == 0 && translation > 0 ? 0 : min(1, abs(translation) / width)
            return relative == 0 ? 1 : (relative == incoming ? progress : 0)
        }
    }

    private func layer(relative: Int) -> Double {
        relative == 0 ? 1 : (relative == (translation < 0 ? 1 : -1) ? 2 : 0)
    }

    private func shade(relative: Int, width: CGFloat) -> Double {
        style == .cover && relative == 0 ? 0.16 * min(1, abs(translation) / width) : 0
    }

    private func update(_ distance: CGSize, width: CGFloat, index: Int) {
        guard !settling, abs(distance.width) > 1.5 * abs(distance.height) else { return }
        let horizontal = min(width, max(-width, distance.width))
        translation = index == 0 && horizontal > 0 ? horizontal * 0.22 : horizontal
    }

    private func end(_ distance: CGSize, velocity: CGFloat, cancelled: Bool, width: CGFloat, index: Int) {
        guard !settling else { return }
        let horizontal = distance.width
        let horizontalIntent = abs(horizontal) > 1.5 * abs(distance.height)
        let projected = horizontal + velocity * 0.15
        let commit = !cancelled && horizontalIntent && abs(horizontal) > 20 &&
            (abs(horizontal) >= width * 0.22 || (abs(velocity) > 500 && abs(projected) > width * 0.22))
        settle(forward: horizontal < 0, commit: commit, width: width, index: index)
    }

    private func navigate(forward: Bool, width: CGFloat, index: Int) {
        guard !settling else { return }
        settle(forward: forward, commit: true, width: width, index: index)
    }

    private func settle(forward: Bool, commit: Bool, width: CGFloat, index: Int) {
        let advance = commit && (forward || index > 0)
        let target = advance ? (forward ? -width : width) : 0
        let id = transitionID
        settling = true
        let animation: Animation? = style == .none ? nil :
            .easeOut(duration: reduceMotion ? 0.12 : 0.25)
        withAnimation(animation, completionCriteria: .removed) {
            translation = target
        } completion: {
            guard transitionID == id else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                translation = 0
                settling = false
                if advance {
                    let next = index + (forward ? 1 : -1)
                    if groups.indices.contains(next) {
                        selectedID = groups[next].id
                    } else {
                        finishReview()
                    }
                }
            }
        }
    }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transitionID = UUID()
            translation = 0
            settling = false
        }
    }
}

#if os(macOS)
private struct ReviewTrackpadSwipe: NSViewRepresentable {
    let onChange: (CGSize) -> Void
    let onEnd: (CGSize, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class SwipeView: NSView {
        var onChange: ((CGSize) -> Void)?
        var onEnd: ((CGSize, CGFloat, Bool) -> Void)?
        private var monitor: Any?
        private var translation: CGSize?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            translation = nil
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.track(event)
                return event
            }
        }

        private func track(_ event: NSEvent) {
            guard event.window === window, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
            if event.phase == .began {
                translation = bounds.contains(convert(event.locationInWindow, from: nil)) ? .zero : nil
            }
            guard var distance = translation else { return }
            // Keep the page direction tied to finger movement for either system scroll setting.
            distance.width += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
            distance.height += event.scrollingDeltaY
            if event.phase == .ended || event.phase == .cancelled {
                translation = nil
                onEnd?(distance, 0, event.phase == .cancelled)
            } else {
                translation = distance
                onChange?(distance)
            }
        }
    }
}
#else
private struct ReviewSwipe: UIGestureRecognizerRepresentable {
    let onChange: (CGSize) -> Void
    let onEnd: (CGSize, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: nil)
        let distance = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began, .changed: onChange(distance)
        case .ended, .cancelled, .failed:
            onEnd(distance, recognizer.velocity(in: nil).x, recognizer.state != .ended)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            let startX = pan.location(in: nil).x - pan.translation(in: nil).x
            return startX > 24 && abs(velocity.x) > 1.5 * abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }
    }
}
#endif

