import AppKit

/// What the command line asks of the app, acted on as it starts.
///
///     open -n -a "Browser Setu" --args --space Development      # starts a new copy of the app only to hand the request over
///     "/Applications/Browser Setu.app/Contents/MacOS/Browser Setu" --space Development
///     open "browsersetu://space?name=Development"               # the form that reaches an app that is already running
///
/// macOS gives an app's arguments to the copy that starts, never to one already running (`open -a … --args` on a running app only brings it forward). So a copy
/// started with `--space` while the app is running passes the request to the running one as a `browsersetu://space` link, brings it forward, and quits at once.
/// A mistake in the arguments is printed to the terminal when there is one, and otherwise shown in the app.
@MainActor
enum LaunchHandling {
    static func handle(_ arguments: [String] = CommandLine.arguments) {
        switch LaunchArgumentParser.parse(arguments) {
        case .failure(let problem):
            report(problem.message)
        case .success(let requests):
            for request in requests {
                switch request {
                case .space(let query): requestSpace(query)
                }
            }
        }
    }

    private static func requestSpace(_ query: String) {
        if let running = otherRunningCopy(), let url = spaceLink(query) {
            // Passed to the copy that is already open, then this one has nothing left to do.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: running.bundleURL ?? Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async {
                    running.activate()
                    exit(0)
                }
            }
            // If the system never answers, this copy still must not stay open as a second app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
            return
        }
        // The first copy: the request waits until the window is ready for it.
        IntentInbox.send(.space(query))
    }

    private static func spaceLink(_ query: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "browsersetu"
        parts.host = "space"
        parts.queryItems = [URLQueryItem(name: "name", value: query)]
        return parts.url
    }

    private static func otherRunningCopy() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static func report(_ message: String) {
        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data(("Browser Setu: " + message + "\n").utf8))
            exit(64)                         // EX_USAGE
        }
        IntentInbox.send(.report(message))
    }
}
