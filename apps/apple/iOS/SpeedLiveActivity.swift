import ActivityKit
import Combine
import os
import SwiftUI

/// The Dynamic Island's speed readout. iOS shows an app's Live Activity in the island once the app is not in front, and gives a suspended app no
/// way to measure the network, so: it runs (and updates every second) while the browser is open, stays up for two minutes after you leave it
/// showing the last speed marked as out of date, and then ends. Coming back resumes it at once.
@MainActor
final class SpeedLiveActivityController: ObservableObject {
    private let monitor = NetworkSpeedMonitor()
    private var activity: Activity<SpeedActivityAttributes>?
    private var feed: AnyCancellable?
    private var lastSent = Date.distantPast
    private var endTask: Task<Void, Never>?
    private var popupsOn = false
    private var lastClass = -1
    private var lastPopup = Date.distantPast
    /// What the person sees in Settings, so a missing island has an explanation.
    @Published private(set) var status = "" { didSet {
        Logger(subsystem: "com.browsersetu.ios", category: "speed").notice("speed activity: \(self.status, privacy: .public)")
        #if DEBUG
        fputs("SPEEDACTIVITY \(status)\n", stderr)
        #endif
    } }

    func update(wanted: Bool, phase: ScenePhase, popups: Bool = false) {
        popupsOn = popups
        guard wanted else { stop(); status = "Off"; return }
        switch phase {
        case .active: endTask?.cancel(); start()
        case .background: leaveInFront()
        default: break      // inactive is brief (a pulled-down control centre); keep going
        }
    }

    private func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are off for Browser Setu. Turn them on in Settings › Browser Setu, and check Settings › Face ID & Passcode › Live Activities."
            return
        }
        if activity == nil {
            // An activity left over from an earlier launch is reused, never doubled.
            activity = Activity<SpeedActivityAttributes>.activities.first
        }
        if activity == nil {
            do {
                let state = SpeedActivityAttributes.ContentState(down: 0, up: 0)
                activity = try Activity.request(attributes: SpeedActivityAttributes(), content: .init(state: state, staleDate: nil), pushType: nil)
            } catch {
                status = "Could not start: \(error.localizedDescription)"
                return
            }
        }
        status = "Running. It shows in the Dynamic Island when you leave the app."
        monitor.start()
        feed = monitor.$down.combineLatest(monitor.$up).sink { [weak self] down, up in
            guard let self, let activity = self.activity, Date().timeIntervalSince(self.lastSent) >= 1 else { return }
            self.lastSent = Date()
            let state = SpeedActivityAttributes.ContentState(down: down, up: up)
            Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(8))) }
            self.considerPopup(down: down, up: up)
        }
    }

    /// 0 idle, 1 browsing, 2 heavy (a large download or upload).
    private func speedClass(_ down: Double, _ up: Double) -> Int {
        let total = down + up
        return total < 50_000 ? 0 : (total < 1_000_000 ? 1 : 2)
    }

    /// With pop-ups on, the island opens briefly when the speed moves to a different class (a download starts, or the connection goes quiet),
    /// and at most once every half minute.
    private func considerPopup(down: Double, up: Double) {
        let now = speedClass(down, up)
        defer { lastClass = now }
        guard popupsOn, lastClass >= 0, now != lastClass, Date().timeIntervalSince(lastPopup) > 30 else { return }
        lastPopup = Date()
        Task { await flash() }
    }

    /// Opens the island for a few seconds with the current speed, silently, the way VayuSetu announces a change. iOS shows an app's Live
    /// Activity while the app is in front only when it is sent as an alert.
    func flash() async {
        guard let activity else { return }
        let state = SpeedActivityAttributes.ContentState(down: monitor.down, up: monitor.up)
        let body = "↓ \(SpeedText.full(state.down))   ↑ \(SpeedText.full(state.up))"
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(8)),
                              alertConfiguration: AlertConfiguration(title: LocalizedStringResource(stringLiteral: "Network speed"),
                                                                     body: LocalizedStringResource(stringLiteral: body), sound: .named("silence.caf")))
    }

    /// The app is leaving the front: measuring stops, the last speed stays up for a while, marked out of date.
    private func leaveInFront() {
        feed = nil
        monitor.stop()
        guard let activity else { return }
        Task { await activity.update(.init(state: activity.content.state, staleDate: Date())) }
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func stop() {
        endTask?.cancel()
        feed = nil
        monitor.stop()
        let current = activity
        activity = nil
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
    }
}
