import Foundation

/// One request as the page's own Resource Timing reports it. WebKit gives pages no headers or bodies, so this is what exists.
struct ResourceEntry: Equatable, Identifiable {
    var name: String
    var type: String
    var startMs: Double
    var durationMs: Double
    var transferBytes: Int
    var decodedBytes: Int
    var status: Int
    var id: String { "\(startMs)|\(name)" }

    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        self.name = name
        type = raw["type"] as? String ?? "other"
        startMs = (raw["start"] as? NSNumber)?.doubleValue ?? 0
        durationMs = max(0, (raw["duration"] as? NSNumber)?.doubleValue ?? 0)
        transferBytes = (raw["transfer"] as? NSNumber)?.intValue ?? 0
        decodedBytes = (raw["decoded"] as? NSNumber)?.intValue ?? 0
        status = (raw["status"] as? NSNumber)?.intValue ?? 0
    }

    init(name: String, type: String, startMs: Double, durationMs: Double, transferBytes: Int, decodedBytes: Int = 0, status: Int = 0) {
        self.name = name; self.type = type; self.startMs = startMs; self.durationMs = durationMs
        self.transferBytes = transferBytes; self.decodedBytes = decodedBytes; self.status = status
    }
}

enum Waterfall {
    struct Bar: Equatable, Identifiable {
        var entry: ResourceEntry
        /// Where the bar starts and how long it is, as fractions of the whole timeline.
        var start: Double
        var length: Double
        var id: String { entry.id }
    }

    static func bars(_ entries: [ResourceEntry]) -> [Bar] {
        guard !entries.isEmpty else { return [] }
        let end = max(entries.map { $0.startMs + $0.durationMs }.max() ?? 1, 1)
        return entries.sorted { $0.startMs < $1.startMs }.map {
            Bar(entry: $0, start: $0.startMs / end, length: max($0.durationMs / end, 0.004))
        }
    }

    struct Summary: Equatable {
        var requests: Int
        var transferBytes: Int
        var slowest: String?
        var byType: [String: Int]
        var totalMs: Double
    }

    static func summary(_ entries: [ResourceEntry]) -> Summary {
        var types: [String: Int] = [:]
        for e in entries { types[e.type, default: 0] += 1 }
        return Summary(requests: entries.count, transferBytes: entries.reduce(0) { $0 + $1.transferBytes },
                       slowest: entries.max { $0.durationMs < $1.durationMs }?.name, byType: types,
                       totalMs: entries.map { $0.startMs + $0.durationMs }.max() ?? 0)
    }
}

enum HARWriter {
    /// A HAR 1.2 file from Resource Timing. Headers and bodies are empty because the page cannot see them; the file says so.
    static func har(page: URL?, entries: [ResourceEntry], started: Date) -> Data {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items: [[String: Any]] = entries.sorted { $0.startMs < $1.startMs }.map { e in
            [
                "startedDateTime": iso.string(from: started.addingTimeInterval(e.startMs / 1000)),
                "time": e.durationMs,
                "request": ["method": "GET", "url": e.name, "httpVersion": "", "cookies": [], "headers": [], "queryString": [], "headersSize": -1, "bodySize": -1] as [String: Any],
                "response": ["status": e.status, "statusText": "", "httpVersion": "", "cookies": [], "headers": [],
                             "content": ["size": e.decodedBytes, "mimeType": e.type] as [String: Any], "redirectURL": "", "headersSize": -1, "bodySize": e.transferBytes] as [String: Any],
                "cache": [String: Any](), "timings": ["send": 0, "wait": e.durationMs, "receive": 0] as [String: Any],
                "comment": "type: \(e.type)",
            ]
        }
        let log: [String: Any] = [
            "version": "1.2", "creator": ["name": "Browser Setu", "version": "1"] as [String: Any],
            "comment": "Built from the page's Resource Timing data. Headers and bodies are not available to pages, so they are empty.",
            "pages": [["startedDateTime": iso.string(from: started), "id": "page_1", "title": page?.absoluteString ?? "", "pageTimings": [String: Any]()] as [String: Any]],
            "entries": items.map { var i = $0; i["pageref"] = "page_1"; return i },
        ]
        return (try? JSONSerialization.data(withJSONObject: ["log": log], options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

/// What a storage inspector shows: the keys a page keeps, with sizes.
struct StorageItem: Equatable, Identifiable {
    enum Area: String { case local = "Local storage", session = "Session storage", cookie = "Cookies" }
    var area: Area
    var key: String
    var valueSize: Int
    var preview: String
    var id: String { area.rawValue + "|" + key }

    /// The value, cut short, with anything that looks like a secret hidden: values are shown to the person who owns them, but copied screenshots travel.
    static func preview(_ value: String, key: String) -> String {
        let sensitive = ["token", "secret", "password", "auth", "session", "key"].contains { key.lowercased().contains($0) }
        if sensitive { return "••••••••" }
        let single = value.replacingOccurrences(of: "\n", with: " ")
        return single.count > 80 ? String(single.prefix(80)) + "…" : single
    }
}

/// A short, stable summary of how a page did, from the browser's own timing numbers.
struct PagePerformance: Equatable {
    var loadMs: Double
    var domContentMs: Double
    var firstPaintMs: Double?
    var requests: Int
    var transferBytes: Int
    var domNodes: Int

    init(_ raw: [String: Any]) {
        func n(_ k: String) -> Double { (raw[k] as? NSNumber)?.doubleValue ?? 0 }
        loadMs = n("load"); domContentMs = n("dcl")
        firstPaintMs = (raw["paint"] as? NSNumber)?.doubleValue
        requests = Int(n("requests")); transferBytes = Int(n("transfer")); domNodes = Int(n("nodes"))
    }

    var notes: [String] {
        var out: [String] = []
        if loadMs > 5000 { out.append("The page took over five seconds to finish loading.") }
        if transferBytes > 5_000_000 { out.append("It downloaded \(ByteCountFormatter.string(fromByteCount: Int64(transferBytes), countStyle: .file)); that is heavy on a phone connection.") }
        if requests > 150 { out.append("It made \(requests) requests.") }
        if domNodes > 3000 { out.append("It has \(domNodes) elements, which slows scrolling and memory.") }
        return out
    }
}


/// Window sizes of common screens, for looking at how a page responds. The Mac window is resized to the page area of that size; a phone cannot resize its window.
struct ViewportPreset: Identifiable, Equatable {
    var id: String
    var title: String
    var width: Int
    var height: Int
    var summary: String { "\(width) × \(height)" }

    static let all: [ViewportPreset] = [
        .init(id: "phone-small", title: "Small phone", width: 375, height: 667),
        .init(id: "phone", title: "Phone", width: 393, height: 852),
        .init(id: "phone-wide", title: "Phone, sideways", width: 852, height: 393),
        .init(id: "tablet", title: "Tablet", width: 820, height: 1180),
        .init(id: "tablet-wide", title: "Tablet, sideways", width: 1180, height: 820),
        .init(id: "laptop", title: "Laptop", width: 1280, height: 800),
        .init(id: "desktop", title: "Desktop", width: 1920, height: 1080),
    ]

    /// The size a window can actually be made: never larger than the screen's usable area, and never so small the window stops working.
    func fitted(to screen: CGSize) -> CGSize {
        CGSize(width: min(max(CGFloat(width), 320), screen.width), height: min(max(CGFloat(height), 320), screen.height))
    }
}

/// What the element picker reports about the thing clicked.
struct PickedElement: Equatable {
    var selector: String
    var tag: String
    var size: CGSize
    var text: String
    var html: String
    var styles: [(name: String, value: String)]

    init?(_ raw: [String: Any]?) {
        guard let raw, let selector = raw["selector"] as? String, !selector.isEmpty, let tag = raw["tag"] as? String else { return nil }
        self.selector = String(selector.prefix(500)); self.tag = String(tag.prefix(40))
        size = CGSize(width: (raw["width"] as? NSNumber)?.doubleValue ?? 0, height: (raw["height"] as? NSNumber)?.doubleValue ?? 0)
        text = String((raw["text"] as? String ?? "").prefix(300)); html = String((raw["html"] as? String ?? "").prefix(1200))
        styles = (raw["styles"] as? [[String]] ?? []).prefix(40).compactMap { $0.count == 2 ? (String($0[0].prefix(60)), String($0[1].prefix(200))) : nil }
    }

    static func == (a: PickedElement, b: PickedElement) -> Bool { a.selector == b.selector && a.html == b.html && a.size == b.size }

    /// The rule as CSS, ready to paste.
    var css: String { selector + " {\n" + styles.map { "  \($0.name): \($0.value);" }.joined(separator: "\n") + "\n}" }
}
