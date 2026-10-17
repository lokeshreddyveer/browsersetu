import Foundation
import SwiftUI

/// A video or audio player found on the page, and what can be done with it from here.
struct DetectedVideo: Identifiable, Equatable {
    var id: Int
    var source: String
    var duration: Double
    var time: Double
    var paused: Bool
    var rate: Double
    var protected: Bool
    var isVideo: Bool

    init(index: Int, raw: [String: Any]) {
        id = index
        source = (raw["src"] as? String) ?? ""
        duration = (raw["duration"] as? NSNumber)?.doubleValue ?? 0
        time = (raw["currentTime"] as? NSNumber)?.doubleValue ?? 0
        paused = (raw["paused"] as? NSNumber)?.boolValue ?? true
        rate = (raw["rate"] as? NSNumber)?.doubleValue ?? 1
        protected = (raw["hasMediaKeys"] as? NSNumber)?.boolValue ?? false
        isVideo = (raw["tag"] as? String) != "audio"
    }

    var title: String { (isVideo ? "Video" : "Audio") + (duration.isFinite && duration > 0 ? " · " + Self.clock(duration) : " · live") }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum VideoAction: String { case play, pause, speed, pictureInPicture, fullscreen, seek }

struct VideoToolsView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var videos: [DetectedVideo] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && videos.isEmpty {
                ContentUnavailableView("No Video Found", systemImage: "play.slash", description: Text("No video or audio player was found on this page."))
            } else {
                List(videos) { video in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: video.isVideo ? "play.rectangle" : "waveform").foregroundStyle(.secondary)
                            Text(video.title).fontWeight(.medium)
                            if video.protected { Text("Protected").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                            Spacer()
                            Text(DetectedVideo.clock(video.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack {
                            Button(video.paused ? "Play" : "Pause") { run(video, video.paused ? .play : .pause) }
                            Menu("Speed \(video.rate.formatted())×") {
                                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { run(video, .speed, rate) } }
                            }
                            if video.isVideo {
                                Button("Pop Out") { run(video, .pictureInPicture) }.disabled(video.protected)
                                Button("Full Screen") { run(video, .fullscreen) }
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        if video.protected { Text("Pop Out is off for protected video. The site does not allow it.").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        videos = (await model.active?.engine.mediaElements() ?? []).enumerated().map { DetectedVideo(index: $0.offset, raw: $0.element) }
        loaded = true
    }

    private func run(_ video: DetectedVideo, _ action: VideoAction, _ value: Double = 0) {
        Task { await model.active?.engine.controlVideo(index: video.id, action: action.rawValue, value: value); await refresh() }
    }
}

/// Offers targeted fixes for a page that does not work, one at a time, from the least to the most drastic.
struct PageRepairView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Form {
            Section {
                step("Reload", "Fetches the page again.", "arrow.clockwise") { model.active?.reload() }
                step("Pause protection on this site", "Stops blocking on this website only, then reloads. Turn it back on from the shield.", "shield.slash") {
                    model.privacy.toggleSite(host: model.active?.url?.host); model.active?.reload()
                }
                step("Load the desktop version", "For pages that fail on the mobile layout.", "desktopcomputer") { model.active?.engine.setDesktopMode(true); model.active?.reload() }
                step("Let this site start video by itself", "If a player on this page waits for a tap that it should not need.", "play.circle") {
                    model.setAutoplayException(host: model.active?.url?.host, allowed: true); model.active?.reload()
                }
                step("Turn JavaScript back on", "In case it was switched off for the page.", "curlybraces") { model.active?.engine.setJavaScriptEnabled(true); model.active?.reload() }
                step("Clear this site’s data and reload", "Removes its cookies and storage. You will be signed out of it.", "trash") {
                    guard let host = model.active?.url?.host else { return }
                    Task { await model.removeSiteData(host: host); model.active?.reload() }
                }
            } header: { Text("Try These in Order") } footer: { Text("Each step changes only this website. Nothing is pretended: the site still sees Browser Setu as it is.") }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("page-repair")
    }

    private func step(_ title: String, _ detail: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { VStack(alignment: .leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol) }
        }
        .buttonStyle(.plain)
    }
}

enum InfiniteScrollScript {
    /// Holds back a page's "load more as you reach the end" until you ask. Only watchers whose target sits near the bottom are held,
    /// so pictures further up still load as you scroll.
    static let source = """
    if (!window.__bsHold) { window.__bsHold = true;
      var Native = window.IntersectionObserver, held = [], button = null, allow = false;
      var show = function () {
        if (button || !document.body) return;
        button = document.createElement('button'); button.textContent = 'Load more';
        button.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;padding:10px 16px;border-radius:999px;border:0;background:#111;color:#fff;font:600 14px -apple-system,sans-serif;box-shadow:0 2px 12px rgba(0,0,0,.4)';
        button.onclick = function () { allow = true; var list = held; held = []; list.forEach(function (h) { try { h[0].call(h[1], h[2], h[3]); } catch (e) {} }); button.remove(); button = null; setTimeout(function () { allow = false; }, 1500); };
        document.body.appendChild(button);
      };
      window.IntersectionObserver = function (callback, options) {
        var self = this;
        return new Native(function (entries, observer) {
          var keep = [], hold = [];
          entries.forEach(function (e) {
            var top = e.target.getBoundingClientRect().top + window.scrollY, nearEnd = top > document.documentElement.scrollHeight - window.innerHeight * 2.5;
            (e.isIntersecting && nearEnd && !allow ? hold : keep).push(e);
          });
          if (keep.length) callback.call(self, keep, observer);
          if (hold.length) { held.push([callback, self, hold, observer]); show(); }
        }, options);
      };
      window.IntersectionObserver.prototype = Native.prototype;
    }
    """

    static var script: UserScript {
        UserScript(name: "Pause infinite scroll", sites: ["*"], source: source, enabled: true, runAtStart: true, inPageWorld: true)
    }
}

extension BrowserModel {
    /// The scripts the user wrote plus the ones the browser adds for settings that need them.
    var effectiveUserScripts: [UserScript] {
        userScripts.filter(\.enabled) + (pauseInfiniteScroll ? [InfiniteScrollScript.script] : [])
    }
}
