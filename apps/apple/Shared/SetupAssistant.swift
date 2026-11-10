import SwiftUI

/// The first thing a new install shows: a few short questions that set up the look, the layout, search, protection and passwords.
/// Every choice applies the moment it is made and can be changed later in Settings; nothing is sent anywhere.
///
/// Two panes on a wide window: the picture of the step on the left, the question on the right. On a narrow one the picture sits above the question. The picture and the question change together, one step at a time.
struct SetupAssistantView: View {
    @EnvironmentObject var model: BrowserModel
    #if DEBUG && os(macOS)
    /// Development only (`BS_SETUP_STEP=3`, a throwaway -UITestRoot): opens on that step, to look at it without clicking through the ones before.
    @State private var step = Int(ProcessInfo.processInfo.environment["BS_SETUP_STEP"] ?? "") ?? 0
    #else
    @State private var step = 0
    #endif
    @State private var forward = true
    /// The assistant takes the keyboard when it opens, so Return and Esc reach it and not the page behind it.
    @FocusState private var keyboardFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @StateObject private var mediaTools = MediaToolsStore.shared
    @State private var mediaOn = true
    #endif

    private enum Step: Int, CaseIterable { case welcome, look, layout, panels, search, protection, passwords, importData, sync, media, done
        static var shown: [Step] { #if os(macOS)
            allCases
            #else
            allCases.filter { $0 != .panels && $0 != .media }
            #endif
        }
        var illustration: SetupIllustration.Kind {
            switch self {
            case .welcome: .welcome; case .look: .look; case .layout: .layout; case .panels: .panels; case .search: .search
            case .protection: .protection; case .passwords: .passwords; case .importData: .importData; case .sync: .sync; case .media: .media; case .done: .done
            }
        }
        var name: String {
            switch self {
            case .welcome: "Welcome"; case .look: "Look"; case .layout: "Layout"; case .panels: "Panels"; case .search: "Search"
            case .protection: "Protection"; case .passwords: "Passwords"; case .importData: "Import"; case .sync: "Sync"; case .media: "Media"; case .done: "Done"
            }
        }
    }
    private var effectiveScheme: ColorScheme { model.appearance.colorScheme ?? model.activeTheme.scheme?.colorScheme ?? .dark }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var isLight: Bool { effectiveScheme == .light }
    private var current: Step { Step(rawValue: step) ?? .welcome }
    private var position: Int { (Step.shown.firstIndex { $0 == current } ?? 0) + 1 }

    var body: some View {
        ZStack {
            Group {
                if isLight && !model.themeIsActive { DaylightBackdrop() }
                else { ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim).overlay(Color.black.opacity(isLight ? 0 : 0.25)) }
            }
            .ignoresSafeArea()
            GeometryReader { geo in
                let wide = geo.size.width >= 780
                card(wide: wide, width: geo.size.width)
                    .frame(maxWidth: wide ? 1080 : 560, maxHeight: min(820, max(380, geo.size.height - 32)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
        // Dark unless light was chosen (or the theme is a light one); the backdrop and the card follow.
        .preferredColorScheme(effectiveScheme)
        .focusable()
        .focused($keyboardFocus)
        .focusEffectDisabled()
        .onAppear {
            // A text field behind the assistant (the start page's search box) holds the keyboard when the window opens; let go of it first, then take focus here.
            #if os(macOS)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                NSApp.keyWindow?.makeFirstResponder(nil)
                keyboardFocus = true
            }
            #else
            keyboardFocus = true
            #endif
        }
        // Keys no control used: Return is the default button (Set Up, Continue, Start Browsing), Esc goes back a step.
        .onKeyPress(.return) { if current == .done { finish() } else { move(1) }; return .handled }
        .onKeyPress(.escape) { if current == .welcome || current == .done { return .ignored }; move(-1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Set up Browser Setu")
    }

    // MARK: The card

    private func card(wide: Bool, width: CGFloat) -> some View {
        // The picture's side takes about a third of the card, between 250 and 390 points, so the split follows the window.
        let artWidth = min(max((min(width - 32, 1080)) * 0.35, 250), 390)
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return Group {
            if wide {
                HStack(spacing: 0) {
                    artPane(compact: false, width: artWidth).frame(width: artWidth).clipped()
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                    contentPane
                }
            } else {
                VStack(spacing: 0) {
                    artPane(compact: true, width: artWidth).frame(height: 138).clipped()
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    contentPane
                }
            }
        }
        .themedFill(in: shape, fallback: .regularMaterial)
        .background(isLight ? Color.white.opacity(reduceTransparency ? 0.97 : 0.78) : Color.clear, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: isLight ? [Color.white.opacity(0.9), Color.black.opacity(0.08)] : [Color.white.opacity(0.28), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: (isLight ? Theme.accent : Color.black).opacity(isLight ? 0.16 : 0.40), radius: isLight ? 40 : 36, y: isLight ? 18 : 14)
        .shadow(color: .black.opacity(isLight ? 0.08 : 0.0), radius: 3, y: 1)
    }

    /// The left pane (above on a narrow window): the name, the picture of this step and, when there is room, the list of steps with where you are in it.
    private func artPane(compact: Bool, width: CGFloat) -> some View {
        ZStack {
            if isLight {
                LinearGradient(colors: [Theme.accent.opacity(0.10), Color(red: 0.60, green: 0.52, blue: 0.95).opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(colors: [Color.black.opacity(0.18), Color.black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
            }
            if compact {
                SetupIllustration(kind: current.illustration, layout: model.layoutPreset, panel: model.panelMode)
                    .scaleEffect(0.52)
                    .id(current)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .padding(.top, 14)
                brand.padding(.horizontal, 20).padding(.top, 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        brand.padding(.horizontal, 24).padding(.top, 20).frame(maxWidth: .infinity, alignment: .leading)
                        SetupIllustration(kind: current.illustration, layout: model.layoutPreset, panel: model.panelMode)
                            .scaleEffect(min(1.12, max(0.9, width / 316)))
                            .id(current)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The list of steps shows when the pane is tall enough for it and the picture still has its room.
                        if geo.size.height >= 640 { stepRail.padding(.horizontal, 32).padding(.bottom, 28) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .motion(.easeInOut(duration: 0.4), value: step)
    }

    private var brand: some View {
        HStack { SetuLockup(size: 13); Spacer() }
    }

    /// Every step, in order: done ones checked, the current one lit, the rest quiet, joined by a thin line. Read-only (the buttons move between steps), and hidden from VoiceOver
    /// because "Step 3 of 11, Layout" already says where you are.
    private var stepRail: some View {
        let steps = Step.shown
        let here = position - 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, item in
                HStack(spacing: 11) {
                    ZStack {
                        if index < here {
                            Circle().fill(Theme.accent)
                            Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.white)
                        } else if index == here {
                            Circle().fill(Theme.accent.opacity(0.22))
                            Circle().strokeBorder(Theme.accent, lineWidth: 2)
                        } else {
                            Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.3)
                        }
                    }
                    .frame(width: 15, height: 15)
                    Text(item.name).font(.system(size: 12.5, weight: index == here ? .semibold : .regular))
                        .foregroundStyle(index == here ? Color.primary : (index < here ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.85)))
                    Spacer(minLength: 0)
                }
                .frame(height: 23)
                .background(alignment: .topLeading) {
                    if index < steps.count - 1 {
                        Rectangle().fill(index < here ? Theme.accent.opacity(0.65) : Color.primary.opacity(0.13)).frame(width: 1.5, height: 14).offset(x: 6.75, y: 19)
                    }
                }
            }
        }
        .motion(.easeOut(duration: 0.3), value: step)
        .accessibilityHidden(true)
    }

    /// The right pane (below on a narrow window): where you are, the question, and the buttons.
    private var contentPane: some View {
        VStack(spacing: 0) {
            progress.padding(.horizontal, 30).padding(.top, 24)
            GeometryReader { geo in
            ScrollView {
                content
                    .frame(minHeight: geo.size.height - 36, alignment: (current == .welcome || current == .done) ? .center : .top)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                    .padding(.horizontal, 30).padding(.vertical, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18) })
            }
            buttons.padding(.horizontal, 30).padding(.bottom, 24).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    /// "Step 3 of 9" and a rail of capsules: the one you are on is long and lit, the ones behind it are lit, the ones ahead are dim.
    private var progress: some View {
        HStack(spacing: 12) {
            Text("STEP \(position) OF \(Step.shown.count)").font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(Step.shown, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= step ? Theme.accent : Color.primary.opacity(0.14))
                        .frame(width: s.rawValue == step ? 24 : 7, height: 5)
                }
            }
            .motion(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(position) of \(Step.shown.count), \(current.name)")
    }

    private var buttons: some View {
        HStack {
            if current == .welcome {
                Button("Skip Setup") { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            } else if current != .done {
                Button("Back") { move(-1) }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            Spacer()
            if current == .done {
                Button { finish() } label: { Text("Start Browsing").padding(.horizontal, 12) }.buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { move(1) } label: { Text(current == .welcome ? "Set Up" : "Continue").padding(.horizontal, 12) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        #if os(macOS)
        if current == .media, delta > 0 { applyMediaChoice() }
        #endif
        forward = delta > 0
        var next = min(max(step + delta, 0), Step.allCases.count - 1)
        #if DEBUG
        // Debug only (`-SetupJumpToMedia YES`, for UI tests): "Set Up" on the welcome page goes straight to the media step, so a test of that step does not click through the six before it.
        if current == .welcome, delta > 0, UserDefaults.standard.bool(forKey: "SetupJumpToMedia") { next = Step.media.rawValue }
        #endif
        if !Step.shown.contains(where: { $0.rawValue == next }) { next = min(max(next + delta, 0), Step.allCases.count - 1) }
        animated(.easeOut(duration: 0.3)) { step = next }
    }

    private func finish() {
        model.saveSetting("setup_done", "1")
        animated(.easeOut(duration: 0.3)) { model.showSetup = false }
    }

    /// The question of a step: what it is, and one or two plain sentences about it.
    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 13.5)).foregroundStyle(Color.primary.opacity(0.72)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// A setting as a card: its name and what it does, with the control at the end.
    private func row<Trailing: View>(_ title: String, _ detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(1).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupRowSurface()
        .accessibilityElement(children: .contain)
    }

    /// A protection switch: the name and its first sentence show; the rest is a tap away ("Details"), so the page is not a wall of text.
    private func switchRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        SetupSwitchRow(title: title, detail: detail, isOn: isOn)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch current {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                heading("Welcome to Browser Setu", "A browser built around your privacy. A few quick questions make it yours. It takes about a minute, and every answer can be changed later in Settings.")
                VStack(spacing: 10) {
                    SetupPoint(symbol: "lock.shield", title: "Private by default", text: "Protection is on from the start, on this device.")
                    SetupPoint(symbol: "slider.horizontal.3", title: "Yours to arrange", text: "Look, layout and search, chosen in a few taps.")
                    SetupPoint(symbol: "icloud.slash", title: "Nothing is sent to us", text: "Your answers stay on this Mac.")
                }
            }
        case .look:
            VStack(alignment: .leading, spacing: 16) {
                heading("How should it look?", "Light or dark, and a colour theme for the window, the sidebar, the new tab page and the panels. Nothing is downloaded.")
                Picker("Appearance", selection: $model.appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                VStack(alignment: .leading, spacing: 10) {
                    ThemeDots()
                    Text(model.activeTheme.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .setupRowSurface()
                Text("You can switch at any time in Settings › Appearance.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .layout:
            layoutStep
        case .panels:
            panelsStep
        case .search:
            VStack(alignment: .leading, spacing: 12) {
                heading("Which search engine?", "The site that answers when you type words, not a web address, into the address bar. A keyword such as “yt” before your words searches one other site for that search only.")
                row("Search engine") { SearchEngineMenu() }
                row("Suggest as I type", "On: each letter you type is sent to the search engine you chose, so it can offer suggestions. Off: nothing is sent until you press Return.") {
                    Toggle("", isOn: $model.searchSuggestionsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        case .protection:
            VStack(alignment: .leading, spacing: 9) {
                heading("How protected?", "Each switch is on by default and works inside Browser Setu, on this device. Switch off any you don’t want.")
                switchRow("Block ads on YouTube", "Removes the ad data from YouTube’s pages before the player reads it, so ads are skipped instead of played. The rules can update without a new app version. YouTube may change and break this for a while.", isOn: $model.blockVideoAds)
                switchRow("Stop videos and sound starting by themselves", "A video or sound only starts after you tap, click or press a key on that page. Pages that try to play on load are paused.", isOn: $model.blockAutoplay)
                switchRow("Block pop-ups", "A page that opens a new window with no click from you is stopped, and a small notice offers to allow it for that site. Windows opened by a click, such as “Sign in with Google”, still open.", isOn: $model.blockPopups)
                switchRow("Open a site’s own page instead of its AMP copy", "AMP is Google’s stripped-down copy of a page. This sends you to the site’s normal page instead.", isOn: $model.deAMP)
                switchRow("Randomize canvas and audio details", "Adds tiny random noise to what a page can read from your graphics and audio, so sites can’t tell this device apart by them. A few sites may draw an image slightly differently.", isOn: $model.randomizeFingerprint)
            }
        case .passwords:
            VStack(alignment: .leading, spacing: 12) {
                heading("Passwords", "After you sign in to a site, Browser Setu can offer to keep the username and password in this device’s Keychain. Nothing is sent to us. Filling one in always asks for Touch ID or your password first.")
                row("Offer to save passwords", "Shows a card after a sign-in with Save, Not Now or Never for This Site. Off means it never asks.") {
                    Toggle("", isOn: Binding(get: { model.saveLoginsEnabled }, set: { model.setSaveLogins($0) })).labelsHidden().toggleStyle(.switch)
                }
                Text("You can bring passwords from another browser in Settings › Websites.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .importData:
            VStack(alignment: .leading, spacing: 12) {
                heading("Bring your things over", "Optional. Export from your old browser, then choose the file here. Everything is read on this device and nothing is sent anywhere. You can skip this now and do it later from the start page or Settings.")
                ForEach(ImportKind.allCases) { ImportCard(kind: $0) }
                Text("Open tabs cannot be moved from another browser. Browser Setu keeps your tabs the same between your own devices, which is the next step.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .sync:
            SetupSyncStep(heading: heading("Keep your devices in step", "Optional. Uses your own iCloud account, not our servers. You can change it any time in Settings ▸ Sync."))
        case .media:
            #if os(macOS)
            mediaStep
            #else
            EmptyView()
            #endif
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                heading("You’re all set. Enjoy!", "Here’s to the best browsing yet. Everything you chose is already in place. Settings has every option, and the command palette (⌘⇧P) can find anything.")
                VStack(spacing: 0) {
                    summaryLine("Appearance", "\(model.appearance.title), \(model.activeTheme.name)")
                    #if os(macOS)
                    summaryLine("Layout", model.layoutPreset.title)
                    summaryLine("Panels", model.panelMode.title)
                    #endif
                    summaryLine("Suggestions as you type", model.searchSuggestionsEnabled ? "On" : "Off")
                    summaryLine("Offers to save passwords", model.saveLoginsEnabled ? "On" : "Off")
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .setupRowSurface()
                #if os(macOS)
                if mediaTools.choice == .accepted { mediaStatusLine }
                Button("Make Browser Setu the Default Browser…") { finish(); SettingsRouter.open(.general) }.buttonStyle(.bordered)
                #endif
            }
        }
    }

    private func summaryLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium))
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    /// Continue is the confirmation: with the box ticked the download starts (and carries on while the person browses); unticked, nothing is installed and nothing asks again.
    private func applyMediaChoice() {
        if mediaOn, mediaTools.manifest != nil { if !mediaTools.isBusy, !mediaTools.isReady { mediaTools.install() } }
        else { mediaTools.decline() }
    }

    private var mediaStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Advanced media downloads", "Optional. Browser Setu already saves ordinary files, streams and torrents. This adds a program that can find the formats of videos on more sites, so you can pick the quality and save the video or just its sound.")
            if mediaTools.manifest != nil {
                row("Download and install the media tools", "Browser Setu downloads \(mediaTools.manifest?.name ?? "yt-dlp") \(mediaTools.manifest?.version ?? "") from its official release page, checks it against a fingerprint built into this app, and keeps it in its own folder. \(mediaTools.sizeSummary ?? "") It runs on this Mac only when you ask for a video’s formats and allow it for that site, never in private tabs. No administrator password, Terminal or Homebrew is needed. Browsing carries on while it downloads.") {
                    Toggle("Install advanced media downloads", isOn: $mediaOn).labelsHidden().toggleStyle(.switch).accessibilityLabel("Install advanced media downloads").accessibilityIdentifier("setup-media-toggle")
                }
                Text("You can change this at any time in Settings › Media.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("This build has no media-tools package to install.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var mediaStatusLine: some View {
        switch mediaTools.phase {
        case .working(let f, let t): HStack(spacing: 8) { ProgressView(value: f).frame(width: 120).accessibilityLabel("Installing media tools").accessibilityValue("\(Int(f * 100)) percent"); Text("Media tools: \(t) \(Int(f * 100))%").font(.caption).foregroundStyle(.secondary) }
        case .ready: Label("Media tools are ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let m): Text("Media tools could not be installed: \(m) You can retry in Settings › Media.").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
    #endif

    @ViewBuilder private var layoutStep: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            heading("How should the window be laid out?", "Where your tabs and the address bar sit. Each picture shows what moves. You can switch at any time from the toolbar’s right-click menu.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(LayoutPreset.allCases.filter { $0 != .custom }) { preset in
                    let selected = model.layoutPreset == preset
                    SetupChoiceCard(title: preset.title, summary: Self.shortSummary(preset), selected: selected) {
                        SetupWindowGlyph(preset: preset, selected: selected)
                    } action: { animated(.easeOut(duration: 0.2)) { model.layoutPreset = preset } }
                }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            heading("Where should the address bar be?", "At the bottom it sits under your thumb. At the top it is where most browsers keep it.")
            Picker("Address bar", selection: $model.addressBarPosition) { ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        }
        #endif
    }

    /// One short line for each layout, so the cards are the same height. The full descriptions are in Settings.
    private static func shortSummary(_ preset: LayoutPreset) -> String {
        switch preset {
        case .classic: "Tabs on top, standard toolbar"
        case .sidebar: "Vertical tabs, address bar in the sidebar"
        case .minimal: "Compact tabs, no sidebar"
        case .floating: "No top bar; a pill shows the site"
        case .inline: "Tabs and address on one line"
        case .custom: preset.summary
        }
    }

    private var panelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Where should Bookmarks, History and Downloads open?", "These three lists are used all day. Choose where they appear. You can change it later in Settings › Tabs, or from the buttons at the top of any panel.")
            VStack(spacing: 10) {
                ForEach(PanelMode.allCases) { mode in
                    let selected = model.panelMode == mode
                    SetupChoiceCard(title: mode.title, summary: Self.explain(mode), selected: selected, horizontal: true) {
                        SetupPanelGlyph(mode: mode, selected: selected)
                    } action: { animated(.easeOut(duration: 0.2)) { model.panelMode = mode } }
                }
            }
        }
    }

    private static func explain(_ mode: PanelMode) -> String {
        switch mode {
        case .dock: "A column on the right edge. The page gets narrower to make room, so you can read both at once. Drag its edge to resize. Press the shortcut again to close."
        case .tab: "Opens as a tab in your tab list, with the whole window to itself. Best for long lists. Close it like any tab."
        case .float: "A card over the page, with the page dimmed behind it. It covers part of the page and closes when you click outside it or press Esc."
        }
    }
}

// MARK: - The sync step

/// The iCloud choice: a switch, why it may be off, the passphrase that seals what is shared, and what does and does not travel.
private struct SetupSyncStep<Heading: View>: View {
    let heading: Heading
    @EnvironmentObject private var model: BrowserModel
    @State private var phrase = ""
    @State private var hasPhrase = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync with iCloud").font(.system(size: 13.5, weight: .medium))
                    Text("Bookmarks, the tabs open on your other devices, and the settings you choose.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $model.iCloudSync).labelsHidden().toggleStyle(.switch)
                    .disabled(!CloudSync.available && !model.iCloudSync)
                    .accessibilityLabel("Sync with iCloud")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupRowSurface()
            if !CloudSync.available {
                Label("Sign in to iCloud in System Settings to turn this on. Browser Setu works the same without it.", systemImage: "icloud.slash").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if model.iCloudSync {
                VStack(alignment: .leading, spacing: 8) {
                    if hasPhrase {
                        Label("Passphrase saved on this device", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("Choose a passphrase. Use the same one on every device: it seals what is shared, so Apple stores only scrambled bytes.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            SecureField("Passphrase, at least 6 characters", text: $phrase).textFieldStyle(.roundedBorder)
                            Button("Save") {
                                guard phrase.count >= 6 else { message = "Use at least 6 characters."; return }
                                SyncKeys.setPassphrase(phrase, profile: model.profileName); hasPhrase = true; phrase = ""; message = nil
                                Task { await model.syncNowCloud() }
                            }
                        }
                        if let message { Text(message).font(.system(size: 11.5)).foregroundStyle(.orange) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .setupRowSurface()
            }
            Text("Passwords never go through this sync. They have their own iCloud Keychain option in Settings ▸ Websites. Nothing is sent to us.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { hasPhrase = model.syncPassphrase != nil }
    }
}

// MARK: - Pieces of the assistant

/// One point on the welcome page: a small lit symbol, a name and a line.
private struct SetupPoint: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A choice shown as a picture, a name and a line: selected it is outlined in the accent; hovered it lifts a little; pressed it settles.
private struct SetupChoiceCard<Glyph: View>: View {
    let title: String
    let summary: String
    let selected: Bool
    var horizontal = false
    @ViewBuilder let glyph: () -> Glyph
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Group {
                if horizontal {
                    HStack(spacing: 14) { glyph().frame(width: 120, height: 75); text; check }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        glyph().frame(maxWidth: .infinity).aspectRatio(1.6, contentMode: .fit)
                        HStack(alignment: .top, spacing: 8) { text; check }.frame(minHeight: 52, alignment: .top)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : (scheme == .light ? Color.white.opacity(hovering ? 1 : 0.92) : Color.primary.opacity(hovering ? 0.09 : 0.055))))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.07), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .offset(y: hovering && !reduceMotion ? -1 : 0)
        }
        .buttonStyle(SetupPressStyle())
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(title)
        .accessibilityHint(summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var check: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 17)).foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.6))
    }
}

private struct SetupPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A switch with its name, the first sentence of what it does, and the rest behind "Details".
private struct SetupSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @State private var open = false

    private var parts: (first: String, rest: String) {
        guard let end = detail.firstIndex(where: { ".!?".contains($0) }) else { return (detail, "") }
        let first = String(detail[...end])
        let rest = detail[detail.index(after: end)...].trimmingCharacters(in: .whitespaces)
        return (first, rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(parts.first).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(title).accessibilityHint(detail)
            }
            if !parts.rest.isEmpty {
                if open { Text(parts.rest).font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(1).fixedSize(horizontal: false, vertical: true).transition(.opacity) }
                Button(open ? "Less" : "Details") { animated(.easeOut(duration: 0.2)) { open.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    .accessibilityLabel(open ? "Hide details of \(title)" : "Show details of \(title)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupRowSurface()
    }
}
