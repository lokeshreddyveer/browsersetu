import SwiftUI
import ImageIO

// The start page's collection of pictures: your own, kept in this profile's folder, each tagged for light mode, dark mode or either, shown one at a time, or rotated
// (each new tab, hourly or daily, in order or shuffled). Also the built-in gradient presets, which are drawn by the app itself, so there is nothing to license
// and nothing to download. Everything is local; no picture, name or choice leaves the device.

enum WallpaperAppearance: String, Codable, CaseIterable, Identifiable {
    case any, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .any: "Either"; case .light: "Light mode"; case .dark: "Dark mode" }
    }
}

enum WallpaperRotation: String, Codable, CaseIterable, Identifiable {
    case off, everyTab, hourly, daily
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .everyTab: "Each new tab"; case .hourly: "Every hour"; case .daily: "Every day" }
    }
}

struct WallpaperEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var appearance = WallpaperAppearance.any
    var added = Date()

    var fileName: String { id.uuidString + ".jpg" }
}

extension WallpaperEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        appearance = try c.decodeIfPresent(WallpaperAppearance.self, forKey: .appearance) ?? .any
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
    }
}

/// The collection and how it rotates, kept as one setting.
struct WallpaperLibraryState: Codable, Equatable {
    static let maxEntries = 40

    var entries: [WallpaperEntry] = []
    var rotation = WallpaperRotation.off
    var shuffle = false
    /// The picture shown while rotation is off.
    var selected: UUID?
    /// Advances once for each new start page when the rotation is "each new tab".
    var counter = 0

    var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    /// Nil when nothing was saved or what was saved cannot be read (so nothing is "cleaned up" on the strength of a failed read).
    static func decode(_ text: String?) -> WallpaperLibraryState? {
        guard let text, let data = text.data(using: .utf8), var state = try? JSONDecoder().decode(WallpaperLibraryState.self, from: data) else { return nil }
        state.entries = Array(state.entries.prefix(maxEntries))
        return state
    }
}

extension WallpaperLibraryState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([WallpaperEntry].self, forKey: .entries) ?? []
        rotation = try c.decodeIfPresent(WallpaperRotation.self, forKey: .rotation) ?? .off
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        counter = try c.decodeIfPresent(Int.self, forKey: .counter) ?? 0
    }
}

/// Which picture to show. Pure, so it is the same everywhere and easy to test.
enum WallpaperPicker {
    /// The pictures that may show in this appearance: the ones tagged for it. Only when none is tagged for it do the "either" ones show, so a picture tagged for
    /// light mode and one tagged for dark mode always win over an untagged one, however it was chosen.
    static func candidates(_ entries: [WallpaperEntry], dark: Bool) -> [WallpaperEntry] {
        let wanted: WallpaperAppearance = dark ? .dark : .light
        let exact = entries.filter { $0.appearance == wanted }
        return exact.isEmpty ? entries.filter { $0.appearance == .any } : exact
    }

    static func pick(_ state: WallpaperLibraryState, dark: Bool, now: Date = Date(), calendar: Calendar = .current) -> WallpaperEntry? {
        let list = candidates(state.entries, dark: dark)
        guard !list.isEmpty else { return nil }
        if state.rotation == .off { return list.first { $0.id == state.selected } ?? list.first }
        let step: Int
        switch state.rotation {
        case .off: step = 0
        case .everyTab: step = state.counter
        case .hourly: step = Int(now.timeIntervalSince1970 / 3600)
        case .daily: step = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        }
        // Shuffled, each picture still shows once before any shows again: the order is made afresh for each pass through the collection.
        let order = state.shuffle ? shuffled(list, pass: step / max(list.count, 1)) : list
        return order[((step % order.count) + order.count) % order.count]
    }

    static func shuffled(_ list: [WallpaperEntry], pass: Int) -> [WallpaperEntry] {
        list.sorted { key($0, pass) < key($1, pass) }
    }

    private static func key(_ entry: WallpaperEntry, _ pass: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(entry.id.uuidString)-\(pass)".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }
}

// MARK: - Gradient presets

/// A gradient the app draws itself. Dark ones suit light text; the light one, dark text.
struct StartPreset: Identifiable, Equatable {
    struct Stop: Equatable { var hex: String; var at: Double }
    var id: String
    var name: String
    var stops: [Stop]
    /// Degrees; 0 runs top to bottom.
    var angle: Double
    var isDark: Bool

    static let defaultID = "dusk"

    static let all: [StartPreset] = [
        StartPreset(id: "dusk", name: "Dusk", stops: [.init(hex: "141436", at: 0), .init(hex: "3A2A66", at: 0.45), .init(hex: "8A4F7D", at: 0.8), .init(hex: "D98A66", at: 1)], angle: 8, isDark: true),
        StartPreset(id: "lagoon", name: "Lagoon", stops: [.init(hex: "06222E", at: 0), .init(hex: "0B4F5C", at: 0.5), .init(hex: "2A9D8F", at: 1)], angle: 16, isDark: true),
        StartPreset(id: "ember", name: "Ember", stops: [.init(hex: "1A0B0B", at: 0), .init(hex: "5A1E1B", at: 0.5), .init(hex: "C2542D", at: 0.85), .init(hex: "F2A65A", at: 1)], angle: 10, isDark: true),
        StartPreset(id: "aurora", name: "Aurora", stops: [.init(hex: "0A1030", at: 0), .init(hex: "123D5E", at: 0.4), .init(hex: "1F8A70", at: 0.75), .init(hex: "7BD389", at: 1)], angle: 24, isDark: true),
        StartPreset(id: "graphite", name: "Graphite", stops: [.init(hex: "17181C", at: 0), .init(hex: "2A2D34", at: 0.6), .init(hex: "3E434D", at: 1)], angle: 0, isDark: true),
        StartPreset(id: "cloud", name: "Cloud", stops: [.init(hex: "E8EEF7", at: 0), .init(hex: "CFE0F5", at: 0.55), .init(hex: "F6E6EE", at: 1)], angle: 12, isDark: false),
    ]

    static func named(_ id: String) -> StartPreset { all.first { $0.id == id } ?? all[0] }

    /// A hex such as "3A2A66" (with or without a leading #); anything else is mid grey.
    static func color(_ hex: String) -> Color {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return Color(white: 0.5) }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    func gradient(shift: Double = 0) -> LinearGradient {
        let turned = (angle + shift) * .pi / 180
        // From the top toward the bottom, leaned by the angle.
        let start = UnitPoint(x: 0.5 - 0.5 * sin(turned), y: 0.5 - 0.5 * cos(turned))
        let end = UnitPoint(x: 0.5 + 0.5 * sin(turned), y: 0.5 + 0.5 * cos(turned))
        return LinearGradient(stops: stops.map { Gradient.Stop(color: Self.color($0.hex), location: $0.at) }, startPoint: start, endPoint: end)
    }
}

/// A preset on the page. With `drifting` the angle turns a few degrees, very slowly; it stands still with Reduce Motion, in Low Power Mode, with the window in the
/// background, or when the page is not on screen, and it updates twice a second.
struct StartPresetBackground: View {
    let preset: StartPreset
    let drifting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var activity = AppActivity.shared
    @State private var visible = false

    private var paused: Bool { !drifting || reduceMotion || !visible || scenePhase != .active || !activity.isActive || ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        // Twice a second is plenty: the angle moves about a quarter of a degree a second, so each step is under one colour level. (At 15 a second the app spent 5 to 7% of a
        // core on the per-tick work of the view update and the Core Animation commit, measured with `sample`; the gradient itself is drawn by the render server either way.)
        TimelineView(.animation(minimumInterval: 0.5, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Rectangle().fill(preset.gradient(shift: paused ? 0 : 14 * sin(t / 19)))
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

// MARK: - The collection on the model

@MainActor
extension BrowserModel {
    var wallpaperFolder: URL { themeFolder.appendingPathComponent("wallpapers", isDirectory: true) }

    func wallpaperURL(_ entry: WallpaperEntry) -> URL { wallpaperFolder.appendingPathComponent(entry.fileName) }

    /// Adds a picture from this device: checked, cut down, stripped of location and camera details, and kept in this profile's folder.
    func addWallpaper(from url: URL, appearance: WallpaperAppearance = .any) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard wallpaperLibrary.entries.count < WallpaperLibraryState.maxEntries else { notice = "The collection holds up to \(WallpaperLibraryState.maxEntries) pictures."; return }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 150_000_000 { notice = "That picture is too large (over 150 MB)."; return }
        guard let data = try? Data(contentsOf: url), let jpeg = WallpaperImages.prepared(data) else { notice = "That picture could not be used."; return }
        var entry = WallpaperEntry()
        entry.name = String(url.deletingPathExtension().lastPathComponent.prefix(60))
        entry.appearance = appearance
        try? FileManager.default.createDirectory(at: wallpaperFolder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: wallpaperURL(entry), options: .atomic)) != nil else { notice = "The picture could not be saved."; return }
        wallpaperLibrary.entries.append(entry)
        wallpaperLibrary.selected = entry.id
        startBackground = .image
        // The new picture is shown now, whatever its tag, so the person sees what they added.
        show(entry, data: jpeg)
    }

    /// Shows a picture from the collection and stops rotating, so it stays.
    func useWallpaper(_ entry: WallpaperEntry) {
        guard let data = try? Data(contentsOf: wallpaperURL(entry)) else { removeWallpaper(entry, dark: true); return }
        wallpaperLibrary.rotation = .off
        wallpaperLibrary.selected = entry.id
        startBackground = .image
        show(entry, data: data)
    }

    func setWallpaperAppearance(_ entry: WallpaperEntry, to appearance: WallpaperAppearance, dark: Bool) {
        guard let index = wallpaperLibrary.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        wallpaperLibrary.entries[index].appearance = appearance
        refreshWallpaper(dark: dark)
    }

    func removeWallpaper(_ entry: WallpaperEntry, dark: Bool) {
        try? FileManager.default.removeItem(at: wallpaperURL(entry))
        WallpaperThumbnails.forget(wallpaperURL(entry))
        wallpaperLibrary.entries.removeAll { $0.id == entry.id }
        if wallpaperLibrary.selected == entry.id { wallpaperLibrary.selected = nil }
        guard currentWallpaperID == entry.id else { return }
        currentWallpaperID = nil
        if wallpaperLibrary.entries.isEmpty {
            WallpaperImages.clear()
            startImageData = nil
            startAnalysis = nil
            if startBackground == .image { startBackground = .gradient }
        } else {
            refreshWallpaper(dark: dark)
        }
    }

    /// Chooses the picture for now: the right one for light or dark, and the one this moment of the rotation points at. Called when a start page appears and
    /// when the appearance changes. A picture whose file has gone is dropped from the collection and the next one is tried.
    func refreshWallpaper(dark: Bool, newPage: Bool = false) {
        // An animated wallpaper is chosen on its own picture; the collection leaves the page alone while it is on.
        guard startBackground == .image, !wallpaperLibrary.entries.isEmpty, !(startVideoOn && startHasVideo) else { return }
        if newPage, wallpaperLibrary.rotation == .everyTab { wallpaperLibrary.counter &+= 1 }
        guard let entry = WallpaperPicker.pick(wallpaperLibrary, dark: dark) else { return }
        guard entry.id != currentWallpaperID else { return }
        guard let data = try? Data(contentsOf: wallpaperURL(entry)), !data.isEmpty else {
            wallpaperLibrary.entries.removeAll { $0.id == entry.id }
            if wallpaperLibrary.selected == entry.id { wallpaperLibrary.selected = nil }
            refreshWallpaper(dark: dark)
            return
        }
        show(entry, data: data)
    }

    private func show(_ entry: WallpaperEntry, data: Data) {
        currentWallpaperID = entry.id
        startImageData = data
        analyzeStartImage()
    }

    /// Files in the collection's folder that no entry names (left by a failed save or an older version) are removed. Only when the saved collection was read, so a
    /// read that failed can never lead to deleting pictures.
    func removeOrphanedWallpapers(knownState: Bool) {
        guard knownState, let names = try? FileManager.default.contentsOfDirectory(atPath: wallpaperFolder.path) else { return }
        let kept = Set(wallpaperLibrary.entries.map(\.fileName))
        for name in names where !kept.contains(name) { try? FileManager.default.removeItem(at: wallpaperFolder.appendingPathComponent(name)) }
    }
}

/// Small pictures for the list in Customize, decoded straight from the file at thumbnail size and kept for a while.
enum WallpaperThumbnails {
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 60; return c }()

    static func image(_ url: URL) -> CGImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }

    static func forget(_ url: URL) { cache.removeObject(forKey: url.path as NSString) }
}
