import SwiftUI

/// A small menu in the address bar for switching search engines. The choice is saved as the profile's search engine, so it holds for
/// every search from then on, until it is changed again.
struct SearchEngineMenu: View {
    @EnvironmentObject var model: BrowserModel
    /// Just the engine's letter, for tight spaces.
    var compact = false

    private var current: SearchEngine? { SearchEngines.preset(for: model.searchTemplate) }
    private var name: String { current?.name ?? "Custom" }
    /// The engine's own site icon, once it has been fetched (see Settings › Site Icons); the letter until then.
    @ObservedObject private var icons = FaviconStore.shared
    private var searchPage: URL? { URL(string: model.searchTemplate.replacingOccurrences(of: "{}", with: "")) }
    private var icon: PlatformImage? { searchPage.flatMap { icons.image(forURL: $0.absoluteString, points: 16) } }

    var body: some View {
        Menu {
            ForEach(SearchEngines.presets) { engine in
                Button { model.setSearchTemplate(engine.template) } label: {
                    if engine.id == current?.id { Label(engine.name, systemImage: "checkmark") } else { Text(engine.name) }
                }
            }
            if current == nil {
                Divider()
                Text("Using a custom search address")
            }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let icon {
                        #if os(macOS)
                        Image(platform: icon)
                            .frame(width: 22, height: 22)
                            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        #else
                        Image(platform: icon).resizable().interpolation(.high).scaledToFit()
                            .padding(3)
                            .frame(width: 22, height: 22)
                            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        #endif
                    } else {
                        Text(String(name.prefix(1)))
                            .scaledFont(11, weight: .bold, design: .rounded)
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Theme.tileColor(for: name), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                if !compact {
                    Text(name).scaledFont(12.5, weight: .medium).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, compact ? 2 : 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .task(id: model.searchTemplate) {
            // The engine is the one site the user has chosen to talk to, so its icon is fetched the same way as any site's.
            if model.fetchSiteIcons, !model.activeIsPrivate, let page = searchPage { await FaviconStore.shared.learn(pageURL: page, candidates: []) }
        }
        .help("Search with \(name). Click to change the search engine.")
        .accessibilityLabel("Search engine")
        .accessibilityValue(name)
        .accessibilityIdentifier("search-engine-menu")
    }
}
