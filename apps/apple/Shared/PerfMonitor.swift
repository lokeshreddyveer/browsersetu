import Foundation
import os

/// Signposts for the moments that decide how fast the browser feels. They cost nothing unless Instruments is recording, and record nothing
/// about what was visited: only the name of the moment and how long it took.
enum Perf {
    private static let log = OSLog(subsystem: "app.browsersetu", category: .pointsOfInterest)

    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return body()
    }
}

/// Releases what can be rebuilt when the system is short of memory or running hot: the page thumbnails of tabs that are not on screen, and
/// the in-memory copy of site icons (they stay on disk). Page state is never touched here; that is the tab lifecycle's job.
@MainActor
enum MemoryTrim {
    /// Thumbnails kept for the most recently used tabs, so the overview still has something to show.
    static let keptThumbnails = 6

    static func run(model: BrowserModel, aggressive: Bool) {
        let recent = model.tabs.sorted { $0.lastActive > $1.lastActive }
        let keep = Set(recent.prefix(aggressive ? 2 : keptThumbnails).map(\.id))
        for tab in model.tabs where tab.snapshot != nil && tab.id != model.activeID && !keep.contains(tab.id) { tab.snapshot = nil }
        FaviconStore.shared.trimMemory(limit: aggressive ? 0 : FaviconStore.memoryLimit)
    }
}
