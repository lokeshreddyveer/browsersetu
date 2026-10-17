import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What this device's WebKit can do with video and audio, found out by asking it, and plain-language answers when something will not play.
struct MediaFeature: Identifiable, Equatable {
    enum Status: String { case supported, partial, unsupported, unknown }
    var id: String
    var title: String
    var status: Status
    var detail: String
}

/// Whether something is capturing or mirroring the screen, which makes protected (DRM) video go black or refuse to play.
struct ProtectedOutput: Equatable {
    var screenCaptured: Bool
    var mirrored: Bool
    var externalDisplays: Int

    var blocksProtectedVideo: Bool { screenCaptured || mirrored }
    var summary: String {
        if screenCaptured { return "The screen is being recorded or shared. Protected video is usually blocked while that is on." }
        if mirrored { return "The display is mirrored. Some protected video refuses to play on a mirrored or unsupported display." }
        if externalDisplays > 0 { return "\(externalDisplays) external display\(externalDisplays == 1 ? "" : "s") connected. Protected video plays only if the display meets the service's copy-protection rules (HDCP), which apps cannot check ahead of time." }
        return "No recording or mirroring in progress."
    }

    @MainActor static func current() -> ProtectedOutput {
        #if os(macOS)
        let displays = NSScreen.screens.count
        var online: [CGDirectDisplayID] = [0, 0, 0, 0, 0, 0, 0, 0]
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &online, &count)
        let mirrored = online.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
        return ProtectedOutput(screenCaptured: false, mirrored: mirrored, externalDisplays: max(0, displays - 1))
        #else
        let screenCount = Set(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene).map { ObjectIdentifier($0.screen) } }).count
        return ProtectedOutput(screenCaptured: UIScreen.main.isCaptured, mirrored: screenCount > 1, externalDisplays: max(0, screenCount - 1))
        #endif
    }
}

struct MediaCapabilityReport: Equatable {
    var features: [MediaFeature]
    var date = Date()

    var plainText: String {
        let marks: [MediaFeature.Status: String] = [.supported: "yes", .partial: "partly", .unsupported: "no", .unknown: "unknown"]
        return features.map { "\($0.title): \(marks[$0.status] ?? "?") — \($0.detail)" }.joined(separator: "\n")
    }

    /// Turns what the page-side check found into a list of features with a plain explanation each.
    static func build(from raw: [String: Any], output: ProtectedOutput) -> MediaCapabilityReport {
        func flag(_ value: Any?) -> Bool { (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false) }
        func text(_ value: Any?) -> String { (value as? String) ?? "" }
        var out: [MediaFeature] = []

        let eme = raw["eme"] as? [String: Any] ?? [:]
        let fairplay = text(eme["fairplay"]) == "supported" || text(eme["fairplay1"]) == "supported"
        out.append(MediaFeature(id: "fairplay", title: "FairPlay Streaming (DRM)",
                                status: eme.isEmpty ? .unknown : (fairplay ? .supported : .unsupported),
                                detail: fairplay ? "Protected video from services that use Apple's FairPlay can play."
                                                 : (eme.isEmpty ? "Could not be checked." : "Not available here (\(text(eme["fairplay"]).isEmpty ? "no answer" : text(eme["fairplay"]))). Protected video from FairPlay services will not play.")))
        let others = ["widevine": "Widevine", "playready": "PlayReady"].compactMap { key, name in text(eme[key]) == "supported" ? name : nil }
        out.append(MediaFeature(id: "other-drm", title: "Widevine and PlayReady",
                                status: others.isEmpty ? .unsupported : .supported,
                                detail: others.isEmpty ? "Not offered by WebKit browsers. Services that only use these cannot play protected video here; many also offer FairPlay."
                                                       : "Available: \(others.joined(separator: ", "))."))

        let hls = text(raw["hls"])
        out.append(MediaFeature(id: "hls", title: "HLS streaming", status: hls.isEmpty ? .unsupported : .supported,
                                detail: hls.isEmpty ? "Live and adaptive streams in HLS format will not play natively." : "Native HLS playback is available."))

        let mse = raw["mse"] as? [String: Any]
        let managed = flag(raw["managedMse"])
        let mseStatus: MediaFeature.Status = mse != nil ? .supported : (managed ? .partial : .unsupported)
        out.append(MediaFeature(id: "mse", title: "Media Source Extensions", status: mseStatus,
                                detail: mse != nil ? "Adaptive streaming players that build the video in the page (MSE) work."
                                                   : (managed ? "Only the managed form is available: some players work, others fall back to HLS." : "Players that rely on MSE will not work; HLS may be used instead.")))

        let codecs: [(String, String, String)] = [("h264", "H.264", "Used by almost every site."), ("hevc", "HEVC (H.265)", "Used for 4K and HDR by some services."),
                                                  ("vp9", "VP9", "Used by YouTube for some resolutions."), ("av1", "AV1", "A newer format; needs a recent chip for smooth playback.")]
        let decoding = raw["decoding"] as? [String: Any] ?? [:]
        for (key, name, note) in codecs {
            let info = decoding[key] as? [String: Any] ?? [:]
            let supported = flag(info["supported"]), efficient = flag(info["powerEfficient"]), smooth = flag(info["smooth"])
            out.append(MediaFeature(id: "codec-" + key, title: name + " video",
                                    status: info.isEmpty ? .unknown : (supported ? (smooth ? .supported : .partial) : .unsupported),
                                    detail: info.isEmpty ? "Could not be checked." : (supported ? (efficient ? "Plays using the chip's own video hardware (low power). " : "Plays in software, which uses more power. ") + note
                                                                                    : "Not supported on this device. Sites will use another format.")))
        }
        let hardware = codecs.filter { flag((decoding[$0.0] as? [String: Any])?["powerEfficient"]) }.map(\.1)
        out.append(MediaFeature(id: "hardware", title: "Hardware decoding", status: hardware.isEmpty ? (decoding.isEmpty ? .unknown : .unsupported) : .supported,
                                detail: hardware.isEmpty ? "None of the formats checked use the video hardware." : "Hardware used for: \(hardware.joined(separator: ", "))."))

        let fullscreen = raw["fullscreen"] as? [String: Any] ?? [:]
        out.append(MediaFeature(id: "fullscreen", title: "Full-screen video", status: flag(fullscreen["video"]) || flag(fullscreen["element"]) ? .supported : .unsupported,
                                detail: "Videos can use the system's full-screen player."))
        let pip = raw["pip"] as? [String: Any] ?? [:]
        out.append(MediaFeature(id: "pip", title: "Picture in Picture", status: flag(pip["webkit"]) || flag(pip["standard"]) ? .supported : .unsupported,
                                detail: "A playing video can float above other windows, where the website allows it."))
        let airplay = raw["airplay"] as? [String: Any] ?? [:]
        out.append(MediaFeature(id: "airplay", title: "AirPlay", status: flag(airplay["picker"]) || flag(airplay["event"]) ? .supported : .unsupported,
                                detail: "Video can be sent to an Apple TV or AirPlay speaker, where the website allows it."))
        out.append(MediaFeature(id: "output", title: "Screen capture and mirroring", status: output.blocksProtectedVideo ? .partial : .supported, detail: output.summary))
        return MediaCapabilityReport(features: out)
    }
}

/// What a page's own video said about itself, and what that most likely means.
struct MediaPageFinding: Identifiable, Equatable {
    var id = UUID()
    var element: String
    var source: String
    var headline: String
    var explanation: String
    var isProblem: Bool
}

enum MediaProblemExplainer {
    /// A plain explanation for a media element's state. `errorCode` is the standard media error (1 aborted, 2 network, 3 decode,
    /// 4 source not supported); `readyState` 0 means nothing is loaded.
    static func explain(errorCode: Int?, errorMessage: String?, hasMediaKeys: Bool, isBlob: Bool, readyState: Int, networkState: Int,
                        fairplayAvailable: Bool, output: ProtectedOutput) -> (headline: String, explanation: String, isProblem: Bool) {
        let message = (errorMessage ?? "").lowercased()
        let drmHint = hasMediaKeys || message.contains("key") || message.contains("drm") || message.contains("license") || message.contains("fps")
        if let code = errorCode {
            if drmHint || (code == 4 && isBlob) {
                if output.blocksProtectedVideo {
                    return ("Blocked while the screen is being shared", "This video is copy-protected, and protected video is refused while the screen is recorded, shared or mirrored. Stop the recording or mirroring and reload.", true)
                }
                if !fairplayAvailable {
                    return ("This video needs a kind of copy protection that is not available here", "The service protects this video with DRM that this browser engine cannot provide (FairPlay is not available, and Widevine and PlayReady are not offered by WebKit). Use the service's own app, or try a service that supports FairPlay.", true)
                }
                return ("The copy protection check failed", "The service could not confirm a licence for this video. This can happen when you are signed out, your plan does not include it, the connection dropped, or the display does not meet the service's copy-protection rules. Sign in again, reload, and try without an external display.", true)
            }
            switch code {
            case 1: return ("Playback was stopped", "The video was cancelled before it finished loading, often because the page navigated away or paused it. Reload to try again.", true)
            case 2: return ("The network interrupted the video", "The video file could not be fetched. Check your connection, and whether a content blocker or the site itself is refusing it. Reload to try again.", true)
            case 3: return ("This device could not decode the video", "The file is damaged or uses a format this device cannot decode. Another quality or another site's copy may play.", true)
            case 4: return ("This video format is not supported", "The address does not point to a video this browser can play, or its format (codec) is not supported here. See Media Compatibility for the formats this device can play.", true)
            default: return ("The video reported an error", errorMessage ?? "No details were given.", true)
            }
        }
        if readyState == 0 && networkState == 3 { return ("No video source", "The player has nothing to play: the address is missing or could not be found.", true) }
        if readyState == 0 { return ("Waiting for the video to load", "Nothing has loaded yet. If it stays like this, reload the page.", false) }
        return ("Playing normally", "No problem was reported by this player.", false)
    }
}

extension BrowserModel {
    /// Asks WebKit what this device can play and builds the report.
    func checkMediaCompatibility() async {
        mediaChecking = true
        defer { mediaChecking = false }
        let output = ProtectedOutput.current()
        guard let raw = await active?.engine.probeMediaCapabilities() else {
            mediaReport = MediaCapabilityReport(features: [MediaFeature(id: "probe", title: "Check", status: .unknown, detail: "Open a page first, then check again.")] )
            return
        }
        mediaReport = MediaCapabilityReport.build(from: raw, output: output)
    }

    /// Looks at the videos on the page in front and says, for each, what state it is in and why it might not play.
    func diagnoseMediaOnPage() async {
        guard let tab = active, !tab.isBlank else { return }
        mediaChecking = true
        defer { mediaChecking = false }
        let output = ProtectedOutput.current()
        let fairplay = mediaReport?.features.first { $0.id == "fairplay" }?.status == .supported
        guard let elements = await tab.engine.mediaElements() else { mediaFindings = []; return }
        mediaFindings = elements.map { item in
            let e = MediaProblemExplainer.explain(errorCode: (item["errorCode"] as? NSNumber)?.intValue, errorMessage: item["errorMessage"] as? String,
                                                  hasMediaKeys: (item["hasMediaKeys"] as? NSNumber)?.boolValue ?? false, isBlob: (item["blob"] as? NSNumber)?.boolValue ?? false,
                                                  readyState: (item["readyState"] as? NSNumber)?.intValue ?? 0, networkState: (item["networkState"] as? NSNumber)?.intValue ?? 0,
                                                  fairplayAvailable: fairplay, output: output)
            return MediaPageFinding(element: (item["tag"] as? String) ?? "video", source: displayHostOrBlob(item["src"] as? String),
                                    headline: e.headline, explanation: e.explanation, isProblem: e.isProblem)
        }
    }

    private func displayHostOrBlob(_ source: String?) -> String {
        guard let source, !source.isEmpty else { return "no address" }
        if source.hasPrefix("blob:") { return "streamed by the page" }
        return displayHost(URL(string: source))
    }
}

/// Settings and Library: what this device can play, and why this page's video might not.
struct MediaCompatibilitySection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            Section {
                if let report = model.mediaReport {
                    ForEach(report.features) { feature in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(feature.status)).foregroundStyle(color(feature.status)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title).fontWeight(.medium)
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Check what this device can play: protected video, streaming formats, video hardware, full screen, Picture in Picture and AirPlay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.mediaReport == nil ? "Check This Device" : "Check Again") { Task { await model.checkMediaCompatibility() } }
                        .disabled(model.mediaChecking)
                    if model.mediaChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let report = model.mediaReport { Button("Copy Report") { copyToPasteboard(report.plainText) } }
                }
            } header: { Text("This Device") }
            Section {
                Button("Check the Video on This Page") { Task { if model.mediaReport == nil { await model.checkMediaCompatibility() }; await model.diagnoseMediaOnPage() } }
                    .disabled(model.active?.isBlank ?? true)
                if let findings = model.mediaFindings {
                    if findings.isEmpty { Label("No video or audio player was found on this page.", systemImage: "play.slash").foregroundStyle(.secondary) }
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(finding.headline, systemImage: finding.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(finding.isProblem ? Color.orange : Color.green).fontWeight(.medium)
                            Text(finding.explanation).font(.callout)
                            Text("\(finding.element) · \(finding.source)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("This Page") } footer: {
                Text("Nothing is sent anywhere. The check asks the page's own player what state it is in.")
            }
        }
        .accessibilityIdentifier("media-compatibility")
    }

    private func symbol(_ s: MediaFeature.Status) -> String {
        switch s { case .supported: "checkmark.circle.fill"; case .partial: "exclamationmark.circle.fill"; case .unsupported: "xmark.circle.fill"; case .unknown: "questionmark.circle" }
    }
    private func color(_ s: MediaFeature.Status) -> Color {
        switch s { case .supported: .green; case .partial: .orange; case .unsupported: .red; case .unknown: .secondary }
    }
}
