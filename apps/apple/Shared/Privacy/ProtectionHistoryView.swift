import Charts
import SwiftUI

/// What the rules have refused over time: a bar for each day, and the sites that had the most. Estimates (WebKit does not report
/// blocks), kept on this device, never from private tabs.
struct ProtectionHistoryView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var span = 14

    private var days: [(day: Date, count: Int)] { model.blockedStats.dailyTotals(days: span) }
    private var sites: [(host: String, count: Int)] { model.blockedStats.topSites(days: span) }
    private var total: Int { days.reduce(0) { $0 + $1.count } }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $span) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .firstTextBaseline) {
                    Text(total.formatted()).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    Text("blocked in \(span) days").foregroundStyle(.secondary)
                }
                Chart(days, id: \.day) { item in
                    BarMark(x: .value("Day", item.day, unit: .day), y: .value("Blocked", item.count))
                        .foregroundStyle(Theme.accent.gradient).cornerRadius(2)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: span <= 14 ? 7 : 5)) }
                .frame(height: 140)
                .accessibilityLabel("Blocked per day for the last \(span) days, \(total) in all")
            }
            Section("Sites with the most") {
                if sites.isEmpty { Text("Nothing yet. Counts appear as you browse.").foregroundStyle(.secondary) }
                ForEach(sites, id: \.host) { site in
                    HStack {
                        Text(site.host).lineLimit(1)
                        Spacer()
                        Text(site.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("These are estimates: WebKit does not report blocks, so a load that fails with no network record is counted. Kept on this device. Private tabs are never counted.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset Counts", role: .destructive) { model.resetBlockedStats() }
                    .disabled(model.blockedStats.total(.all) == 0)
            }
        }
        .formStyle(.grouped)
        .animation(.easeOut(duration: 0.2), value: span)
    }
}
