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

struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuSearch", provider: SnapshotProvider()) { _ in
            Link(destination: URL(string: "browsersetu://command?id=new-tab")!) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search or enter address").lineLimit(1).font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
                .padding(8)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Search")
        .description("Opens a new tab ready for typing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuFavorites", provider: SnapshotProvider()) { entry in
            let items = Array(entry.snapshot.favorites.prefix(8))
            if items.isEmpty {
                Text("Add favorites in Browser Setu").font(.footnote).foregroundStyle(.secondary).containerBackground(.fill.tertiary, for: .widget)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(items) { link in
                        Link(destination: open(link.url)) {
                            VStack(spacing: 4) {
                                Text(String(link.title.prefix(1)).uppercased()).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                    .frame(width: 40, height: 40).background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                Text(link.title).font(.system(size: 10)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
                .containerBackground(.fill.tertiary, for: .widget)
            }
        }
        .configurationDisplayName("Favorites")
        .description("Your favorite sites, one tap away.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BlockedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuBlocked", provider: SnapshotProvider()) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Label("Blocked today", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                Text(entry.snapshot.blockedToday.formatted()).font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                Text("An estimate of ads and trackers stopped").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Blocked Today")
        .description("How many ads and trackers were blocked today (an estimate).")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct ReadingListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrowserSetuReading", provider: SnapshotProvider()) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Label("Reading list", systemImage: "book").font(.caption).foregroundStyle(.secondary)
                if entry.snapshot.reading.isEmpty { Text("Nothing saved").font(.footnote).foregroundStyle(.secondary) }
                ForEach(entry.snapshot.reading.prefix(4)) { link in
                    Link(destination: open(link.url)) { Text(link.title).font(.footnote).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Reading List")
        .description("The articles you saved to read later.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

#endif
