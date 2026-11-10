import AVFoundation
import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
import CoreMotion
#endif

// An optional animated wallpaper: a short loop from this device, played muted, over the picture that stays as its poster frame. It costs power and memory, so it is
// off until chosen and it stops by itself: in Low Power Mode, with Reduce Motion on, when the window is in the background, when the start page is not on screen, and in
// private tabs. Every start page shares ONE player (several windows or tabs never start several decoders). Nothing is played through a web view.

/// Whether the app is in front and one of its windows can be seen. SwiftUI's own scene phase stays "active" on the Mac while another app is in front, so every
/// animation (the drifting gradient, the animated wallpaper) also asks this: it follows the app becoming active or inactive, and windows being covered, minimised or hidden.
/// A reading taken at one instant can be stale (a window that has only just been ordered in is not yet "visible"), so every change is read twice: at once, and again a moment later.
@MainActor
final class AppActivity: ObservableObject {
    static let shared = AppActivity()

    @Published private(set) var isActive = true
    private var tokens: [NSObjectProtocol] = []

    private init() {
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                          NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.didResignKeyNotification, NSWindow.didExposeNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        #else
        let names: [Notification.Name] = [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                                          UIApplication.willEnterForegroundNotification]
        #endif
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheck() }
            })
        }
        isActive = Self.compute()
        #if DEBUG
        // Development only: a line every two seconds with what the player is really doing, for checking behaviour without relying on CPU figures.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { WallpaperDebug.snapshot() } }
        RunLoop.main.add(timer, forMode: .common)
        #endif
    }

    /// Reads now, and once more shortly after.
    func recheck() {
        refresh(reason: "change")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refresh(reason: "settled")
        }
    }

    private var pending: Task<Void, Never>?

    /// A change of state only counts once it has held for a quarter of a second: the app and its windows flicker through states while they are being shown, hidden or
    /// brought to the front (four flips in 200 ms were seen at launch, and each one built and dropped a video player).
    private func refresh(reason: String) {
        pending?.cancel()
        pending = nil
        guard Self.compute() != isActive else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let confirmed = Self.compute()
            self.pending = nil
            guard confirmed != self.isActive else { return }
            self.isActive = confirmed
            #if DEBUG
            WallpaperDebug.log("activity \(confirmed ? "ACTIVE" : "INACTIVE") (\(reason))")
            #endif
        }
    }

    private static func compute() -> Bool {
        #if os(macOS)
        NSApp.isActive && !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }
}

#if DEBUG
/// Development only: what the shared player is doing, written to a file in the app's temporary folder.
@MainActor
enum WallpaperDebug {
    static let path = NSTemporaryDirectory() + "wallpaper-debug.log"
    static func log(_ text: String) {
        let line = "\(String(format: "%.2f", Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))) \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
    }
    /// Start pages on screen right now (counted by the pages themselves).
    static var visibleStartPages = 0
    static func snapshot() { log("snapshot active=\(AppActivity.shared.isActive) visiblePages=\(visibleStartPages) \(WallpaperPlayer.shared.debugState) | images \(WallpaperImages.debugState)") }
}
#endif

/// The one muted, looping player. Started by the first start page that needs it, stopped when the last one goes.
@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var users = 0
    /// How many players have ever been made (a test that two start pages share one asks for this).
    private(set) var playersMade = 0
    /// Which file, and which version of it: replacing the loop keeps the same path, so the version is what tells a new video from the one already loaded.
    private var loaded: String?

    /// How many start pages are showing the video right now (tests).
    var consumers: Int { users }

    var debugState: String { "users=\(users) player=\(player != nil) rate=\(player?.rate ?? -1) items=\(player?.items().count ?? 0) made=\(playersMade) loaded=\(loaded ?? "-")" }

    /// What identifies the video that is loaded: the file itself (its place, when it last changed and its size). Not a counter kept by a window's own model: every window has
    /// a model of its own, and their counters disagree, which made each window look like it wanted a different video and rebuilt the one shared player every time.
    static func identity(of url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let changed = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return "\(url.path)@\(changed)#\(size)"
    }

    func attach(_ url: URL) {
        users += 1
        releaseTask?.cancel(); releaseTask = nil
        let key = Self.identity(of: url)
        if player == nil || loaded != key { start(url, key: key) }
        player?.play()
        #if DEBUG
        WallpaperDebug.log("attach \(debugState)")
        #endif
    }

    func detach() {
        users = max(0, users - 1)
        if users == 0 {
            // Stopped at once, released after a moment: a quick switch between tabs (or a flicker of the window's state) finds the same player still there.
            player?.pause()
            releaseTask?.cancel()
            releaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.users == 0 else { return }
                self.stop()
                #if DEBUG
                WallpaperDebug.log("released \(self.debugState)")
                #endif
            }
        }
        #if DEBUG
        WallpaperDebug.log("detach \(debugState)")
        #endif
    }

    private var releaseTask: Task<Void, Never>?

    private func start(_ url: URL, key: String) {
        stop()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.allowsExternalPlayback = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        loaded = key
        playersMade += 1
    }

    private func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        loaded = nil
    }
}

/// The video, filling its space. It attaches to the shared player when it appears and lets go when it goes.
struct AnimatedWallpaperLayer: View {
    @EnvironmentObject var model: BrowserModel
    @State private var player: AVPlayer?

    var body: some View {
        PlayerLayerHost(player: player)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                WallpaperPlayer.shared.attach(model.startVideoURL)
                player = WallpaperPlayer.shared.player
            }
            .onDisappear {
                player = nil
                WallpaperPlayer.shared.detach()
            }
            // A new loop (or none) rebuilds this layer: the old one lets go and the new one attaches.
            .id(model.startVideoVersion)
    }
}

#if os(macOS)
private struct PlayerLayerHost: NSViewRepresentable {
    let player: AVPlayer?

    final class Host: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); playerLayer.frame = bounds }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) { view.playerLayer.player = player }
}
#else
private struct PlayerLayerHost: UIViewRepresentable {
    let player: AVPlayer?

    final class Host: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Host, context: Context) { view.playerLayer.player = player }
}
#endif

/// Whether an animated wallpaper may play now. Pure, so every rule is tested in one place.
enum AnimatedWallpaperRules {
    static func mayPlay(switchedOn: Bool, hasVideo: Bool, isPrivate: Bool, reduceMotion: Bool, lowPower: Bool, windowActive: Bool, onScreen: Bool) -> Bool {
        switchedOn && hasVideo && !isPrivate && !reduceMotion && !lowPower && windowActive && onScreen
    }

    static let longestLoop = 60.0
    static let largestFile = 200_000_000
    static let largestSide = 4096.0
}

@MainActor
extension BrowserModel {
    var startVideoURL: URL { themeFolder.appendingPathComponent("start.mov") }

    /// Keeps a short loop from this device. It is checked first (a video track, at most a minute, 200 MB and 4096 points on a side); its first moments become the
    /// still picture, so there is always something to show when it is not playing.
    func setStartVideo(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > AnimatedWallpaperRules.largestFile { notice = "That video is too large (over 200 MB)."; return }
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
              let duration = try? await asset.load(.duration), let natural = try? await track.load(.naturalSize) else { notice = "That video could not be used."; return }
        guard duration.seconds > 0, duration.seconds <= AnimatedWallpaperRules.longestLoop else { notice = "Choose a loop of up to a minute."; return }
        guard max(natural.width, natural.height) <= AnimatedWallpaperRules.largestSide else { notice = "That video is larger than 4096 points on a side."; return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(WallpaperImages.longestSide), height: CGFloat(WallpaperImages.longestSide))
        guard let frame = try? await generator.image(at: CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)).image,
              let poster = Self.jpeg(frame), let prepared = WallpaperImages.prepared(poster) else { notice = "That video could not be used."; return }
        try? FileManager.default.createDirectory(at: themeFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: startVideoURL)
        do { try FileManager.default.copyItem(at: url, to: startVideoURL) } catch { notice = "The video could not be saved."; return }
        guard (try? prepared.write(to: startImageURL, options: .atomic)) != nil else { notice = "The picture could not be saved."; return }
        WallpaperImages.clear()
        startImageData = prepared
        currentWallpaperID = nil
        analyzeStartImage()
        startVideoVersion += 1
        startHasVideo = true
        startVideoOn = true
        startBackground = .image
    }

    func removeStartVideo() {
        try? FileManager.default.removeItem(at: startVideoURL)
        startVideoVersion += 1
        startHasVideo = false
        startVideoOn = false
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

#if os(iOS)
/// Device tilt for the optional motion effect: 20 readings a second at most, smoothed, only while the start page is on screen and only when asked for.
@MainActor
final class StartMotion {
    private let manager = CMMotionManager()
    private var smoothed = CGSize.zero

    func start(into pointer: StartPointer) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self, weak pointer] motion, _ in
            guard let self, let pointer, let attitude = motion?.attitude else { return }
            // Roll and pitch in radians, about a quarter turn either way for the full range; a light smoothing so it never jitters.
            let target = CGSize(width: min(max(attitude.roll / 1.2, -0.5), 0.5), height: min(max((attitude.pitch - 0.7) / 1.2, -0.5), 0.5))
            self.smoothed = CGSize(width: self.smoothed.width * 0.85 + target.width * 0.15, height: self.smoothed.height * 0.85 + target.height * 0.15)
            pointer.tilt = self.smoothed
        }
    }

    func stop(from pointer: StartPointer) {
        manager.stopDeviceMotionUpdates()
        smoothed = .zero
        pointer.tilt = nil
    }
}
#endif
