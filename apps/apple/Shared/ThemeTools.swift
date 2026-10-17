import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

// MARK: - Colour maths

extension RGB {
    /// "#RRGGBB".
    var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// From "#RRGGBB" or "RRGGBB"; nil for anything else.
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// WCAG relative luminance (the version that treats the colour channels as light, not as stored numbers).
    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// How different two colours look, from 1 (the same) to 21 (black on white). 3 is the least WCAG asks for large text and icons.
    func contrast(with other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour moved toward white or black, as little as it takes, until it can be seen against `background`.
    func readable(against background: RGB, minimum: Double = 3) -> RGB {
        guard contrast(with: background) < minimum else { return self }
        let towardWhite = background.relativeLuminance < 0.4
        var out = self
        for _ in 0..<30 {
            out = out.shifted(towardWhite ? 0.06 : -0.06)
            if out.contrast(with: background) >= minimum { break }
        }
        return out
    }
}

/// The main colour of a picture, chosen to be an accent: vivid, not too dark and not too pale.
enum ThemeColor {
    static func dominantAccent(from data: Data) -> RGB? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            guard high > 0.2, delta > 0.12 else { continue }              // black, white and grey say nothing about colour
            let saturation = delta / high
            guard saturation > 0.25 else { continue }
            var hue: Double
            if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) } else if high == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
            hue = hue < 0 ? hue + 6 : hue
            let bin = min(bins - 1, Int(hue / 6 * Double(bins)))
            let w = saturation * high
            weight[bin] += w
            sums[bin].0 += r * w; sums[bin].1 += g * w; sums[bin].2 += b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return nil }
        let total = weight[best]
        let average = RGB(sums[best].0 / total, sums[best].1 / total, sums[best].2 / total)
        return vivid(average)
    }

    /// Keeps the hue; makes it saturated and bright enough to work as an accent.
    static func vivid(_ c: RGB) -> RGB {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b)
        guard high > 0 else { return c }
        let saturation = max((high - low) / high, 0.55)
        let value = min(max(high, 0.62), 0.95)
        let scale = value / high
        let r = c.r * scale, g = c.g * scale, b = c.b * scale
        let top = max(r, g, b)
        func lift(_ x: Double) -> Double { top - (top - x) * (saturation / max((top - min(r, g, b)) / top, 0.01)).clamped(to: 0...1.6) }
        return RGB(lift(r).clamped(to: 0...1), lift(g).clamped(to: 0...1), lift(b).clamped(to: 0...1))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Theme files

/// A theme as a small JSON file, to share or keep: only colours and the mood. A photo is never part of it.
struct ThemeFile: Codable, Equatable {
    var format = "browsersetu-theme"
    var version = 1
    var name: String
    var accent: String
    var top: String
    var bottom: String
    var glow: String?
    var chrome: String?
    var scheme: String?
    var decoration: String?

    static let maxBytes = 20_000

    init(_ theme: BrowserTheme) {
        name = theme.name
        accent = theme.accent.hexString; top = theme.top.hexString; bottom = theme.bottom.hexString; glow = theme.glow.hexString
        chrome = theme.chrome?.hexString
        scheme = theme.scheme.map { $0 == .light ? "light" : "dark" }
        decoration = theme.decoration.rawValue
    }

    /// The theme this file describes, or nil if it is not one (wrong format, a colour that is not a colour, no name).
    func theme(id: String) -> BrowserTheme? {
        guard format == "browsersetu-theme", version == 1 else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let accent = RGB(hexString: accent), let top = RGB(hexString: top), let bottom = RGB(hexString: bottom) else { return nil }
        let glowColor = glow.flatMap(RGB.init(hexString:))
        let chromeColor = chrome.flatMap(RGB.init(hexString:))
        if (glow != nil && glowColor == nil) || (chrome != nil && chromeColor == nil) { return nil }
        let light: Bool
        let mode: AppearanceMode?
        switch scheme {
        case "light": mode = .light; light = true
        case "dark": mode = .dark; light = false
        case nil: mode = nil; light = top.luminance > 0.6
        default: return nil
        }
        return BrowserTheme(id: id, name: String(clean.prefix(40)), note: "From a theme file", accent: accent,
                            chrome: chromeColor ?? top.shifted(light ? -0.04 : -0.35), top: top, bottom: bottom, glow: glowColor ?? accent.shifted(-0.55),
                            scheme: mode, decoration: decoration.flatMap(ThemeDecoration.init(rawValue:)) ?? .none, family: "Yours")
    }

    func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct UserTheme: Codable, Equatable, Identifiable {
    var id: String
    var file: ThemeFile
    var theme: BrowserTheme? { file.theme(id: id) }
}

struct ThemeFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension BrowserModel {
    var allThemes: [BrowserTheme] { BrowserTheme.all + BrowserTheme.palettes + userThemes.compactMap(\.theme) }

    func userTheme(id: String) -> BrowserTheme? { userThemes.first { $0.id == id }?.theme }

    func saveUserThemes() { saveSetting("user_themes", encodedMap(["list": userThemes])) }

    /// Adds a theme from a file and switches to it. Returns why not, if it could not.
    @discardableResult
    func importTheme(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= ThemeFile.maxBytes else { return "That file is not a theme (or it is too big)." }
        return importTheme(data: data)
    }

    @discardableResult
    func importTheme(data: Data) -> String? {
        guard data.count <= ThemeFile.maxBytes, let file = try? JSONDecoder().decode(ThemeFile.self, from: data) else { return "That file is not a Browser Setu theme." }
        guard userThemes.count < 24 else { return "You already have 24 imported themes. Delete one first." }
        var taken = Set(allThemes.map(\.name))
        var named = file
        named.name = String(file.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var n = 2
        let base = named.name
        while taken.contains(named.name) { named.name = "\(base) \(n)"; n += 1 }
        taken.insert(named.name)
        let id = "user-" + UUID().uuidString.prefix(8).lowercased()
        guard UserTheme(id: id, file: named).theme != nil else { return "That theme file has a colour that could not be read." }
        userThemes.append(UserTheme(id: id, file: named))
        saveUserThemes()
        themeID = id
        notice = "Added the theme “\(named.name)”."
        return nil
    }

    func deleteUserTheme(_ id: String) {
        userThemes.removeAll { $0.id == id }
        saveUserThemes()
        if themeID == id { themeID = "midnight" }
    }

    /// Copies a theme's colours into the Custom theme, so a ready-made look can be adjusted.
    func editAsCustom(_ theme: BrowserTheme) {
        var value = customTheme
        value.accent = theme.accent; value.top = theme.top; value.bottom = theme.bottom
        setCustomTheme(value)
        themeID = "custom"
    }

    /// Takes the accent from the background photo. Returns false if the picture has no colour to take (a grey photo).
    @discardableResult
    func matchAccentToPhoto() -> Bool {
        guard let data = themePhoto, let found = ThemeColor.dominantAccent(from: data) else { return false }
        var value = customTheme
        value.accent = found.readable(against: value.top)
        setCustomTheme(value)
        return true
    }

    func loadUserThemes() {
        userThemes = (Self.decodeMap((try? core.getSetting(key: "user_themes")) ?? nil, as: [UserTheme].self)["list"] ?? []).filter { $0.theme != nil }.prefix(24).map { $0 }
        startTile = StartTile(rawValue: ((try? core.getSetting(key: "start_tile")) ?? nil) ?? "") ?? .regular
    }

    // MARK: A style sheet for every website

    static let globalStyleKey = "*"

    var globalStyle: String { siteStyles[Self.globalStyleKey] ?? "" }

    func setGlobalStyle(_ css: String) {
        var map = siteStyles
        let trimmed = String(css.prefix(20_000))
        map[Self.globalStyleKey] = trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmed
        setSiteStyles(map)
        for tab in tabs { tab.applySiteStyle() }
    }
}

enum StartTile: String, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var points: CGFloat { switch self { case .small: 44; case .regular: 52; case .large: 62 } }
}

// MARK: - Settings pieces

/// Import, export and the contrast check for the theme in use.
struct ThemeToolsRows: View {
    @EnvironmentObject var model: BrowserModel
    @State private var importing = false
    @State private var exporting = false
    @State private var document = ThemeFileDocument(data: Data())

    var body: some View {
        Group {
            HStack {
                Button("Import a Theme…") { importing = true }
                Button("Export This Theme…") { document = ThemeFileDocument(data: ThemeFile(model.activeTheme).data()); exporting = true }
                if model.themeIsActive, model.themeID != "custom" { Button("Edit as Custom") { model.editAsCustom(model.activeTheme) } }
            }
            .buttonStyle(.borderless)
            if model.themeID.hasPrefix("user-") { Button("Delete This Imported Theme", role: .destructive) { model.deleteUserTheme(model.themeID) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, let problem = model.importTheme(from: url) { model.notice = problem }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: model.activeTheme.name + " theme") { _ in }
    }
}

/// One stylesheet applied to every website, under each site's own.
struct GlobalStyleSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced)).frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .onChange(of: text) { _, new in
                    guard loaded else { return }
                    saveTask?.cancel()
                    saveTask = Task { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { model.setGlobalStyle(new) } }
                }
            if text.count > 18_000 { Text("\(text.count.formatted()) of 20,000 characters").font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Style Sheet for Every Website")
        } footer: {
            Text("CSS applied to every page you open, before a site's own style sheet in Site Privacy. For example, hide a cookie banner or a sticky header: .cookie-banner { display: none }. Saved as you type. It only changes how pages look on this device.")
        }
        .onAppear { text = model.globalStyle; loaded = true }
    }
}

// MARK: - The start page's side panel

/// Customize, right where you are: themes, accent, what the start page shows and the search engine. Everything applies the moment it is touched; there is nothing to save.
struct StartDrawer: View {
    @EnvironmentObject var model: BrowserModel

    private func close() { animated(.easeOut(duration: 0.22)) { model.startDrawerOpen = false } }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.38).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                panel
                    .frame(width: min(340, geo.size.width - 36))
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Customize start page")
                    .accessibilityAddTraits(.isModal)
            }
        }
        #if os(macOS)
        .onExitCommand { close() }
        #endif
    }

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Customize").font(.title3.weight(.semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).accessibilityLabel("Close") }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                group("Appearance") {
                    Text(model.activeTheme.name).font(.callout).foregroundStyle(.secondary)
                    ThemeDots()
                    if !model.themeIsActive {
                        HStack(spacing: 10) {
                            ForEach(AccentChoice.allCases) { choice in
                                Button { model.accent = choice } label: {
                                    Circle().fill(choice.color).frame(width: 24, height: 24)
                                        .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).opacity(model.accent == choice ? 1 : 0))
                                }
                                .buttonStyle(.plain).accessibilityLabel("\(choice.title) accent\(model.accent == choice ? ", selected" : "")")
                            }
                        }
                    }
                    Picker("Background", selection: $model.startBackground) { ForEach(StartBackground.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                group("Layout") {
                    Toggle("Greeting", isOn: $model.showGreeting)
                    Toggle("Favorites", isOn: $model.showFavorites)
                    Toggle("Continue browsing", isOn: $model.showContinue)
                    Toggle("Often visited", isOn: $model.showFrequent)
                    Toggle("Recently closed", isOn: $model.showRecentlyClosed)
                    Picker("Icon size", selection: $model.startTile) { ForEach(StartTile.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                group("Behavior") {
                    HStack { Text("Search engine"); Spacer(); SearchEngineMenu() }
                }
                Button("More Settings…") {
                    close()
                    #if os(macOS)
                    SettingsRouter.open(.appearance)
                    #else
                    model.sheet = .settings
                    #endif
                }
                .buttonStyle(.borderless)
            }
            .toggleStyle(.switch)
            .padding(20)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }
}

/// Every theme as a round swatch (its own two background colours, with its accent in the middle); a tick marks the one in use.
struct ThemeDots: View {
    @EnvironmentObject var model: BrowserModel
    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 10)]

    var body: some View {
        let themes = [BrowserTheme.midnight] + model.allThemes.filter { $0.id != "midnight" } + [model.customTheme.theme]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(themes) { theme in
                let selected = model.themeID == theme.id
                Button { animated(.easeOut(duration: 0.2)) { model.chooseTheme(theme.id) } } label: {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [theme.top.color, theme.bottom.color], startPoint: .top, endPoint: .bottom))
                        Circle().fill(theme.accent.color).frame(width: 12, height: 12)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent.luminance > 0.6 ? Color.black : Color.white)
                            .offset(x: 0, y: 0).opacity(selected ? 1 : 0).scaleEffect(selected ? 1 : 0.5)
                    }
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(selected ? theme.accent.color : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 0.5).padding(-3))
                }
                .buttonStyle(.plain)
                .help(theme.name)
                .accessibilityLabel("\(theme.name) theme\(selected ? ", selected" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 3)
    }
}
