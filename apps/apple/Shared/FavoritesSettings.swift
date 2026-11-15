import SwiftUI

/// How the favorites look: their style, whether they carry names, whether folders show as folders, and the way back to the defaults. Used in the start page's
/// Customize panel and in Settings, so both change the same choices (each profile keeps its own).
struct FavoritesAppearanceControls: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Style", selection: $model.favoriteStyle) { ForEach(FavoriteStyle.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("favorites-style")
            Text(model.favoriteStyle.summary).font(.caption).foregroundStyle(.secondary)
            Toggle("Show names under favorites", isOn: $model.favoriteLabels)
            Toggle("Show folders as folders", isOn: $model.favoriteFoldersShown)
            Text("With folders off, the favorites inside them sit in the row instead.").font(.caption).foregroundStyle(.secondary)
            Button("Restore Layout Defaults") { model.restoreFavoriteLayoutDefaults() }
            Text("Your favorites, folders and bookmarks are not changed.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// How many frequently visited sites show, and the sites you chose not to see again.
struct OftenVisitedControls: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sites shown", selection: $model.oftenCount) { ForEach([4, 6, 8, 12], id: \.self) { Text("\($0)").tag($0) } }
                .accessibilityIdentifier("often-count")
            HStack {
                Text(model.dismissedOftenCount == 0 ? "No hidden sites" : "\(model.dismissedOftenCount) hidden site\(model.dismissedOftenCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Hidden Sites Again") { model.clearDismissedOften() }.disabled(model.dismissedOftenCount == 0)
            }
            Text("Sites come from this profile's history on this device, never from a private tab, and are not saved anywhere else.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
