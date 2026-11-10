import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A line of a player's subtitles, with when it is said.
struct TranscriptLine: Identifiable, Equatable {
    var id: Int
    var start: Double
    var text: String
}

@MainActor
extension BrowserModel {
    // MARK: Saving to Research (Watch Later, notes that link back to a moment)

    private func researchCollection(named name: String) -> ResearchCollection? {
        research.collections.first { $0.name == name } ?? research.create(name: name)
    }

    /// Saves this page to the "Watch Later" collection in Research, with how far you got, so it can be opened and carried on. Only for pages in normal tabs.
    func saveWatchLater(_ video: DetectedVideo) {
        guard playerCanStore, let tab = active, let url = tab.url, url.scheme?.hasPrefix("http") == true,
              let collection = researchCollection(named: "Watch Later") else { notice = "Watch Later keeps pages from normal tabs only."; return }
        var item = ResearchItem(kind: .page, title: tab.displayTitle, url: url.absoluteString, text: nil, citation: nil)
        if video.duration > 0 { item.place = min(max(video.time / video.duration, 0), 1) }
        if video.time >= 20 { item.comment = "Carry on at \(DetectedVideo.clock(video.time))" }
        item.captured = Date()
        notice = research.add(item, to: collection.id) ? "Saved to Watch Later." : "Watch Later is full."
    }

    /// A note of your own, saved to Research with a link that opens the page at this moment (`#t=` seconds, the media-fragment form most players honour).
    func saveClipNote(_ video: DetectedVideo) {
        guard playerCanStore, let tab = active, let url = tab.url, url.scheme?.hasPrefix("http") == true else { notice = "Notes are kept for pages in normal tabs only."; return }
        let at = DetectedVideo.clock(video.time), seconds = Int(video.time)
        Task {
            guard let text = await Dialogs.promptText(title: "Note at \(at)", message: "Saved to Research with a link back to this moment.", placeholder: "What is here?")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let collection = researchCollection(named: "Video notes") else { return }
            var link = URLComponents(url: url, resolvingAgainstBaseURL: false)
            link?.fragment = "t=\(seconds)"
            var item = ResearchItem(kind: .note, title: "\(tab.displayTitle) · \(at)", url: link?.string ?? url.absoluteString, text: text, citation: nil)
            item.captured = Date()
            notice = research.add(item, to: collection.id) ? "Note saved to Research." : "That collection is full."
        }
    }

    // MARK: A picture, and the words

    /// Copies the picture on screen to the clipboard, when the video allows it.
    func captureFrame(_ video: DetectedVideo) {
        Task {
            guard let result = await active?.engine.mediaData(MediaScripts.capture, id: video.id) else { notice = "The page could not be reached."; return }
            if let problem = result["error"] as? String { notice = problem; return }
            guard let text = result["data"] as? String, let comma = text.firstIndex(of: ","), let data = Data(base64Encoded: String(text[text.index(after: comma)...])) else { notice = "No picture came back."; return }
            #if os(iOS)
            UIPasteboard.general.setData(data, forPasteboardType: "public.png")
            #else
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
            #endif
            notice = "Picture copied."
        }
    }

    func loadTranscript(_ video: DetectedVideo) async -> (label: String, lines: [TranscriptLine])? {
        guard let result = await active?.engine.mediaData(MediaScripts.transcript, id: video.id) else { notice = "The page could not be reached."; return nil }
        if let problem = result["error"] as? String { notice = problem; return nil }
        let cues = (result["cues"] as? [[String: Any]]) ?? []
        let lines = cues.enumerated().compactMap { i, c -> TranscriptLine? in
            let text = ((c["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = (c["start"] as? NSNumber)?.doubleValue else { return nil }
            return TranscriptLine(id: i, start: start, text: text)
        }
        return ((result["label"] as? String) ?? "Subtitles", lines)
    }

    // MARK: Profiles for a site: the subtitle language you chose is chosen again

    func rememberSubtitle(_ label: String?) {
        guard playerCanStore, let host = active?.url?.host else { return }
        if let label { playerSiteSubtitles[host] = label } else { playerSiteSubtitles.removeValue(forKey: host) }
        saveSetting("player_site_subtitles", (try? String(data: JSONEncoder().encode(playerSiteSubtitles), encoding: .utf8)) ?? "{}")
    }

    func loadPlayerSiteSubtitles(_ text: String?) {
        guard let data = text?.data(using: .utf8), let table = try? JSONDecoder().decode([String: String].self, from: data) else { playerSiteSubtitles = [:]; return }
        playerSiteSubtitles = table
    }

    /// Once per player: if this site has a subtitle language chosen before and nothing is showing, it is turned on.
    func applySiteSubtitle(to video: DetectedVideo) {
        guard playerCanStore, let host = active?.url?.host, let label = playerSiteSubtitles[host], !video.tracks.isEmpty, !video.tracks.contains(where: \.showing),
              !player.subtitleApplied.contains(video.id), let index = video.tracks.firstIndex(where: { $0.label == label }) else { return }
        player.subtitleApplied.insert(video.id)
        Task { _ = await active?.engine.controlVideo(id: video.id, action: VideoAction.subtitle.rawValue, value: Double(index)) }
    }

    // MARK: Across tabs

    /// With "Pause other tabs when one starts" on, a tab that begins to play sound pauses the rest. A tab using the camera or microphone (a call) is left alone.
    func applyAudioFocus(startedIn tab: TabController) {
        guard audioFocus else { return }
        for other in tabs where other.id != tab.id && other.playingAudio && !other.usesCamera && !other.usesMicrophone { pauseMedia(in: other) }
    }

    /// The battery policy: sound that has played in a background tab for the chosen number of minutes is paused (never in a call). Called with the window's background check.
    func checkBackgroundMediaPolicy(now: Date = Date()) {
        guard mediaBackgroundMinutes > 0 else { elsewhereSince = [:]; return }
        let ids = Set(playingElsewhere.map(\.id))
        elsewhereSince = elsewhereSince.filter { ids.contains($0.key) }
        for tab in playingElsewhere where !tab.usesCamera && !tab.usesMicrophone {
            let since = elsewhereSince[tab.id] ?? now
            elsewhereSince[tab.id] = since
            if now.timeIntervalSince(since) >= Double(mediaBackgroundMinutes) * 60 {
                pauseMedia(in: tab)
                elsewhereSince[tab.id] = nil
                notice = "Paused “\(tab.displayTitle)” to save battery."
            }
        }
    }
}

/// The words a player has, searchable, each line a way to jump to its moment. Only what the player already exposes; nothing is fetched or recognised.
struct TranscriptView: View {
    @EnvironmentObject var model: BrowserModel
    let video: DetectedVideo
    let close: () -> Void
    @State private var label = ""
    @State private var lines: [TranscriptLine] = []
    @State private var query = ""
    @State private var loaded = false

    private var shown: [TranscriptLine] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            PanelList {
                if loaded && lines.isEmpty { Text("Nothing to show.").foregroundStyle(.secondary) }
                ForEach(shown) { line in
                    Button { model.playerCommand(.seek, line.start) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(DetectedVideo.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 52, alignment: .leading)
                            Text(line.text).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        }
                    }
                    .contextMenu {
                        Button("Copy this line", systemImage: "doc.on.doc") { copy(line.text) }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search the words")
            .navigationTitle(label.isEmpty ? "Transcript" : label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheetDoneToolbar(action: close)
            .task {
                if let result = await model.loadTranscript(video) { label = result.label; lines = result.lines }
                loaded = true
            }
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
