import Foundation
import SwiftUI

/// How eagerly inactive tabs give their memory back. A discarded tab keeps its address, title, back/forward list
/// and scroll position; only the page's web process is released, and it reloads when the tab is selected again.
enum MemoryMode: String, CaseIterable, Identifiable {
    case balanced, saver, performance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .saver: "Memory Saver"
        case .performance: "Performance"
        }
    }
    var summary: String {
        switch self {
        case .balanced: "Keeps your recent tabs. Releases older inactive ones when the system is low on memory."
        case .saver: "Also releases tabs you have not looked at for ten minutes, even when memory is fine."
        case .performance: "Keeps almost every tab live. Only releases tabs when the system is critically short of memory."
        }
    }
}

enum MemoryEvent { case timer, warning, critical }

/// What the policy needs to know about a tab. Kept separate from `TabController` so the policy is pure.
struct TabCandidate: Equatable {
    var id: UInt64
    var lastActive: Date
    var pinned: Bool
    var isPrivate: Bool
    var isActive: Bool
    var loaded: Bool
    var discarded: Bool
    /// The person asked that this site's tabs never go to sleep.
    var exempt = false
}

enum TabLifecyclePolicy {
    /// Tabs to release, oldest first.
    /// Never chosen: the selected tab, private tabs (their page state could not come back), pinned tabs when asked to
    /// keep them, tabs with nothing loaded, and the most recently used tabs of the mode's budget.
    static func victims(_ tabs: [TabCandidate], mode: MemoryMode, event: MemoryEvent, now: Date, keepPinned: Bool) -> [UInt64] {
        guard let rule = rule(mode: mode, event: event) else { return [] }
        let live = tabs.filter { $0.loaded && !$0.discarded }
        let protected = Set(live.sorted { $0.lastActive > $1.lastActive }.prefix(rule.keepRecent).map(\.id))
        return live
            .filter { !$0.isActive && !$0.isPrivate && !$0.exempt && !(keepPinned && $0.pinned) && !protected.contains($0.id) }
            .filter { now.timeIntervalSince($0.lastActive) >= rule.minIdle }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.id)
    }

    private static func rule(mode: MemoryMode, event: MemoryEvent) -> (keepRecent: Int, minIdle: TimeInterval)? {
        switch (mode, event) {
        case (.balanced, .warning): (5, 120)
        case (.balanced, .critical): (2, 30)
        case (.saver, .timer): (3, 600)
        case (.saver, .warning): (3, 60)
        case (.saver, .critical): (1, 10)
        case (.performance, .critical): (8, 300)
        default: nil
        }
    }
}

/// Watches the system's memory pressure (an event, not a poll) and a slow one-minute timer for Memory Saver.
@MainActor
final class TabLifecycle {
    private weak var model: BrowserModel?
    private var source: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?

    init(model: BrowserModel) { self.model = model }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event: MemoryEvent = source.data.contains(.critical) ? .critical : .warning
            _ = MainActor.assumeIsolated { Task { await self.run(event) } }
        }
        source.resume()
        self.source = source
        // A device that is running hot is treated like one short of memory: fewer live pages means less work.
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let state = ProcessInfo.processInfo.thermalState
                guard state == .serious || state == .critical else { return }
                Task { await self.run(state == .critical ? .critical : .warning) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.model != nil else { timer.invalidate(); return }
                Task { await self.run(.timer) }
            }
        }
    }

    func stop() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
    }

    /// Releases the tabs the policy picks, skipping any that are playing media, capturing the camera or microphone,
    /// or still loading.
    @discardableResult
    func run(_ event: MemoryEvent, now: Date = Date()) async -> [UInt64] {
        guard let model else { return [] }
        if event != .timer { MemoryTrim.run(model: model, aggressive: event == .critical) }
        let candidates = model.tabs.map { tab in
            TabCandidate(id: tab.id, lastActive: tab.lastActive, pinned: tab.pinned, isPrivate: tab.isPrivate,
                         isActive: tab.id == model.activeID || tab.id == model.splitTabID || tab.id == model.thirdSplitTabID,
                         loaded: tab.hasLoadedPage, discarded: tab.isDiscarded, exempt: model.neverSleeps(host: tab.url?.host))
        }
        var released: [UInt64] = []
        for id in TabLifecyclePolicy.victims(candidates, mode: model.effectiveMemoryMode, event: event, now: now, keepPinned: model.keepPinnedTabs) {
            guard let tab = model.tabs.first(where: { $0.id == id }), id != model.activeID else { continue }
            if await tab.engine.isBusy() { continue }
            // The tab may have been selected while we were asking.
            guard id != model.activeID else { continue }
            tab.discard()
            released.append(id)
        }
        return released
    }
}
