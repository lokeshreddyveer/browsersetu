import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a new tab shows. Browser Setu Home is the native start page; Blank is an empty page with the address bar ready; Custom opens an address of your choice.
enum NewTabMode: String, CaseIterable, Identifiable {
    case home, blank, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Browser Setu Home"
        case .blank: "Blank Page"
        case .custom: "Custom Address"
        }
    }

    /// The address a custom new tab opens, if it is a usable web address.
    static func customURL(from text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.contains(".") == true else { return nil }
        return url
    }
}

enum StartColor {
    static let defaultA = "#1B2A4A"
    static let defaultB = "#0C0F17"

    /// "#RRGGBB" to its parts, or nil if it is not that.
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(r: Double, g: Double, b: Double) -> String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    static func color(_ hex: String, fallback: String = defaultA) -> Color {
        let c = components(hex) ?? components(fallback) ?? (0, 0, 0)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func hex(of color: Color) -> String {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return hex(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return hex(r: Double(r), g: Double(g), b: Double(b))
        #endif
    }
}

@MainActor
extension BrowserModel {
    /// Replaces a favorite's address and name, keeping its place in the row.
    func editFavorite(_ old: String, address: String, name: String) {
        guard let url = NewTabMode.customURL(from: address) else { notice = "That does not look like a website address."; return }
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host ?? address) : name
        if url.absoluteString == old {
            try? core.addBookmark(url: old, title: title, folder: Self.favoritesFolder)
            refreshBookmarkState()
            objectWillChange.send()
            return
        }
        addFavorite(address: url.absoluteString, name: title)
        moveFavorite(url.absoluteString, before: old)
        removeFavorite(old)
    }
}

struct NewTabSettings: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Picker("New tabs open", selection: $model.newTabMode) {
            ForEach(NewTabMode.allCases) { Text($0.title).tag($0) }
        }
        if model.newTabMode == .custom {
            TextField("https://www.google.com/", text: $model.newTabURL).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            if NewTabMode.customURL(from: model.newTabURL) == nil {
                Label("Use a full web address. Until then new tabs open Browser Setu Home.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        Text(model.newTabMode == .blank ? "A new tab is empty and the address bar is ready for typing. Private tabs always show their own page."
             : (model.newTabMode == .custom ? "Every new tab in a normal window opens this address. Private tabs still show their own page." : "A search box, your favorites and nothing fetched from the network until you ask."))
            .font(.caption).foregroundStyle(.secondary)
    }
}


/// How the start page looks, beyond colours: a few plain choices.
enum StartFont: String, CaseIterable, Identifiable {
    case rounded, standard, serif
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var design: Font.Design { self == .rounded ? .rounded : (self == .serif ? .serif : .default) }
}

enum StartSearchStyle: String, CaseIterable, Identifiable {
    case pill, rounded, square
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var radius: CGFloat { self == .pill ? 28 : (self == .rounded ? 14 : 6) }
}

enum StartWidth: String, CaseIterable, Identifiable {
    case narrow, standard, wide
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Relative to the standard width.
    var factor: CGFloat { self == .narrow ? 0.78 : (self == .wide ? 1.25 : 1) }
}
