import Foundation

/// The one service the app's Downloads window uses for local media jobs. Created the first time it is needed; interrupted work from an earlier run is listed (never restarted) then.
@MainActor
enum MediaProcessingHub {
    static let shared: MediaProcessingService = {
        MediaProcessingService.sweepPrivateTemporaries()
        let service = MediaProcessingService(stagingRoot: MediaProcessingService.defaultStagingRoot(), authorizedRoots: [DownloadCoordinator.directory])
        service.recoverInterrupted()
        return service
    }()
}

/// What the details panel may offer for one finished download.
struct MediaToolsContext: Equatable {
    var file: URL
    var kind: MediaPreviewKind
    var isPrivate: Bool
    var isAudioVideo: Bool { kind == .video || kind == .audio }
}

@MainActor enum MediaToolsAvailability {
    /// The file a completed download left, when it is a plain file inside a folder the app may use and one of the kinds that can be looked at. Nil otherwise (not finished, gone, or outside).
    static func context(path: String?, isCompleted: Bool, isPrivate: Bool, roots: [URL]? = nil) -> MediaToolsContext? {
        let roots = roots ?? [DownloadCoordinator.directory]
        guard isCompleted, let path, DownloadPathPolicy.isAuthorized(path, roots: roots) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let kind = MediaPreviewPolicy.kind(of: url)
        guard kind.isPreviewable else { return nil }
        return MediaToolsContext(file: url, kind: kind, isPrivate: isPrivate)
    }

    /// Why a download that has not finished cannot be previewed (the engines do not state how much of the start of the file is certainly written, so none qualifies).
    static let partialExplanation = "A preview needs the whole file. A download that is still arriving may be written in pieces from several places at once, so it is not certain which part is complete."
}
