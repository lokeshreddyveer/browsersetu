import SwiftUI

private struct StartBottomInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct StartTopInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct StartOverPhotoKey: EnvironmentKey { static let defaultValue = false }
private struct StartPointerGlowKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    /// The soft pointer light is on: glass controls also catch a small highlight on their edge where the pointer is.
    var startPointerGlow: Bool {
        get { self[StartPointerGlowKey.self] }
        set { self[StartPointerGlowKey.self] = newValue }
    }

    /// The page is drawn over the person's own picture: cards and the search field become glass instead of solid tints.
    var startOverPhoto: Bool {
        get { self[StartOverPhotoKey.self] }
        set { self[StartOverPhotoKey.self] = newValue }
    }
}
extension EnvironmentValues {
    /// Room the page leaves at its head for a bar that floats over it (the iPhone's bar layouts with the bar at the top).
    var startTopInset: CGFloat {
        get { self[StartTopInsetKey.self] }
        set { self[StartTopInsetKey.self] = newValue }
    }
    /// Room the page leaves at its foot for a toolbar that floats over it (the iPhone's dock).
    var startBottomInset: CGFloat {
        get { self[StartBottomInsetKey.self] }
        set { self[StartBottomInsetKey.self] = newValue }
    }
}

/// The page a blank tab shows. Quiet and fast: the day and a greeting, one large search field, your favorites as cards, one card to carry on where you
/// were, the places you go often, and a single honest line about protection at the foot. Long lists show a few and say how many more there are. It is plain
/// SwiftUI over the browser's own data (bookmarks, history, tabs); there is no web view behind it, and nothing on it is fetched from the network except site
/// icons you allow.
struct StartPageView: View {
    @EnvironmentObject var model: BrowserModel
    let isPrivate: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startBottomInset) private var bottomInset
    @Environment(\.startTopInset) private var topInset
    @State private var addingFavorite = false
    /// The first visit after setup: a welcome in the greeting and a burst of confetti, once for this profile.
    @State private var welcoming = false
    @State private var confetti = false
    @State private var newURL = ""
    @State private var newName = ""
    /// Held, not observed: only the background redraws when the pointer moves.
    @State private var pointer = StartPointer()
    /// The collection's picture is chosen once for each page that appears (a new tab moves a rotation on; coming back to this one does not).
    @State private var choseWallpaper = false
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var activity = AppActivity.shared
    #if os(iOS)
    @StateObject private var voice = VoiceSearch()
    @State private var motion = StartMotion()
    #endif

    /// The person's own picture is behind the page.
    private var overPhoto: Bool { !isPrivate && model.startBackground == .image && model.startImageData != nil }
    /// A picture or a gradient preset is behind the page: cards and buttons are glass, and ink follows what is behind.
    private var overArt: Bool { overPhoto || (!isPrivate && model.startBackground == .preset) }

    /// Over a picture or a preset, text and glass take light or dark ink to suit the middle of it, whatever the system appearance is; everywhere else they follow the system.
    private var contentScheme: ColorScheme {
        guard overArt, model.startLook.adaptiveText else { return scheme }
        if model.startBackground == .preset { return StartPreset.named(model.startPreset).isDark ? .dark : .light }
        guard let dark = StartReadability.prefersDarkInk(model.startAnalysis, dim: model.startImageDim, brightness: model.startLook.brightness) else { return scheme }
        return dark ? .light : .dark
    }

    private var playsVideo: Bool {
        overPhoto && AnimatedWallpaperRules.mayPlay(switchedOn: model.startVideoOn, hasVideo: model.startHasVideo, isPrivate: isPrivate, reduceMotion: reduceMotion,
                                                    lowPower: lowPower, windowActive: scenePhase == .active && activity.isActive, onScreen: onScreen)
    }

    /// The Customize size choice scales the greeting and the search box as well as the site tiles.
    private var startScale: CGFloat { model.startTile.points / 52 }

    private var accent: Color { isPrivate ? Theme.privateAccent : Theme.accent }

    #if os(macOS)
    private var contentWidth: CGFloat { 720 * model.startWidth.factor }
    #else
    private var contentWidth: CGFloat { 640 * model.startWidth.factor }
    #endif

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if model.newTabMode == .blank && !isPrivate {
                    Color.clear.frame(height: geo.size.height).accessibilityHidden(true)
                } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    VStack(spacing: 30) {
                        VStack(spacing: 24) {
                            greeting
                            heroSearch
                        }
                        .startEntrance(0)
                        // Above everything below it: the suggestions open over the favorites and the cards, and they were being drawn under them.
                        .zIndex(10)
                        if isPrivate {
                            privateNote
                        } else {
                            if model.showFavorites { FavoritesGrid(addingFavorite: $addingFavorite).startEntrance(1) }
                            #if os(macOS)
                            if model.showFavorites && model.favorites.isEmpty { GettingStartedStrip().startEntrance(1) }
                            #endif
                            if model.showContinue, let tab = model.continueTab { ContinueCard(tab: tab).startEntrance(2) }
                            if model.showFrequent || model.showRecentlyClosed { HistoryChips().startEntrance(3) }
                            if !model.inbox.isEmpty { SentToThisDevice() }
                            if !model.remoteTabs.isEmpty { OtherDeviceTabs() }
                        }
                    }
                    Spacer(minLength: 28)
                    if !isPrivate {
                        HStack(spacing: 10) {
                            PrivacyLine()
                            Menu { ToolsMenuItems(model: model) } label: {
                                Image(systemName: "wrench.and.screwdriver").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                                    .startChip()
                                    .accessibilityLabel("Tools")
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            CustomizeMenu()
                        }
                        .startEntrance(4)
                        .padding(.top, 20)
                        .padding(.bottom, bottomInset)
                        .padding(.top, topInset)
                    }
                }
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, 24).padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            // One screen when it fits; it scrolls (and never clips) on a small phone, in landscape, or with large text.
            .scrollBounceBehavior(.basedOnSize)
            .environment(\.colorScheme, contentScheme)
            .environment(\.startOverPhoto, overArt)
            .environment(\.startPointerGlow, overArt && model.startLook.pointerGlow)
        }
        #if os(macOS)
        .onContinuousHover { phase in
            guard overPhoto, model.startLook.pointerGlow || model.startLook.parallax else { if pointer.point != nil { pointer.point = nil }; return }
            switch phase {
            case .active(let location): pointer.point = location
            case .ended: pointer.point = nil
            }
        }
        #endif
        .background(background)
        .motion(.easeOut(duration: 0.25), value: model.startBackground)
        .onAppear {
            onScreen = true
            #if DEBUG
            WallpaperDebug.visibleStartPages += 1
            WallpaperDebug.log("start page appeared (visible \(WallpaperDebug.visibleStartPages))")
            #endif
            AppActivity.shared.recheck()
            if !choseWallpaper { choseWallpaper = true; if !isPrivate { model.refreshWallpaper(dark: scheme == .dark, newPage: true) } }
            #if os(iOS)
            updateMotion()
            #endif
        }
        .onDisappear {
            onScreen = false
            #if DEBUG
            WallpaperDebug.visibleStartPages = max(0, WallpaperDebug.visibleStartPages - 1)
            WallpaperDebug.log("start page disappeared (visible \(WallpaperDebug.visibleStartPages))")
            #endif
            #if os(iOS)
            motion.stop(from: pointer)
            #endif
        }
        #if DEBUG
        .onChange(of: playsVideo) { _, now in
            WallpaperDebug.log("playsVideo=\(now) [photo=\(overPhoto) on=\(model.startVideoOn) has=\(model.startHasVideo) reduce=\(reduceMotion) low=\(lowPower) scene=\(scenePhase == .active) activity=\(activity.isActive) onScreen=\(onScreen)]")
        }
        #endif
        // Light and dark can have their own pictures; changing the appearance changes the picture.
        .onChange(of: scheme) { _, now in if !isPrivate { model.refreshWallpaper(dark: now == .dark) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        #if os(iOS)
        .onChange(of: model.startLook.motion) { _, _ in updateMotion() }
        .onChange(of: lowPower) { _, _ in updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
        .onChange(of: activity.isActive) { _, _ in updateMotion() }
        #endif
        .alert("Add Favorite", isPresented: $addingFavorite) {
            TextField("Website address", text: $newURL)
            TextField("Name (optional)", text: $newName)
            Button("Add") { model.addFavorite(address: newURL, name: newName); newURL = ""; newName = "" }
            Button("Cancel", role: .cancel) { newURL = ""; newName = "" }
        }
        .overlay { if model.startDrawerOpen, !isPrivate { StartDrawer() } }
        // The first visit after setup is a small celebration: a burst of confetti over the page and a welcome where the greeting is.
        .overlay { if confetti { SetupConfetti().transition(.opacity) } }
        .onChange(of: model.showSetup) { _, now in if !now { celebrateFirstVisit() } }
        .accessibilityIdentifier("start-page")
    }

    /// Once for this profile, and only right after the setup assistant closes.
    private func celebrateFirstVisit() {
        guard !isPrivate, model.settingValue("start_welcomed") != "1" else { return }
        model.saveSetting("start_welcomed", "1")
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { welcoming = true; confetti = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.2))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { confetti = false }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { welcoming = false }
        }
    }

    #if os(iOS)
    /// Tilt reaches the picture only when it is asked for, and never in Low Power Mode, with Reduce Motion on, or in a private tab.
    private func updateMotion() {
        if overPhoto, model.startLook.motion, !lowPower, !reduceMotion, onScreen, activity.isActive { motion.start(into: pointer) } else { motion.stop(from: pointer) }
    }
    #endif

    // MARK: Pieces

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let word = switch hour { case 5..<12: "Good morning"; case 12..<17: "Good afternoon"; case 17..<22: "Good evening"; default: "Good night" }
        let custom = model.startTitle.trimmingCharacters(in: .whitespaces)
        let title = isPrivate ? "Private Browsing" : (welcoming ? "Welcome to Browser Setu" : (!custom.isEmpty ? custom : (model.showGreeting ? word : "Browser Setu")))
        return VStack(spacing: 6) {
            if !isPrivate { SetuLockup(size: 12, latin: false).padding(.bottom, 10) }
            if !isPrivate, model.showGreeting || welcoming {
                Text(welcoming ? "You’re all set" : Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12, weight: .semibold)).tracking(0.9).textCase(.uppercase)
                    // The accent colour is not chosen for the picture behind it (teal on green was hard to read): over a picture the date takes the page's ink.
                    .foregroundStyle(overArt ? AnyShapeStyle(Color.primary.opacity(0.78)) : AnyShapeStyle(accent.opacity(0.9)))
            }
            Text(title)
                .font(.system(size: 34 * startScale, weight: .semibold, design: model.startFont.design)).foregroundStyle(.primary.opacity(0.92))
                .minimumScaleFactor(0.7).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .motion(.easeOut(duration: 0.2), value: model.startTile)
    }

    /// On the Mac this is a real text field of its own: clicking it keeps focus and typing in the page, with suggestions right under it. The
    /// top address bar is a separate field with its own focus; both use the same search, suggestion and navigation code. On the iPhone a tap
    /// opens the search panel, which is the same thing there.
    @ViewBuilder private var heroSearch: some View {
        #if os(macOS)
        StartSearchField()
        #else
        if UIDevice.current.userInterfaceIdiom == .phone, !model.topBarHidden, !model.chromeCollapsed {
            // In the bar layouts the address bar is on screen already: a second search box under it was a second place to type. Only the voice button stays.
            VoiceButton(voice: voice, round: true)
                .onAppear { voice.onFinish = { words in model.navigate(input: words) } }
                .onChange(of: voice.problem) { _, message in if let message { model.notice = message; voice.problem = nil } }
        } else {
        HStack(spacing: 8) {
        Button { model.openSearchPanel() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17 * startScale, weight: .medium)).foregroundStyle(accent)
                Text("Search or enter address").font(.system(size: 16 * startScale)).foregroundStyle(.secondary)
                Spacer()
                EngineBadge()
            }
            .padding(.horizontal, 18).frame(height: 56)
            .startField(radius: model.startSearchStyle.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search or enter address")
        .accessibilityIdentifier("start-search")
        VoiceButton(voice: voice, round: true)
        }
        .onAppear { voice.onFinish = { words in model.navigate(input: words) } }
        .onChange(of: voice.problem) { _, message in if let message { model.notice = message; voice.problem = nil } }
        // While a search is being typed, the one real field is the only field.
        .opacity(model.floatingAddressVisible ? 0 : 1)
        .motion(.easeOut(duration: 0.18), value: model.floatingAddressVisible)
        }
        #endif
    }

    private var privateNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing here is saved", systemImage: "eye.slash").font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
            Text("This tab keeps no history, cookies or session data once closed.")
            Text("Private browsing does not hide your activity from websites, your network or your employer.").foregroundStyle(.secondary)
        }
        .scaledFont(14)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
    }

    /// Midnight charcoal with a barely perceptible blue tint in the middle.
    private var background: some View {
        Group {
            if isPrivate { Color.platformBackground }
            else if model.startBackground == .image {
                if let data = model.startImageData {
                    // Two pictures cross-fade (old out, new in) with no black frame between; with Reduce Motion the change is immediate. The decoded pictures come
                    // from the cache, so nothing is decoded while it fades.
                    let identity = WallpaperImages.identity(data)
                    ZStack {
                        StartBackdrop(data: data, look: model.startLook, dim: model.startImageDim, blur: model.startImageBlur, analysis: model.startAnalysis, pointer: pointer, playsVideo: playsVideo)
                            .id(identity)
                            .transition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: identity)
                } else if scheme == .dark { Color(red: 0.047, green: 0.059, blue: 0.090) } else { DaylightBackdrop() }
            }
            else if model.startBackground == .preset { StartPresetBackground(preset: StartPreset.named(model.startPreset), drifting: model.startAnimatedGradient) }
            else if model.startBackground == .color { StartColor.color(model.startColorA) }
            else if model.startBackground == .blend {
                LinearGradient(colors: [StartColor.color(model.startColorA), StartColor.color(model.startColorB, fallback: StartColor.defaultB)], startPoint: .top, endPoint: .bottom)
            }
            else if model.startBackground == .plain {
                // Plain: one flat colour, no glow, decoration or photo.
                if model.themeIsActive { model.activeTheme.top.color } else if scheme == .dark { Color(red: 0.047, green: 0.059, blue: 0.090) } else { Color.platformBackground }
            }
            else if model.themeIsActive { ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim) }
            else if scheme == .dark {
                ZStack {
                    Color(red: 0.047, green: 0.059, blue: 0.090)                       // #0C0F17
                    if let data = BundledBackdrops.data("earthset"), let image = Image(platformData: data) {
                        // A real photograph, slowly drifting, darkened so the page on top stays easy to read.
                        DriftingPhoto(image: image)
                            .overlay(LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.66)], startPoint: .top, endPoint: .bottom))
                    } else {
                        RadialGradient(colors: [StartTone.glow().opacity(0.85), .clear],   // #111B30
                                       center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
                    }
                    SetuArcs()
                }
                .clipped()
            } else {
                ZStack { DaylightBackdrop(); SetuArcs() }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared style

/// The card every block of the page sits on: the theme's raised colour when a theme is in use, otherwise a soft tint of the text colour, with a hairline edge.
private struct StartCardStyle: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startOverPhoto) private var overPhoto
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparencySetting
    @Environment(\.colorSchemeContrast) private var contrast
    /// Reduce Transparency, and Increase Contrast, both make the glass solid.
    private var reduceTransparency: Bool { reduceTransparencySetting || contrast == .increased }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if overPhoto && ThemeState.raised == nil {
            // Over the person's picture: a quiet glass (or, with Reduce Transparency, a solid tint), with a thin lit edge at the top.
            content
                .background {
                    if reduceTransparency { shape.fill(scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(white: 0.96)) }
                    else { shape.fill(.ultraThinMaterial) }
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.5), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
                .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.10), radius: 8, y: 2)
                .modifier(StartSpecular(radius: radius))
        } else {
            content
                .background(shape.fill(ThemeState.raised?.opacity(0.62) ?? Color.primary.opacity(scheme == .dark ? 0.075 : 0.05)))
                .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.07), lineWidth: 0.5))
        }
    }
}

/// The large search field's surface: slightly brighter than a card, with a soft shadow, so it is the first thing the eye lands on.
private struct StartFieldStyle: ViewModifier {
    var radius: CGFloat = 28
    var focused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startOverPhoto) private var overPhoto
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparencySetting
    @Environment(\.colorSchemeContrast) private var contrast
    /// Reduce Transparency, and Increase Contrast, both make the glass solid.
    private var reduceTransparency: Bool { reduceTransparencySetting || contrast == .increased }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if overPhoto && ThemeState.raised == nil {
            // Clear glass at rest; while typing it becomes more opaque, so the text is always easy to read.
            let solid = scheme == .dark ? Color(red: 0.115, green: 0.138, blue: 0.195) : Color.white
            content
                .background {
                    if reduceTransparency { shape.fill(solid) }
                    else { shape.fill(.regularMaterial); shape.fill(solid.opacity(focused ? 0.55 : 0.12)) }
                }
                .overlay(shape.strokeBorder(focused ? Theme.accent.opacity(0.85) : Color.white.opacity(scheme == .dark ? 0.22 : 0.55), lineWidth: focused ? 1.5 : 0.7))
                .shadow(color: focused ? Theme.accent.opacity(0.25) : .black.opacity(scheme == .dark ? 0.30 : 0.12), radius: focused ? 14 : 10, y: 3)
                .modifier(StartSpecular(radius: radius))
        } else {
            content
                .background(shape.fill(ThemeState.raised?.opacity(0.85) ?? (scheme == .dark ? Color(red: 0.115, green: 0.138, blue: 0.195) : Color.white.opacity(0.9))))
                .overlay(shape.strokeBorder(focused ? Theme.accent.opacity(0.85) : Color.primary.opacity(scheme == .dark ? 0.10 : 0.08), lineWidth: focused ? 1.5 : 0.5))
                .shadow(color: focused ? Theme.accent.opacity(0.25) : .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: focused ? 14 : 10, y: 3)
        }
    }
}

/// A thin highlight on the edge of a glass control, brightest where the pointer is. It keeps its own small state, so moving the pointer redraws this one control and
/// nothing else, and it is only there when the pointer light is on.
private struct StartSpecular: ViewModifier {
    var radius: CGFloat
    @Environment(\.startPointerGlow) private var enabled
    @State private var location: CGPoint?

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    GeometryReader { geo in
                        if let location {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(RadialGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                                                             center: UnitPoint(x: location.x / max(geo.size.width, 1), y: location.y / max(geo.size.height, 1)),
                                                             startRadius: 0, endRadius: 80), lineWidth: 1.2)
                                .transition(.opacity)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): location = point
                    case .ended: location = nil
                    }
                }
                .animation(.easeOut(duration: 0.18), value: location == nil)
        } else {
            content
        }
    }
}

/// A small pill or round button (the protection line, Tools, Customize): a faint tint on the page's own background, glass over a picture so it never disappears into a busy one.
private struct StartChipStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startOverPhoto) private var overPhoto
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparencySetting
    @Environment(\.colorSchemeContrast) private var contrast
    /// Reduce Transparency, and Increase Contrast, both make the glass solid.
    private var reduceTransparency: Bool { reduceTransparencySetting || contrast == .increased }

    func body(content: Content) -> some View {
        if overPhoto {
            content
                .background {
                    if reduceTransparency { Capsule().fill(scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(white: 0.96)) }
                    else { Capsule().fill(.ultraThinMaterial) }
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.2 : 0.5), lineWidth: 0.6))
        } else {
            content.background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

private extension View {
    func startChip() -> some View { modifier(StartChipStyle()).modifier(StartSpecular(radius: 16)) }
    func startCard(radius: CGFloat = 16) -> some View { modifier(StartCardStyle(radius: radius)) }
    func startField(radius: CGFloat = 28, focused: Bool = false) -> some View { modifier(StartFieldStyle(radius: radius, focused: focused)) }
}

/// A button that rises slightly under the pointer.
private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .offset(y: hovering ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: hovering ? 8 : 0, y: hovering ? 4 : 0)
            .motion(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
    }
}

private extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

/// The name of the search engine in use, as a small capsule at the end of the search field.
private struct EngineBadge: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Text(SearchEngines.preset(for: model.searchTemplate)?.name ?? "Search")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// A heading over a section, at its leading edge, with the number of items and an optional action at the other end.
private struct SectionHeader: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).scaledFont(12, weight: .semibold).tracking(0.7).foregroundStyle(.secondary).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            if let count, count > 0 { Text("\(count)").scaledFont(11, weight: .medium).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
    }
}

/// "Show 8 more" / "Show less": every long list on the page ends with one.
private struct ShowMoreButton: View {
    @Binding var expanded: Bool
    let hidden: Int

    var body: some View {
        Button { animated(.easeOut(duration: 0.22)) { expanded.toggle() } } label: {
            HStack(spacing: 5) {
                Text(expanded ? "Show less" : "Show \(hidden) more")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .scaledFont(12, weight: .medium).foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .contentShape(Capsule())
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(expanded ? "Show fewer" : "Show \(hidden) more")
    }
}

/// One place as a card: its icon, its name and its site; used for the pages you visit often, tabs on other devices and tabs sent to this one.
private struct SiteCard: View {
    let title: String
    let detail: String
    let url: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
                } else {
                    SiteTile(url: url, title: title, size: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaledFont(13, weight: .medium).foregroundStyle(.primary.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                    if !detail.isEmpty { Text(detail).scaledFont(11).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .startCard(radius: 12)
            .contentShape(Rectangle())
            .keyboardFocusRing(radius: 12)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .hoverLift()
    }
}

/// One name and one identity per site, so "my.equifax.com" and "signin.my.equifax.com" are a single tile called "Equifax".
enum SiteName {
    /// The site a host belongs to: its last two labels (three under a country domain such as co.uk), without www.
    static func key(_ host: String?) -> String {
        guard var h = host?.lowercased(), !h.isEmpty else { return "" }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2, let last = parts.last else { return h }
        let secondLevel = ["co", "com", "org", "net", "gov", "ac"]
        let keep = (last.count == 2 && secondLevel.contains(parts[parts.count - 2])) ? 3 : 2
        return parts.suffix(keep).joined(separator: ".")
    }

    /// "equifax.com" reads as "Equifax".
    static func display(_ host: String?) -> String {
        let key = key(host)
        guard let first = key.split(separator: ".").first.map(String.init), !first.isEmpty else { return "" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}

/// A site as an icon tile with its name beneath, the same size and look as a favorite.
private struct ShortcutTile: View {
    @EnvironmentObject var model: BrowserModel
    let title: String
    let url: String
    var symbol: String?
    let action: () -> Void

    private var size: CGFloat { model.startTile.points }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Theme.accent)
                    } else {
                        SiteTile(url: url, title: title, size: size)
                    }
                }
                .frame(width: size + 22, height: size + 22)
                .startCard(radius: (size + 22) * 0.28)
                Text(title.isEmpty ? displayHost(URL(string: url)) : title)
                    .scaledFont(12).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.85)).frame(maxWidth: 92)
            }
            .frame(maxWidth: .infinity)
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .hoverLift()
        .accessibilityLabel(title.isEmpty ? displayHost(URL(string: url)) : title)
    }
}

/// Cards in two columns on a phone and three on a wide window.
private struct CardGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 10)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    #endif
    var body: some View { LazyVGrid(columns: columns, spacing: 10, content: content) }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var addingFavorite: Bool

    private var tileSize: CGFloat { model.startTile.points }
    private let capacity = 12
    @State private var showAll = false
    @State private var editing: BookmarkItem?
    @State private var editURL = ""
    @State private var editName = ""
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 12, alignment: .top)]
    private var accentColor: Color { Theme.accent }

    var body: some View {
        let all = model.orderedFavorites
        let limit = 8
        let items = showAll ? Array(all.prefix(capacity)) : Array(all.prefix(limit))
        VStack(spacing: 12) {
            if !all.isEmpty { SectionHeader(title: "Favorites", count: all.count) }
            if all.isEmpty {
                emptyCard.frame(maxWidth: .infinity).transition(.opacity)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items, id: \.url) { favorite in tile(favorite) }
                    if all.count < capacity || showAll { addTile }
                }
                if all.count > limit { ShowMoreButton(expanded: $showAll, hidden: min(all.count, capacity) - limit) }
            }
        }
        .motion(.easeOut(duration: 0.2), value: all.map(\.url))
        .alert("Edit Favorite", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Website address", text: $editURL)
            TextField("Name", text: $editName)
            Button("Save") { if let old = editing?.url { model.editFavorite(old, address: editURL, name: editName) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private func tile(_ favorite: BookmarkItem) -> some View {
        Button { model.open(urlString: favorite.url) } label: {
            VStack(spacing: 8) {
                SiteTile(url: favorite.url, title: favorite.title, size: tileSize)
                    .frame(width: tileSize + 22, height: tileSize + 22)
                    .startCard(radius: (tileSize + 22) * 0.28)
                Text(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
                    .scaledFont(12).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.85)).frame(maxWidth: 92)
            }
            .frame(maxWidth: .infinity)
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .hoverLift()
        .draggable(favorite.url) { SiteTile(url: favorite.url, title: favorite.title, size: tileSize) }
        .dropDestination(for: String.self) { dropped, _ in
            guard let url = dropped.first else { return false }
            model.moveFavorite(url, before: favorite.url)
            return true
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(urlString: favorite.url, newTab: true) }
            Button("Edit…") { editURL = favorite.url; editName = favorite.title; editing = favorite }
            Button("Remove from Favorites", role: .destructive) { model.removeFavorite(favorite.url) }
        }
        .accessibilityLabel(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
        .accessibilityAction(named: "Move earlier") { model.nudgeFavorite(favorite.url, by: -1) }
        .accessibilityAction(named: "Move later") { model.nudgeFavorite(favorite.url, by: 1) }
    }

    /// Never filled in for you: suggestions are only offered here, and nothing is added until you choose it.
    private var addTile: some View {
        addMenu {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: tileSize + 22, height: tileSize + 22)
                    .background(RoundedRectangle(cornerRadius: (tileSize + 22) * 0.28, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("Add").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .keyboardFocusRing(radius: 14)
        }
    }

    /// With no favorites yet, one clear dashed box says what this row is for and how to fill it.
    private var emptyCard: some View {
        addMenu {
            // One small line, not a box: nothing is added unless you choose it.
            VStack(spacing: 14) {
                SetuGhostTiles()
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(accentColor)
                    Text("Add a favorite").scaledFont(13, weight: .medium).foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 16).frame(height: 38)
                .startCard(radius: 19)
                .contentShape(Capsule())
                .keyboardFocusRing(radius: 19)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityLabel("Add a favorite site")
    }

    private func addMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            if let tab = model.continueTab ?? model.active, let url = tab.url?.absoluteString, !tab.isBlank, !model.isFavorite(url) {
                Button("Add “\(tab.displayTitle)”") { model.toggleFavorite(url: url, title: tab.displayTitle) }
            }
            Button("Add a Website…") { addingFavorite = true }
            let suggestions = FavoriteSuggestions.all.filter { !model.isFavorite($0.url) }
            if !suggestions.isEmpty {
                Menu("Suggestions") { ForEach(suggestions, id: \.url) { s in Button(s.title) { model.toggleFavorite(url: s.url, title: s.title) } } }
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusEffectDisabled()
        .accessibilityLabel("Add a favorite")
        .accessibilityIdentifier("add-favorite")
    }
}

enum FavoriteSuggestions {
    static let all: [(title: String, url: String)] = [
        ("Wikipedia", "https://www.wikipedia.org/"), ("YouTube", "https://www.youtube.com/"), ("GitHub", "https://github.com/"),
        ("Apple", "https://www.apple.com/"), ("Maps", "https://maps.apple.com/"), ("BBC News", "https://www.bbc.com/news"),
        ("Hacker News", "https://news.ycombinator.com/"), ("Archive", "https://archive.org/"),
    ]
}

// MARK: - Continue

private struct ContinueCard: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(title: "Continue browsing")
            Button { model.select(tab.id) } label: {
                HStack(spacing: 14) {
                    if let data = tab.snapshot, let image = Image(platformData: data) {
                        Color.clear.frame(width: 96, height: 62)
                            .overlay(alignment: .top) { image.resizable().scaledToFill() }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    } else {
                        SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.displayTitle).scaledFont(15, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(displayHost(tab.url)) · \(RelativeDateTimeFormatter().localizedString(for: tab.lastActive, relativeTo: Date()))")
                            .scaledFont(12).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.accent.opacity(0.14)))
                }
                .padding(12)
                .startCard(radius: 18)
                .contentShape(Rectangle())
                .keyboardFocusRing(radius: 18)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .hoverLift()
            .accessibilityLabel("Continue browsing: \(tab.displayTitle), \(displayHost(tab.url))")
            .accessibilityIdentifier("continue-card")
        }
    }
}

// MARK: - Places you go often, and tabs you just closed

private struct HistoryChips: View {
    @EnvironmentObject var model: BrowserModel
    @State private var often: [OftenSite] = []
    @State private var showAllOften = false
    @State private var showAllClosed = false

    struct OftenSite: Identifiable { let id: String; let title: String; let url: String; let isLocal: Bool }

    /// Up to eight closed tabs, newest first, with one chip for each site.
    private func reopenChips(_ all: [(offset: Int, element: ClosedTab)]) -> [(offset: Int, element: ClosedTab)] {
        var seen = Set<String>()
        return Array(all.filter { seen.insert(SiteName.key($0.element.url.host)).inserted }.prefix(8))
    }

    private func isLocal(_ host: String?) -> Bool {
        guard let host else { return false }
        return !PublicAddress.isPublicHost(host)   // one definition of "not on the public internet", shared with the lookups
    }

    /// One card per page (no repeats), local development addresses folded into a single "Local" card, readable titles.
    private func load() {
        guard model.showFrequent else { often = []; return }
        let favorites = Set(model.favorites.map(\.url))
        var seen = Set<String>(), titles = Set<String>(), result: [OftenSite] = [], localCount = 0, firstLocal: OftenSite?
        for site in model.frequentSites(limit: 24) where !favorites.contains(site.url) {
            let url = URL(string: site.url)
            let key = SiteName.key(url?.host)
            guard seen.insert(key).inserted else { continue }
            let title = site.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let readable = title.isEmpty || title == site.url ? displayHost(url) : title
            if isLocal(url?.host) {
                localCount += 1
                if firstLocal == nil { firstLocal = OftenSite(id: "local", title: "", url: site.url, isLocal: true) }
            } else if titles.insert(readable.lowercased()).inserted {      // two pages with the same title are one card
                result.append(OftenSite(id: site.url, title: readable, url: site.url, isLocal: false))
            }
        }
        if let firstLocal { result.append(OftenSite(id: "local", title: localCount == 1 ? "Local page" : "Local pages (\(localCount))", url: firstLocal.url, isLocal: true)) }
        often = result
    }

    var body: some View {
        #if os(iOS)
        let limit = 8
        #else
        let limit = 12
        #endif
        let shown = !model.showFrequent ? [] : (showAllOften ? often : Array(often.prefix(limit)))
        let continueURL = model.continueTab?.url?.absoluteString
        let allClosed = model.showRecentlyClosed
            ? Array(model.closedTabs.enumerated().reversed().filter { $0.element.url.absoluteString != continueURL })
            : []
        let closed = showAllClosed ? Array(allClosed.prefix(10)) : Array(allClosed.prefix(3))
        VStack(spacing: 28) {
            if !shown.isEmpty {
                VStack(spacing: 10) {
                    SectionHeader(title: "Often visited", count: often.count)
                    // The same icon tiles as Favorites, so the page reads as one set of shortcuts.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(shown) { site in
                            ShortcutTile(title: site.isLocal ? site.title : SiteName.display(URL(string: site.url)?.host), url: site.url, symbol: site.isLocal ? "laptopcomputer" : nil) { model.open(urlString: site.url) }
                                .contextMenu { Button("Open in New Tab") { model.open(urlString: site.url, newTab: true) } }
                        }
                    }
                    if often.count > limit { ShowMoreButton(expanded: $showAllOften, hidden: often.count - limit) }
                }
            }
            if !closed.isEmpty {
                VStack(spacing: 10) {
                    SectionHeader(title: "Reopen", count: allClosed.count)
                    // One quiet row you can swipe, a chip per closed tab, one site once.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(reopenChips(allClosed), id: \.offset) { index, tab in
                                Button { model.reopenClosedTab(at: index) } label: {
                                    HStack(spacing: 7) {
                                        SiteTile(url: tab.url.absoluteString, title: tab.title, size: 20)
                                        Text(SiteName.display(tab.url.host)).scaledFont(13, weight: .medium).foregroundStyle(.primary.opacity(0.9)).lineLimit(1)
                                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12).frame(height: 38)
                                    .startCard(radius: 19)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Reopen \(tab.title.isEmpty ? displayHost(tab.url) : tab.title)")
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        // The list is read when the switch changes, not only when the section first appears; and it follows the favorites, which it leaves out.
        .onChange(of: model.showFrequent) { _, _ in load() }
        .onChange(of: model.favorites.map(\.url)) { _, _ in load() }
        .motion(.easeOut(duration: 0.2), value: model.showFrequent)
    }
}

private struct SentToThisDevice: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showAll = false

    var body: some View {
        let items = Array(model.inbox.prefix(showAll ? 12 : 4))
        VStack(spacing: 10) {
            SectionHeader(title: "Sent to this device", count: model.inbox.count)
            CardGrid {
                ForEach(items) { item in
                    SiteCard(title: item.title.isEmpty ? displayHost(URL(string: item.url)) : item.title, detail: "From \(item.fromName)", url: item.url) { model.openSentTab(item) }
                        .contextMenu { Button("Dismiss") { model.dismissSentTab(item) } }
                }
            }
            if model.inbox.count > 4 { ShowMoreButton(expanded: $showAll, hidden: min(model.inbox.count, 12) - 4) }
        }
        .transition(.opacity)
    }
}

private struct OtherDeviceTabs: View {
    @EnvironmentObject var model: BrowserModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 24) {
            ForEach(model.remoteTabs.prefix(3)) { device in
                let isOpen = expanded.contains(device.device)
                let tabs = Array(device.tabs.prefix(isOpen ? 12 : 4))
                VStack(spacing: 10) {
                    SectionHeader(title: "On \(device.device)", count: device.tabs.count)
                    CardGrid {
                        ForEach(tabs, id: \.url) { tab in
                            SiteCard(title: tab.title.isEmpty ? displayHost(URL(string: tab.url)) : tab.title, detail: displayHost(URL(string: tab.url)), url: tab.url) { model.open(urlString: tab.url, newTab: true) }
                        }
                    }
                    if device.tabs.count > 4 {
                        ShowMoreButton(expanded: Binding(get: { isOpen }, set: { if $0 { expanded.insert(device.device) } else { expanded.remove(device.device) } }),
                                       hidden: min(device.tabs.count, 12) - 4)
                    }
                }
            }
        }
    }
}

// MARK: - Protection line and customizing

/// Only facts the browser can measure: that protection is on, how many rules are loaded, how many tracking links were cleaned. WebKit's
/// content blockers do not report how many requests they stopped, so no such number is shown, and the line is hidden if there is nothing to say.
private struct PrivacyLine: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let rules = model.privacy.snapshot?.totalRules ?? 0
        if rules > 0 {
            let cleaned = model.strippedLinkCount
            Button { model.sheet = .dashboard } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text(cleaned > 0 ? "Protection on · \(cleaned) link\(cleaned == 1 ? "" : "s") cleaned" : "Protection on")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .startChip()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Protection is on with \(rules) rules. Open the privacy dashboard.")
            .accessibilityIdentifier("privacy-line")
        }
    }
}

/// Which parts of the page show. Changes apply at once and are kept.
private struct CustomizeMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button { animated(.easeOut(duration: 0.22)) { model.startDrawerOpen = true } } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 12.5)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .startChip()
                .accessibilityLabel("Customize")
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .keyboardFocusRing(radius: 14)
        .fixedSize()
        .accessibilityIdentifier("customize-start")
    }
}

#if os(macOS)
// MARK: - The search field in the middle of the page (Mac)

/// An independent text field: its own focus, its own text, its own suggestions. It shares the browser's search engine, suggestion provider,
/// address parser and navigation, but never hands focus to, or takes it from, the address bar in the toolbar.
private struct StartSearchField: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var address = AddressBarController()
    @FocusState private var focused: Bool
    @State private var overList = false
    @StateObject private var voice = VoiceSearch()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(focused ? Theme.accent : Color.secondary)
            TextField("Search or enter address", text: $address.text)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { address.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { address.moveSelection(-1); return .handled }
                .onKeyPress(.escape) { escape(); return .handled }
                .accessibilityLabel("Search or enter address")
                .accessibilityIdentifier("start-search")
            if !address.text.isEmpty {
                Button { address.text = ""; address.clear(); focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear")
                .transition(.opacity)
            } else {
                EngineBadge()
            }
            VoiceButton(voice: voice)
        }
        .padding(.horizontal, 18).frame(height: 56)
        .startField(radius: model.startSearchStyle.radius, focused: focused)
        .onAppear { voice.onFinish = { words in address.text = words; submit() } }
        .onChange(of: voice.transcript) { _, heard in if voice.listening { address.text = heard } }
        .onChange(of: voice.problem) { _, message in if let message { model.notice = message; voice.problem = nil } }
        .motion(.easeOut(duration: 0.18), value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Suggestions open straight under this field, over the rest of the page.
        .overlay(alignment: .top) {
            if focused || overList {
                SuggestionsList(address: address)
                    // Solid, so the page behind it never shows through the list; in the theme's own colour when one is in use.
                    .background {
                        let panel = RoundedRectangle(cornerRadius: 20, style: .continuous)
                        // A solid base with a material over it: legible whatever is behind, and it still looks like part of the glass around it.
                        panel.fill((ThemeState.raised ?? Color(red: 0.075, green: 0.090, blue: 0.135)).opacity(0.88))
                        panel.fill(.regularMaterial).opacity(0.6)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .padding(.top, 64)
                    .onHover { overList = $0 }
            }
        }
        .zIndex(10)
        .onChange(of: address.text) { _, _ in
            address.isEditing = true
            address.refresh(model: model)
        }
        .onChange(of: focused) { _, now in
            address.isEditing = now
            if now { address.refresh(model: model) }
        }
        // A new blank tab opens with this field ready for typing; ⌘L still goes to the address bar, whatever has focus.
        .onChange(of: model.startFocusTick) { _, _ in focused = true }
        .onAppear { DispatchQueue.main.async { if model.active?.isBlank ?? false { focused = true } } }
    }

    private func submit() {
        let text = address.text
        if let picked = address.selectedSuggestion {
            reset()
            model.accept(picked)
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            reset()
            model.navigate(input: text)
        }
    }

    /// Escape closes the suggestions first; a second press clears what was typed and lets go of the field.
    private func escape() {
        if !address.suggestions.isEmpty { address.selection = nil; address.clear() }
        else { address.text = ""; focused = false }
    }

    private func reset() { address.clear(); address.text = ""; address.isEditing = false; focused = false }
}
#endif


/// Each part of the start page rises into place a moment after the one above it. Without motion (Reduce Motion) it simply appears.
private struct StartEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var still: Bool { reduceMotion || MotionStyle.current == .off }

    func body(content: Content) -> some View {
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || still ? 0 : 14)
            .animation(MotionStyle.current.apply(.easeOut(duration: 0.5).delay(Double(index) * 0.07)), value: shown)
            .onAppear { shown = true }
    }
}

private extension View { func startEntrance(_ index: Int) -> some View { modifier(StartEntrance(index: index)) } }

/// The glow behind the start page leans warm in the morning, cool by day, violet in the evening and deep blue at night.
enum StartTone {
    static func glow(hour: Int = Calendar.current.component(.hour, from: Date())) -> Color {
        switch hour {
        case 5..<9: Color(red: 0.20, green: 0.13, blue: 0.08)
        case 9..<17: Color(red: 0.07, green: 0.16, blue: 0.21)
        case 17..<21: Color(red: 0.17, green: 0.10, blue: 0.23)
        default: Color(red: 0.067, green: 0.106, blue: 0.188)
        }
    }
}


#if os(macOS)
/// The first minutes: three quiet next steps on a fresh start page, gone once there is a favorite.
private struct GettingStartedStrip: View {
    @State private var importing = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Make it yours").font(.system(size: 11.5, weight: .semibold)).tracking(0.9).textCase(.uppercase).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12, alignment: .top)], spacing: 12) { cards }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting started")
        .sheet(isPresented: $importing) { ImportSheet() }
    }

    @ViewBuilder private var cards: some View {
        GettingStartedCard(symbol: "paintpalette.fill", title: "Choose a look", detail: "Themes, colours and wallpapers", tint: Theme.accent) { SettingsRouter.open(.appearance) }
        GettingStartedCard(symbol: "checkmark.shield.fill", title: "Make it your default", detail: "Open every link in Browser Setu", tint: .purple) { SettingsRouter.open(.general) }
        GettingStartedCard(symbol: "square.and.arrow.down.fill", title: "Bring your things", detail: "Bookmarks, passwords and history from another browser", tint: .orange) { importing = true }
    }
}

/// One thing to do first: a lit icon tile, what it is and a line of why. It rises a little under the pointer, and settles when pressed.
private struct GettingStartedCard: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LinearGradient(colors: [tint, tint.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(13, weight: .semibold).foregroundStyle(.primary.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).scaledFont(11.5).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .startCard(radius: 16)
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: hovering ? 10 : 0, y: hovering ? 5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
#endif
