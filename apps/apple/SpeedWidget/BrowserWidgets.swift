#if APP_GROUP
import SwiftUI
import WidgetKit

/// What the widgets draw: the snapshot the app last left in the shared folder, or a plain placeholder before the app has run.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedStore.Snapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: SharedStore.Snapshot(favorites: [.init(title: "Wikipedia", url: "https://wikipedia.org"), .init(title: "GitHub", url: "https://github.com")],
                                                                    reading: [.init(title: "An article to read", url: "https://example.com")], blockedToday: 128))
    }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) { completion(SnapshotEntry(date: Date(), snapshot: SharedStore.readSnapshot() ?? SharedStore.Snapshot())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: SharedStore.readSnapshot() ?? SharedStore.Snapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

private func open(_ url: String) -> URL { URL(string: "browsersetu://open?url=" + (url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))! }

/// One brand gradient for every home-screen widget, so the set reads as a family.
private let brand = LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.38, green: 0.30, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)

/// A stable colour per site, so the same favorite keeps its tile colour in every refresh.
private func siteColor(_ title: String) -> Color {
    let hue = Double(title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    return Color(hue: hue, saturation: 0.55, brightness: 0.82)
}

private func host(_ url: String) -> String {
    (URL(string: url)?.host ?? url).replacingOccurrences(of: "www.", with: "")
}

struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuSearch", provider: SnapshotProvider()) { _ in SearchView() }
            .configurationDisplayName("Search")
            .description("Opens a new tab ready for typing.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

private struct SearchView: View {
    @Environment(\.widgetFamily) var family
    private let url = URL(string: "browsersetu://command?id=new-tab")!
    var body: some View {
        Group {
            switch family {
            case .accessoryInline: Label("Search Browser Setu", systemImage: "magnifyingglass")
            case .accessoryCircular: Image(systemName: "magnifyingglass").font(.title2.weight(.semibold))
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.headline)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Browser Setu").font(.headline)
                        Text("Search or enter address").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 14) {
                    Text("Browser Setu").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold))
                        Text("Search or enter address").font(.system(size: 16, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 48)
                    .background(Capsule().fill(.white.opacity(0.22)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading) {
                    Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold))
                    Spacer()
                    Text("Search").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Browser Setu").font(.caption).opacity(0.8)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(url)
        .containerBackground(for: .widget) { if family.isHome { brand } else { Color.clear } }
    }
}

private extension WidgetFamily {
    var isHome: Bool { self == .systemSmall || self == .systemMedium || self == .systemLarge }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuFavorites", provider: SnapshotProvider()) { entry in FavoritesView(entry: entry) }
            .configurationDisplayName("Favorites")
            .description("Your favorite sites, one tap away.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct FavoritesView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry
    var body: some View {
        let items = Array(entry.snapshot.favorites.prefix(family == .systemLarge ? 12 : 8))
        Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "star").font(.title2).foregroundStyle(.secondary)
                    Text("No favorites yet").font(.subheadline.weight(.semibold))
                    Text("Add some in Browser Setu").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: family == .systemLarge ? 16 : 10) {
                    ForEach(items) { link in
                        Link(destination: open(link.url)) {
                            VStack(spacing: 5) {
                                Text(String(link.title.prefix(1)).uppercased())
                                    .font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                    .frame(width: 46, height: 46)
                                    .background(siteColor(link.title).gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                Text(link.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: family == .systemLarge ? .top : .center)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct BlockedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuBlocked", provider: SnapshotProvider()) { entry in BlockedView(count: entry.snapshot.blockedToday) }
            .configurationDisplayName("Blocked Today")
            .description("How many ads and trackers were blocked today (an estimate).")
            .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

private struct BlockedView: View {
    @Environment(\.widgetFamily) var family
    let count: Int
    var body: some View {
        Group {
            switch family {
            case .accessoryInline: Label("\(count.formatted()) blocked today", systemImage: "shield.lefthalf.filled")
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "shield.lefthalf.filled").font(.caption)
                    Text(count.formatted(.number.notation(.compactName))).font(.system(size: 16, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled").font(.title3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(count.formatted()).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("blocked today").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Text(count.formatted()).font(.system(size: 38, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    Text("blocked today").font(.system(size: 13, weight: .medium)).opacity(0.85)
                    Text("estimate").font(.system(size: 10)).opacity(0.6)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { if family.isHome { LinearGradient(colors: [Color(red: 0.05, green: 0.55, blue: 0.45), Color(red: 0.10, green: 0.38, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing) } else { Color.clear } }
    }
}

struct ReadingListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuReading", provider: SnapshotProvider()) { entry in ReadingView(entry: entry) }
            .configurationDisplayName("Reading List")
            .description("The articles you saved to read later.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct ReadingView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry
    var body: some View {
        let rows = Array(entry.snapshot.reading.prefix(family == .systemLarge ? 6 : 3))
        VStack(alignment: .leading, spacing: 0) {
            Label("Reading List", systemImage: "book.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                .padding(.bottom, 8)
            if rows.isEmpty {
                Spacer()
                Text("Nothing saved yet").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, link in
                    if index > 0 { Divider().padding(.vertical, 5) }
                    Link(destination: open(link.url)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(host(link.url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

#endif
