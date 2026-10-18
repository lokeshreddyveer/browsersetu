import Foundation
import SwiftUI

/// A page that played sound or video, remembered so it can be found again.
struct MediaHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var url: String
    var site: String
}

enum MediaHistoryRules {
    static let limit = 200

    /// Newest first; the same address twice in a row, or within ten minutes of its last entry, is one entry.
    static func adding(_ entry: MediaHistoryEntry, to list: [MediaHistoryEntry]) -> [MediaHistoryEntry] {
        var out = list
        if let i = out.firstIndex(where: { $0.url == entry.url }), entry.date.timeIntervalSince(out[i].date) < 600 { out.remove(at: i) }
        out.insert(entry, at: 0)
        return Array(out.prefix(limit))
    }
}

enum SleepTimerChoice: Int, CaseIterable, Identifiable {
    case fifteen = 15, thirty = 30, sixty = 60, ninety = 90
    var id: Int { rawValue }
    var title: String { "\(rawValue) minutes" }
    func end(from now: Date = Date()) -> Date { now.addingTimeInterval(Double(rawValue) * 60) }
}

@MainActor
extension BrowserModel {
    /// Tabs other than the one in front that are playing sound.
    var playingElsewhere: [TabController] { tabs.filter { $0.playingAudio && $0.id != activeID } }

    func noteMediaStarted(_ tab: TabController) {
        guard keepMediaHistory, !tab.isPrivate, let url = tab.url, url.scheme?.hasPrefix("http") == true else { return }
        mediaHistory = MediaHistoryRules.adding(MediaHistoryEntry(title: tab.displayTitle, url: url.absoluteString, site: displayHost(url)), to: mediaHistory)
        saveSetting("media_history", (try? String(data: JSONEncoder().encode(mediaHistory), encoding: .utf8)) ?? "[]")
    }

    func clearMediaHistory() {
        mediaHistory = []
        saveSetting("media_history", "[]")
    }

    /// Pauses every video and audio player on the tab.
    func pauseMedia(in tab: TabController) {
        tab.engine.runPageScript("document.querySelectorAll('video,audio').forEach(function (m) { try { m.pause(); } catch (e) {} });", arguments: [:])
        Task { await tab.refreshAudio() }
    }

    func pauseAllMedia() {
        for tab in tabs where !tab.isDiscarded && !tab.isBlank { pauseMedia(in: tab) }
    }

    func setSleepTimer(_ choice: SleepTimerChoice?) {
        mediaSleepAt = choice?.end()
        notice = choice.map { "Media will pause in \($0.title)." } ?? "Sleep timer off."
    }

    /// Called with the window's background check: when the time comes, everything pauses.
    func checkMediaSleepTimer(now: Date = Date()) {
        guard let end = mediaSleepAt, now >= end else { return }
        mediaSleepAt = nil
        pauseAllMedia()
        notice = "Sleep timer: media paused."
    }
}

/// Cross-tab controls, the sleep timer and the history, shown above the players on the page in Video Tools.
struct MediaOverviewSections: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if !model.playingElsewhere.isEmpty {
            Section("Playing in other tabs") {
                ForEach(model.playingElsewhere) { tab in
                    HStack {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.displayTitle).lineLimit(1)
                            Text(displayHost(tab.url)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pause") { model.pauseMedia(in: tab) }
                        Button(tab.muted ? "Unmute" : "Mute") { tab.setMuted(!tab.muted) }
                        Button("Go to Tab") { model.select(tab.id) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Pause Everything") { model.pauseAllMedia() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        Section {
            if let end = model.mediaSleepAt {
                HStack {
                    Label("Pauses at \(end.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz")
                    Spacer()
                    Button("Cancel") { model.setSleepTimer(nil) }.buttonStyle(.borderless)
                }
            } else {
                Menu("Sleep Timer") {
                    ForEach(SleepTimerChoice.allCases) { choice in Button(choice.title) { model.setSleepTimer(choice) } }
                }
            }
        } footer: {
            Text("Pauses video and audio in every tab when the time is up.")
        }
        Section {
            Toggle("Keep a list of what I played", isOn: $model.keepMediaHistory)
            if model.keepMediaHistory {
                if model.mediaHistory.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                ForEach(model.mediaHistory.prefix(15)) { entry in
                    Button { model.open(urlString: entry.url, newTab: true) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).lineLimit(1)
                            Text("\(entry.site) · \(entry.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !model.mediaHistory.isEmpty { Button("Clear Media History", role: .destructive) { model.clearMediaHistory() } }
            }
        } header: { Text("Recently Played") } footer: {
            Text("Pages that played sound or video in normal tabs, kept on this device. Private tabs are never listed.")
        }
    }
}
