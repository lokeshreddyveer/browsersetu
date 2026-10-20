import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedLiveActivity()
        #if APP_GROUP
        SearchWidget()
        FavoritesWidget()
        BlockedWidget()
        ReadingListWidget()
        #endif
    }
}

/// The live network speed in the Dynamic Island (and on the Lock Screen while the browser is open).
struct SpeedLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            HStack(spacing: 18) {
                Label(context.isStale ? "–" : SpeedText.full(context.state.down), systemImage: "arrow.down")
                Label(context.isStale ? "–" : SpeedText.full(context.state.up), systemImage: "arrow.up")
            }
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale ? "–" : SpeedText.full(context.state.down), systemImage: "arrow.down")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(context.isStale ? "–" : SpeedText.full(context.state.up), systemImage: "arrow.up")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Live network speed").font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
            } compactTrailing: {
                Text(context.isStale ? "–" : SpeedText.short(context.state.down)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            } minimal: {
                Image(systemName: "speedometer").font(.system(size: 11, weight: .bold))
            }
        }
    }
}
