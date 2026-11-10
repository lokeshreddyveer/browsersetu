import SwiftUI
import UniformTypeIdentifiers

// The parts of the Customize panel for the wallpaper collection, the gradient presets, the animated wallpaper and the effects. The panel itself (the section chips and the
// older controls) is in ThemeTools.swift.

enum StartCustomizeSection: String, CaseIterable, Identifiable {
    case wallpaper, appearance, layout, effects, privacy
    var id: String { rawValue }
    var title: String {
        switch self { case .wallpaper: "Wallpaper"; case .appearance: "Appearance"; case .layout: "Layout"; case .effects: "Effects"; case .privacy: "Privacy" }
    }
}

/// The collection: add pictures, tag each for light or dark, choose how it rotates.
struct WallpaperCollectionControls: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @State private var adding = false
    @State private var addingAppearance = WallpaperAppearance.any

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Collection").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.wallpaperLibrary.entries.count) of \(WallpaperLibraryState.maxEntries)").font(.caption).foregroundStyle(.secondary)
            }
            if model.wallpaperLibrary.entries.isEmpty {
                Text("Add pictures from this device. Tag each for light or dark mode, and the page changes picture with the appearance. Pictures stay in this profile, on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.wallpaperLibrary.entries.contains(where: { $0.appearance != .any }) {
                Text("A picture tagged for the current appearance is shown before any tagged for either.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.wallpaperLibrary.entries.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(model.wallpaperLibrary.entries) { entry in tile(entry) }
                }
            }
            HStack {
                Menu {
                    ForEach(WallpaperAppearance.allCases) { appearance in
                        Button(appearance.title) { addingAppearance = appearance; adding = true }
                    }
                } label: { Label("Add Picture…", systemImage: "plus") }
                .menuStyle(.button).fixedSize()
                Text("for").font(.caption).foregroundStyle(.secondary)
                Text(addingAppearance.title).font(.caption).foregroundStyle(.secondary)
            }
            if model.wallpaperLibrary.entries.count > 1 {
                Picker("Change picture", selection: $model.wallpaperLibrary.rotation) {
                    ForEach(WallpaperRotation.allCases) { Text($0.title).tag($0) }
                }
                if model.wallpaperLibrary.rotation != .off {
                    Toggle("Shuffle (each picture shows once before any repeats)", isOn: $model.wallpaperLibrary.shuffle)
                }
            }
            Text("Every day or hour chooses a picture from your own collection by the clock. Nothing is downloaded.").font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $adding, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { model.addWallpaper(from: url, appearance: addingAppearance) }
        }
    }

    private func tile(_ entry: WallpaperEntry) -> some View {
        let current = model.currentWallpaperID == entry.id
        return Button { model.useWallpaper(entry) } label: {
            ZStack(alignment: .bottomLeading) {
                if let cg = WallpaperThumbnails.image(model.wallpaperURL(entry)) {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill().frame(height: 58).clipped()
                } else {
                    Color.primary.opacity(0.08).frame(height: 58)
                }
                if entry.appearance != .any {
                    Image(systemName: entry.appearance == .dark ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(4)
                        .background(Circle().fill(Color.black.opacity(0.5))).padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(current ? Theme.accent : Color.primary.opacity(0.15), lineWidth: current ? 2.5 : 0.8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Use This Picture") { model.useWallpaper(entry) }
            Menu("Show in") {
                ForEach(WallpaperAppearance.allCases) { appearance in
                    Button(appearance.title) { model.setWallpaperAppearance(entry, to: appearance, dark: dark) }
                }
            }
            Divider()
            Button("Remove from Collection", role: .destructive) { model.removeWallpaper(entry, dark: dark) }
        }
        .accessibilityLabel("\(entry.name.isEmpty ? "Picture" : entry.name), shown in \(entry.appearance.title.lowercased())\(current ? ", showing now" : "")")
        .accessibilityHint("Press to use it. Touch and hold or right-click for more.")
    }
}

/// The built-in gradients, drawn by the app.
struct StartPresetControls: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                ForEach(StartPreset.all) { preset in
                    let selected = model.startPreset == preset.id
                    Button { animated(.easeOut(duration: 0.18)) { model.startPreset = preset.id } } label: {
                        VStack(spacing: 6) {
                            Rectangle().fill(preset.gradient()).frame(height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 0.8))
                            Text(preset.name).font(.caption).foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.name) gradient\(selected ? ", selected" : "")")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Toggle("Let the gradient drift slowly", isOn: $model.startAnimatedGradient)
            Text("A slow turn of a few degrees at no more than 15 frames a second. It stops with Reduce Motion, in Low Power Mode, when the window is in the background and when the page is not on screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// An animated wallpaper from this device.
struct StartVideoControls: View {
    @EnvironmentObject var model: BrowserModel
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animated wallpaper").font(.subheadline.weight(.semibold))
            HStack {
                Button(model.startHasVideo ? "Change Loop…" : "Choose a Loop…") { choosing = true }
                if model.startHasVideo { Button("Remove", role: .destructive) { model.removeStartVideo() } }
            }
            if model.startHasVideo { Toggle("Play it", isOn: $model.startVideoOn) }
            Text("A short video from this device (up to a minute), played without sound over its first picture. It uses more battery and memory. It stops in Low Power Mode, with Reduce Motion on, in private tabs, when the window is in the background and when the page is not on screen. One player is shared by every start page.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { Task { await model.setStartVideo(from: url) } }
        }
    }
}

/// The effects, each off unless it is wanted.
struct StartEffectsControls: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Soft glow from the picture's colours", isOn: $model.startLook.ambient)
            #if os(macOS)
            Toggle("Soft light that follows the pointer", isOn: $model.startLook.pointerGlow)
            Toggle("Picture drifts slightly with the pointer", isOn: $model.startLook.parallax)
            #else
            Toggle("Picture shifts slightly as you tilt the device", isOn: $model.startLook.motion)
            Toggle("Soft light under a pointer (iPad)", isOn: $model.startLook.pointerGlow)
            #endif
            Text("These work with a picture on the page. A flat picture has no real depth, so the shift is a few points, not a 3D effect. Every one stops with Reduce Motion and in Low Power Mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the page uses, said plainly, and the sections that draw on your browsing.
struct StartPrivacyControls: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wallpapers never use the network", systemImage: "wifi.slash").font(.subheadline.weight(.semibold))
            Text("Your pictures, gradients and loops stay in this profile's folder on this device. Nothing is downloaded, uploaded or looked up for them, and no picture's name or place is sent anywhere. Pictures lose their camera and location details when they are added.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Sections that draw on your browsing").font(.subheadline.weight(.semibold))
            Toggle("Continue browsing", isOn: $model.showContinue)
            Toggle("Often visited", isOn: $model.showFrequent)
            Toggle("Recently closed", isOn: $model.showRecentlyClosed)
            Text("These never appear in a private tab. Each profile keeps its own choices.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
