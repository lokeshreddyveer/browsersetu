import CryptoKit
import Foundation

/// A position the person marked in a piece of media.
struct MediaMark: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var label: String
}

/// A saved A–B repeat range for a piece of media (a passage to practise, a bar of music).
struct MediaLoopPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: Double
    var b: Double
    var label: String
}

/// Where a piece of media was left, and the positions marked in it. The media is named by a fingerprint, never by its address.
struct MediaResumeEntry: Codable, Equatable {
    var key: String
    var time: Double
    var duration: Double
    var saved: Date
    var marks: [MediaMark] = []
    var loops: [MediaLoopPreset] = []
}

enum MediaResumeRules {
    static let limit = 200
    static let keep: TimeInterval = 60 * 86_400
    static let marksPerMedia = 20
    static let loopsPerMedia = 10

    /// Long enough to be worth coming back to, past the first moments, and not nearly finished.
    static func worthResuming(time: Double, duration: Double) -> Bool { duration >= 120 && time >= 20 && time <= duration - 30 }

    /// A name for one piece of media that stores no address: a fingerprint of the page (without its query or fragment) and, when the source is a plain file, of the source's host and
    /// path (without its query, where tokens live). A `blob:` source means nothing once the page is closed, so the length of the media stands in for it.
    static func key(pageURL: URL?, src: String, duration: Double) -> String? {
        guard let page = pageURL, page.scheme?.hasPrefix("http") == true else { return nil }
        func plain(_ url: URL) -> String {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.query = nil; c?.fragment = nil
            return c?.string ?? url.absoluteString
        }
        var text = plain(page)
        if let source = URL(string: src), source.scheme?.hasPrefix("http") == true { text += "|" + plain(source) } else { text += "|d\(Int(duration.rounded()))" }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The list with this entry first, the same media's older entry gone, old ones expired, and no more than the limit.
    static func updating(_ list: [MediaResumeEntry], with entry: MediaResumeEntry, now: Date = Date()) -> [MediaResumeEntry] {
        var out = list.filter { $0.key != entry.key && now.timeIntervalSince($0.saved) < keep }
        out.insert(entry, at: 0)
        return Array(out.prefix(limit))
    }
}

@MainActor
extension BrowserModel {
    /// Anything is kept only for a normal tab: a private, scratch, Glance or guest tab leaves nothing, so neither positions nor marks are written there.
    var playerCanStore: Bool { !(active?.leavesNoTrace ?? true) }

    func playerKey(_ video: DetectedVideo) -> String? {
        MediaResumeRules.key(pageURL: active?.url, src: video.source, duration: video.duration)
    }

    func mediaEntry(for video: DetectedVideo) -> MediaResumeEntry? {
        guard playerCanStore, let key = playerKey(video) else { return nil }
        return mediaResumeList.first { $0.key == key }
    }

    /// The offer to carry on: only when the person chose to be offered it, and the media is back at its start.
    func resumeOffer(for video: DetectedVideo) -> Double? {
        guard resumeMedia, video.time < 5, let entry = mediaEntry(for: video), entry.time >= 20,
              MediaResumeRules.worthResuming(time: entry.time, duration: entry.duration) else { return nil }
        return entry.time
    }

    /// Called as the player is read: remembers where a playing, eligible player has got to, at most every few seconds.
    func notePlayerPosition(_ video: DetectedVideo, force: Bool = false) {
        guard resumeMedia, playerCanStore, !video.isLive, MediaResumeRules.worthResuming(time: video.time, duration: video.duration), let key = playerKey(video) else { return }
        if !force, Date().timeIntervalSince(lastResumeSave) < 5 { return }
        var entry = mediaResumeList.first { $0.key == key } ?? MediaResumeEntry(key: key, time: video.time, duration: video.duration, saved: Date())
        entry.time = video.time; entry.duration = video.duration; entry.saved = Date()
        storeMediaEntries(MediaResumeRules.updating(mediaResumeList, with: entry))
        lastResumeSave = Date()
    }

    func addPlayerMark(_ video: DetectedVideo) {
        guard playerCanStore, let key = playerKey(video), video.time > 0 else { return }
        var entry = mediaResumeList.first { $0.key == key } ?? MediaResumeEntry(key: key, time: 0, duration: video.duration, saved: Date())
        guard entry.marks.count < MediaResumeRules.marksPerMedia, !entry.marks.contains(where: { abs($0.time - video.time) < 1 }) else { notice = "That place is already marked."; return }
        entry.marks.append(MediaMark(time: video.time, label: DetectedVideo.clock(video.time)))
        entry.marks.sort { $0.time < $1.time }
        entry.saved = Date()
        storeMediaEntries(MediaResumeRules.updating(mediaResumeList, with: entry))
    }

    func removePlayerMark(_ id: UUID, from video: DetectedVideo) {
        guard let key = playerKey(video), var entry = mediaResumeList.first(where: { $0.key == key }) else { return }
        entry.marks.removeAll { $0.id == id }
        storeMediaEntries(MediaResumeRules.updating(mediaResumeList, with: entry))
    }

    func savePlayerLoop(_ video: DetectedVideo) {
        guard playerCanStore, let key = playerKey(video), let a = video.repeatA, let b = video.repeatB, b > a else { return }
        var entry = mediaResumeList.first { $0.key == key } ?? MediaResumeEntry(key: key, time: 0, duration: video.duration, saved: Date())
        guard entry.loops.count < MediaResumeRules.loopsPerMedia, !entry.loops.contains(where: { abs($0.a - a) < 0.5 && abs($0.b - b) < 0.5 }) else { notice = "That repeat is already saved."; return }
        entry.loops.append(MediaLoopPreset(a: a, b: b, label: DetectedVideo.clock(a) + " – " + DetectedVideo.clock(b)))
        entry.saved = Date()
        storeMediaEntries(MediaResumeRules.updating(mediaResumeList, with: entry))
    }

    func removePlayerLoop(_ id: UUID, from video: DetectedVideo) {
        guard let key = playerKey(video), var entry = mediaResumeList.first(where: { $0.key == key }) else { return }
        entry.loops.removeAll { $0.id == id }
        storeMediaEntries(MediaResumeRules.updating(mediaResumeList, with: entry))
    }

    /// Starts a saved repeat: a command whose name carries its two points.
    func playLoop(_ preset: MediaLoopPreset) {
        guard let video = player.current else { return }
        Task {
            if let problem = await active?.engine.controlVideo(id: video.id, action: "setAB:\(preset.a):\(preset.b)", value: 0) { notice = problem }
            await refreshPlayers()
        }
    }

    func clearMediaPositions() { storeMediaEntries([]) }

    func storeMediaEntries(_ list: [MediaResumeEntry]) {
        mediaResumeList = list
        saveSetting("media_resume", (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]")
    }

    func loadMediaEntries(_ text: String?) {
        guard let data = text?.data(using: .utf8), let list = try? JSONDecoder().decode([MediaResumeEntry].self, from: data) else { mediaResumeList = []; return }
        mediaResumeList = list
    }

    /// How far the skip buttons go on the page in front: this site's own choice if it has one, else the general one.
    var playerStep: Double {
        if let host = active?.url?.host, let step = playerSiteSteps[host] { return step }
        return playerSeekStep
    }

    func setPlayerSiteStep(_ step: Double?, host: String) {
        if let step { playerSiteSteps[host] = step } else { playerSiteSteps.removeValue(forKey: host) }
        saveSetting("player_site_steps", (try? String(data: JSONEncoder().encode(playerSiteSteps), encoding: .utf8)) ?? "{}")
    }

    func loadPlayerSiteSteps(_ text: String?) {
        guard let data = text?.data(using: .utf8), let table = try? JSONDecoder().decode([String: Double].self, from: data) else { playerSiteSteps = [:]; return }
        playerSiteSteps = table.filter { [5.0, 10, 15, 30].contains($0.value) }
    }

    /// One command from the keyboard or a menu, for the player that is really being watched, without the panel being open. `.play` means play or pause, whichever applies.
    func playerQuick(_ action: VideoAction, _ value: Double = 0) {
        Task {
            await refreshPlayers()
            guard let video = player.current else { notice = "No video or audio was found on this page."; return }
            let chosen: VideoAction = action == .play ? (video.paused ? .play : .pause) : action
            let amount: Double = action == .theater ? (video.theater ? 0 : 1) : (action == .mute ? (video.muted ? 0 : 1) : value)
            if let problem = await active?.engine.controlVideo(id: video.id, action: chosen.rawValue, value: amount) { notice = problem }
            if !playerPanelVisible { player.videos = []; player.loaded = false } else { await refreshPlayers() }
        }
    }
}
