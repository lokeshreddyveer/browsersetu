import SwiftUI

/// The first thing a new install shows: a few short questions that set up the look, the layout, search, protection and passwords.
/// Every choice applies the moment it is made and can be changed later in Settings; nothing is sent anywhere.
struct SetupAssistantView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var step = 0
    @State private var forward = true

    private enum Step: Int, CaseIterable { case welcome, look, layout, panels, search, protection, passwords, done
        static var shown: [Step] { #if os(macOS)
            allCases
            #else
            allCases.filter { $0 != .panels }
            #endif
        }
    }
    private var current: Step { Step(rawValue: step) ?? .welcome }

    var body: some View {
        ZStack {
            ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim)
                .overlay(Color.black.opacity(0.25))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                progress.padding(.top, 22)
                ScrollView {
                    content
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                        .padding(.horizontal, 28).padding(.vertical, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
                buttons.padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 8)
            }
            .frame(maxWidth: 560, maxHeight: 640)
            .themedFill(in: RoundedRectangle(cornerRadius: 24, style: .continuous), fallback: .regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
            .padding(16)
        }
        // The backdrop is always dark, so the card is too, whatever the system is set to.
        .preferredColorScheme(model.appearance.colorScheme ?? model.activeTheme.scheme?.colorScheme ?? .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Set up Browser Setu")
    }

    // MARK: Pieces

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.shown, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step ? Theme.accent : Color.primary.opacity(0.15))
                    .frame(width: s.rawValue == step ? 22 : 8, height: 6)
            }
        }
        .motion(.spring(response: 0.35, dampingFraction: 0.8), value: step)
        .accessibilityHidden(true)
    }

    private var buttons: some View {
        HStack {
            if current == .welcome {
                Button("Skip Setup") { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            } else if current != .done {
                Button("Back") { move(-1) }.buttonStyle(.borderless)
            }
            Spacer()
            if current == .done {
                Button { finish() } label: { Text("Start Browsing").padding(.horizontal, 10) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { move(1) } label: { Text(current == .welcome ? "Set Up" : "Continue").padding(.horizontal, 10) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        forward = delta > 0
        var next = min(max(step + delta, 0), Step.allCases.count - 1)
        if !Step.shown.contains(where: { $0.rawValue == next }) { next = min(max(next + delta, 0), Step.allCases.count - 1) }
        animated(.easeOut(duration: 0.28)) { step = next }
    }

    private func finish() {
        model.saveSetting("setup_done", "1")
        animated(.easeOut(duration: 0.3)) { model.showSetup = false }
    }

    private func heading(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent).padding(.bottom, 4)
            Text(title).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(Color.primary.opacity(0.7)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }
        .padding(.bottom, 8)
    }

    private func row<Trailing: View>(_ title: String, _ detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 6)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch current {
        case .welcome:
            heading("Welcome to Browser Setu", "A browser built around your privacy. A few quick questions make it yours. It takes about a minute, and you can change every answer later in Settings.", symbol: "sparkles")
        case .look:
            VStack(spacing: 18) {
                heading("How should it look?", "Light or dark, and a colour theme. The theme colours the window, the sidebar, the new tab page, the panels and Settings. Nothing is downloaded, and you can switch at any time in Settings › Appearance.", symbol: "paintpalette")
                Picker("Appearance", selection: $model.appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                ThemeDots()
                Text(model.activeTheme.name).font(.callout).foregroundStyle(.secondary)
            }
        case .layout:
            layoutStep
        case .panels:
            panelsStep
        case .search:
            VStack(spacing: 12) {
                heading("Which search engine?", "The site that answers when you type words, not a web address, into the address bar. A keyword such as “yt” before your words searches one other site for that search only.", symbol: "magnifyingglass")
                row("Search engine") { SearchEngineMenu() }
                Divider()
                row("Suggest as I type", "On: each letter you type is sent to the search engine you chose, so it can offer suggestions. Off: nothing is sent until you press Return.") {
                    Toggle("", isOn: $model.searchSuggestionsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        case .protection:
            VStack(spacing: 6) {
                heading("How protected?", "Each switch below is on by default and works inside Browser Setu, on this device. Switch off any you don’t want.", symbol: "shield.lefthalf.filled")
                row("Block ads on YouTube", "Removes the ad data from YouTube’s pages before the player reads it, so ads are skipped instead of played. The rules can update without a new app version. YouTube may change and break this for a while.") { Toggle("", isOn: $model.blockVideoAds).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Stop videos and sound starting by themselves", "A video or sound only starts after you tap, click or press a key on that page. Pages that try to play on load are paused.") { Toggle("", isOn: $model.blockAutoplay).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Block pop-ups", "A page that opens a new window with no click from you is stopped, and a small notice offers to allow it for that site. Windows opened by a click, such as “Sign in with Google”, still open.") { Toggle("", isOn: $model.blockPopups).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Open a site’s own page instead of its AMP copy", "AMP is Google’s stripped-down copy of a page. This sends you to the site’s normal page instead.") { Toggle("", isOn: $model.deAMP).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Randomize canvas and audio details", "Adds tiny random noise to what a page can read from your graphics and audio, so sites can’t tell this device apart by them. A few sites may draw an image slightly differently.") { Toggle("", isOn: $model.randomizeFingerprint).labelsHidden().toggleStyle(.switch) }
            }
        case .passwords:
            VStack(spacing: 8) {
                heading("Passwords", "After you sign in to a site, Browser Setu can offer to keep the username and password in this device’s Keychain. Nothing is sent to us. Filling one in always asks for Touch ID or your password first.", symbol: "key")
                row("Offer to save passwords", "Shows a card after a sign-in with Save, Not Now or Never for This Site. Off means it never asks.") {
                    Toggle("", isOn: Binding(get: { model.saveLoginsEnabled }, set: { model.setSaveLogins($0) })).labelsHidden().toggleStyle(.switch)
                }
                Text("You can bring passwords from another browser in Settings › Websites.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
            }
        case .done:
            VStack(spacing: 14) {
                heading("You’re all set", "Everything you chose is already in place. Settings has every option, and the command palette (⌘⇧P) can find anything.", symbol: "checkmark.seal")
                #if os(macOS)
                Button("Make Browser Setu the Default Browser…") { finish(); SettingsRouter.open(.general) }.buttonStyle(.bordered)
                #endif
            }
        }
    }

    @ViewBuilder private var layoutStep: some View {
        #if os(macOS)
        VStack(spacing: 10) {
            heading("How should the window be laid out?", "Where your tabs and the address bar sit. Each choice below says exactly what moves. You can switch at any time from the toolbar’s right-click menu.", symbol: "sidebar.left")
            ForEach(LayoutPreset.allCases.filter { $0 != .custom }) { preset in
                let selected = model.layoutPreset == preset
                Button { animated(.easeOut(duration: 0.2)) { model.layoutPreset = preset } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.system(size: 14, weight: .semibold))
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : Color.secondary).font(.title3)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        #else
        VStack(spacing: 12) {
            heading("Where should the address bar be?", "At the bottom it sits under your thumb. At the top it is where most browsers keep it.", symbol: "rectangle.bottomthird.inset.filled")
            Picker("Address bar", selection: $model.addressBarPosition) { ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
        }
        #endif
    }

    private var panelsStep: some View {
        VStack(spacing: 10) {
            heading("Where should Bookmarks, History and Downloads open?", "These three lists are used all day. Choose where they appear. You can change it later in Settings › Tabs, or from the buttons at the top of any panel.", symbol: "sidebar.right")
            ForEach(PanelMode.allCases) { mode in
                let selected = model.panelMode == mode
                Button { animated(.easeOut(duration: 0.2)) { model.panelMode = mode } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).font(.system(size: 14, weight: .semibold))
                            Text(Self.explain(mode)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : Color.secondary).font(.title3)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
