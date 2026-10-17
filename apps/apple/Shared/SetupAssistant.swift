import SwiftUI

/// The first thing a new install shows: a few short questions that set up the look, the layout, search, protection and passwords.
/// Every choice applies the moment it is made and can be changed later in Settings; nothing is sent anywhere.
struct SetupAssistantView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var step = 0
    @State private var forward = true

    private enum Step: Int, CaseIterable { case welcome, look, layout, search, protection, passwords, done }
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
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Set up Browser Setu")
    }

    // MARK: Pieces

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
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
        animated(.easeOut(duration: 0.28)) { step = min(max(step + delta, 0), Step.allCases.count - 1) }
    }

    private func finish() {
        model.saveSetting("setup_done", "1")
        animated(.easeOut(duration: 0.3)) { model.showSetup = false }
    }

    private func heading(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent).padding(.bottom, 4)
            Text(title).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
                heading("How should it look?", "Pick a theme. The whole browser takes it on: the window, the sidebar, the new tab page and the settings.", symbol: "paintpalette")
                Picker("Appearance", selection: $model.appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                ThemeDots()
                Text(model.activeTheme.name).font(.callout).foregroundStyle(.secondary)
            }
        case .layout:
            layoutStep
        case .search:
            VStack(spacing: 12) {
                heading("Which search engine?", "This is what the address bar uses when you type words. You can change it any time, or use a keyword like “yt” for one search.", symbol: "magnifyingglass")
                row("Search engine") { SearchEngineMenu() }
                Divider()
                row("Suggest as I type", "Sends what you type to your search engine to get suggestions. Off keeps everything on this device.") {
                    Toggle("", isOn: $model.searchSuggestionsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        case .protection:
            VStack(spacing: 6) {
                heading("How protected?", "These are on by default. Switch off anything you don’t want.", symbol: "shield.lefthalf.filled")
                row("Block ads on YouTube", "Removes ads before they play.") { Toggle("", isOn: $model.blockVideoAds).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Stop videos and sound starting by themselves", "Nothing plays until you tap or press a key.") { Toggle("", isOn: $model.blockAutoplay).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Block pop-ups", "Windows that open without a click are stopped. Sign-in windows you click still work.") { Toggle("", isOn: $model.blockPopups).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Open a site’s own page instead of its AMP copy", nil) { Toggle("", isOn: $model.deAMP).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Randomize canvas and audio details", "Stops sites recognising this device by them. A few sites may look slightly different.") { Toggle("", isOn: $model.randomizeFingerprint).labelsHidden().toggleStyle(.switch) }
            }
        case .passwords:
            VStack(spacing: 8) {
                heading("Passwords", "Browser Setu can offer to keep your sign-ins in the Keychain on this device. Filling one in always asks for Touch ID or your password first.", symbol: "key")
                row("Offer to save passwords", "After you sign in to a site.") {
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
            heading("How should the window be laid out?", "Where the tabs and the address bar go. You can switch layouts any time from the toolbar’s right-click menu.", symbol: "sidebar.left")
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
}
