import SwiftUI

/// When to offer a way back to the top of a long page, as a small pill at the left, just above the bar. Chosen from what design systems agree on: wait until the person is well down the page
/// AND is moving back up (that is when they are looking for the top), leave it for about five seconds (the usual time for a short message, enough to read and act),
/// then go away; offer again later, never more than a few times, and not at all once they have shown they do not want it.
struct BackToTopRules {
    /// How far down, in screens, before it is ever offered.
    static let screensDown = 2.0
    /// How far back up (points, in one go) counts as "looking for the top".
    static let upRun = 120.0
    /// How long the pill stays.
    static let visibleFor: TimeInterval = 5
    /// How long after it has gone before it may come back.
    static let cooldown: TimeInterval = 30
    /// The most times it is offered on one page.
    static let offersPerPage = 3

    enum Action: Equatable { case none, show, hide }

    private(set) var offers = 0
    private var upRun = 0.0
    private var shownAt: Date?
    private var hiddenAt: Date?
    var isShown: Bool { shownAt != nil }

    /// The person moved the page. `deltaY` is positive toward the top; `screens` is how far from the top the page now is, in screens.
    mutating func scrolled(deltaY: Double, screens: Double, now: Date = Date()) -> Action {
        // Back near the top: nothing to offer, and a new offer is allowed the next time they are far down.
        if screens < 0.5 {
            upRun = 0; offers = 0
            return hide(now)
        }
        if deltaY < 0 {
            // Going further down again: they changed their mind.
            upRun = 0
            return isShown ? hide(now) : .none
        }
        upRun += deltaY
        if isShown { shownAt = now; return .none }       // still moving up: keep it a little longer
        guard screens >= Self.screensDown, upRun >= Self.upRun, offers < Self.offersPerPage else { return .none }
        if let hiddenAt, now.timeIntervalSince(hiddenAt) < Self.cooldown { return .none }
        shownAt = now; offers += 1; upRun = 0
        return .show
    }

    /// Called as time passes: the pill goes once it has been left alone for its time.
    mutating func tick(now: Date = Date()) -> Action {
        guard let shownAt, now.timeIntervalSince(shownAt) >= Self.visibleFor else { return .none }
        return hide(now)
    }

    /// A new page or tab: start again.
    mutating func reset() { self = BackToTopRules() }

    private mutating func hide(_ now: Date) -> Action {
        guard shownAt != nil else { return .none }
        shownAt = nil; hiddenAt = now; upRun = 0
        return .hide
    }

    /// The pill was used.
    mutating func used(now: Date = Date()) { _ = hide(now); offers = Self.offersPerPage }
}

@MainActor
extension BrowserModel {
    /// Called with every movement of the page in the tab in front.
    func pageMoved(deltaY: Double, screens: Double) {
        guard backToTopPill, !addressBar.isEditing, !overviewVisible else { return }
        apply(backToTopRules.scrolled(deltaY: deltaY, screens: screens))
        if backToTopVisible { scheduleBackToTopExpiry() }
    }

    func resetBackToTop() {
        backToTopRules.reset()
        backToTopExpiry?.cancel()
        if backToTopVisible { animated(.easeOut(duration: 0.2)) { backToTopVisible = false } }
    }

    /// The pill's own button.
    func goBackToTop() {
        backToTopRules.used()
        backToTopExpiry?.cancel()
        animated(.easeOut(duration: 0.2)) { backToTopVisible = false }
        active?.engine.scrollToEdge(bottom: false)
    }

    private func apply(_ action: BackToTopRules.Action) {
        switch action {
        case .show: animated(.spring(response: 0.38, dampingFraction: 0.82)) { backToTopVisible = true }
        case .hide: animated(.easeOut(duration: 0.22)) { backToTopVisible = false }
        case .none: break
        }
    }

    private func scheduleBackToTopExpiry() {
        backToTopExpiry?.cancel()
        backToTopExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BackToTopRules.visibleFor + 0.1))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.backToTopRules.tick())
        }
    }
}

#if os(iOS)
/// The small pill: an arrow and "Top", in the same glass as the bars, at the left just above the bar.
struct BackToTopPill: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.goBackToTop()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                Text("Top").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 16).frame(height: 38)
        }
        .buttonStyle(.plain)
        .floatingGlassCapsule(solidity: 0.45)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityLabel("Back to top")
        .accessibilityIdentifier("back-to-top")
        .transition(.move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
    }
}
#endif
