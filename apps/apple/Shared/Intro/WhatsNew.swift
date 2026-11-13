import SwiftUI

/// What an update shows when the app opens. A brand-new install gets the film and then the setup questions; an update gets the film and then this page, never the questions again.
enum LaunchPlan: Equatable {
    case newInstall          // film, then setup
    case update              // film, then "What's new"
    case none                // straight to the browser

    /// A profile that finished setup, or that already got past the opening film, is an existing install.
    static func established(setupDone: Bool, introDone: Bool) -> Bool { setupDone || introDone }

    /// Pure, so it can be tested. `setupDone`: the person finished (or skipped) the setup questions once. `seenVersion`: the version whose "What's new" they were last shown.
    static func decide(setupDone: Bool, seenVersion: String?, current: String, forced: Bool, skipFilm: Bool, scripted: Bool, secondaryWindow: Bool) -> LaunchPlan {
        if secondaryWindow || scripted || forced || skipFilm { return .none }
        if !setupDone { return .newInstall }
        return seenVersion == current ? .none : .update
    }
}

/// The names people see for the optional tools. The programs' own names are never shown in Setup, Settings or Downloads (only in the licence notices and Acknowledgements, which must name them).
enum MediaToolLabel {
    static let video = "Video download tool"
    static let processing = "Media processing tool"
    static func name(for tool: String) -> String { tool == "ffmpeg" ? processing : video }
}

enum AppRelease {
    /// "0.4.1 (24)": the marketing version and the build, so a new build of the same version is also an update.
    static var current: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }
}

/// The same text goes into docs/releases/<version>-build-<n>.md and the GitHub release notes.
enum WhatsNewContent {
    static let title = "What's new in Browser Setu 0.4.3"
    struct Item: Identifiable, Equatable { let symbol: String; let heading: String; let text: String; var id: String { heading } }
    static let items: [Item] = [
        Item(symbol: "rectangle.3.group", heading: "Four new layouts", text: "Hybrid keeps a full toolbar over the page with your tabs in a sidebar. Canvas is just the page, with the address on ⌘L and your tabs on ⇧⌘A. Research Desk puts two pages side by side. Workspace Deck lists every workspace first. They are grouped with the others under Everyday, Organized, Immersive and Productivity."),
        Item(symbol: "folder", heading: "Tab groups in every tab strip", text: "Groups now show inline in Classic, Minimal and One Row, with colour, collapse and drag in and out, as they do in the sidebar."),
        Item(symbol: "sidebar.left", heading: "A calmer sidebar", text: "Workspaces, search and Essentials stay in place while your pinned tabs, open tabs and groups scroll together. Essentials take at most two rows. Floating's sidebar also opens from the keyboard."),
        Item(symbol: "arrow.up.left.and.arrow.down.right", heading: "Full screen keeps your toolbar", text: "Your layout stays as it is in full screen, and Esc leaves it when nothing else is open."),
        Item(symbol: "eye.slash", heading: "Private tabs are marked everywhere", text: "A private tab is clearly marked in every layout, and moving a tab between windows keeps its privacy."),
        Item(symbol: "ipad.and.iphone", heading: "iPad and iPhone", text: "The iPad sidebar steps aside in narrow windows and its toolbar folds into More. Every iPhone layout, including the compact ones, reaches all your tabs from the menu."),
        Item(symbol: "arrow.down.circle", heading: "Video tools are your choice", text: "The video download and media processing tools are optional downloads, not part of the app. Install them from Settings > Media whenever you want video and audio downloads. You see the size first and nothing downloads without your yes."),
    ]
}

struct WhatsNewView: View {
    var onDone: () -> Void
    var body: some View {
        ZStack {
            IntroPalette.ink.ignoresSafeArea()
            VStack(spacing: 22) {
                Text(WhatsNewContent.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(IntroPalette.cream).multilineTextAlignment(.center)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(WhatsNewContent.items) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(IntroPalette.accentLight).frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.heading).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                                    Text(item.text).font(.system(size: 13)).foregroundStyle(IntroPalette.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxWidth: 480)
                Button(action: onDone) {
                    Text("Continue").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(minWidth: 160, minHeight: 44)
                        .background(Capsule().fill(IntroPalette.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("whatsnew-continue")
            }
            .padding(32)
        }
    }
}
