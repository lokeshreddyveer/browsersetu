import Foundation
import WebKit

/// Whether this launch is a Debug UI-test run (a throwaway `-UITestRoot`). A test run must leave the person's own Browser Setu untouched: its profile folder, preferences and web data. The profile is already
/// a throwaway folder; this is the one switch the rest of the app asks before it writes anything outside that folder (the standard preferences, a window position, bookkeeping that is cached for next time).
enum TestIsolation {
    static var isUITestRun: Bool {
        #if DEBUG
        guard let root = UserDefaults.standard.string(forKey: "UITestRoot") else { return false }
        return !root.isEmpty
        #else
        return false
        #endif
    }

    /// Whether this process is a test process by its real environment (XCTest started it, or it was given a throwaway `-UITestRoot`). Always false in a Release build, so production behavior cannot change.
    static var isTestProcess: Bool {
        #if DEBUG && os(macOS)
        return homeDecision(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments, realHome: realHome, relocatedHome: "") != .notATestProcess
        #else
        return false
        #endif
    }

    /// Where the content-rule installer may remember its recent lists: `nil` in any test process (UI-test launch or XCTest host), the person's standard preferences otherwise. Release builds are never test processes.
    /// The installer keeps an explicit `nil` as "remember for this run only"; it never falls back to the standard preferences.
    static var contentRuleDefaults: UserDefaults? { (isUITestRun || isTestProcess) ? nil : .standard }

    /// `nil` means WebKit's own store (production, unchanged). A test process gets a private store in a throwaway folder, because the default one is the person's `~/Library/WebKit` data; if that
    /// folder cannot be made the process stops, rather than fall back to the default store.
    static func contentRuleStore() -> WKContentRuleListStore? {
        guard isUITestRun || isTestProcess else { return nil }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-test-rule-store-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else {
            fatalError("TestIsolation: cannot make a private content-rule store for a test process; refusing to use the person's own")
        }
        return store
    }

    // MARK: Relocating a test process's home (Debug only)

    /// What a process should do about its home folder, decided from its environment alone (so it can be tested with made-up paths, never the real ones).
    enum HomeDecision: Equatable {
        /// Not a test process: nothing changes (the installed app, a normal launch).
        case notATestProcess
        /// A test process whose home is already somewhere other than the person's own.
        case alreadyRelocated
        /// A test process still pointing at the person's own home: restart it with this one.
        case relocate(to: String)
    }

    /// A process is a test process when XCTest started it (an app-hosted unit-test run) or it was given a throwaway profile (`-UITestRoot`, a UI-test launch). WebKit keeps its web data under the home
    /// folder, so a test process that kept the person's home would read and write the person's own browsing data.
    static func homeDecision(environment: [String: String], arguments: [String], realHome: String, relocatedHome: String) -> HomeDecision {
        let underXCTest = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        var rootGiven = false
        if let i = arguments.firstIndex(of: "-UITestRoot"), arguments.indices.contains(i + 1), !arguments[i + 1].isEmpty { rootGiven = true }
        guard underXCTest || rootGiven else { return .notATestProcess }
        let current = environment["CFFIXED_USER_HOME"].map { ($0 as NSString).standardizingPath } ?? ""
        if !current.isEmpty, current != (realHome as NSString).standardizingPath { return .alreadyRelocated }
        return .relocate(to: relocatedHome)
    }

    #if DEBUG && os(macOS)
    /// The person's own home as the system records it (not what the environment says). `BS_REAL_HOME_FOR_TESTS` stands in for it so the guard itself can be checked with a made-up "real" home.
    static var realHome: String {
        if let override = ProcessInfo.processInfo.environment["BS_REAL_HOME_FOR_TESTS"], !override.isEmpty { return override }
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Run first thing in a Debug build, before WebKit or any store is touched: a test process that still has the person's home is restarted (same process id, so the test runner stays attached) with a
    /// throwaway one. Nothing in a test path can opt out of this; if the restart fails the process stops rather than carry on with the person's data.
    static func relocateHomeIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let target = (NSTemporaryDirectory() as NSString).appendingPathComponent("bs-test-home-\(getuid())")
        switch homeDecision(environment: environment, arguments: CommandLine.arguments, realHome: realHome, relocatedHome: target) {
        case .notATestProcess, .alreadyRelocated:
            return
        case .relocate(let home):
            for sub in ["Library/Preferences", "Library/Caches", "Library/WebKit", "Library/Application Support"] {
                try? FileManager.default.createDirectory(atPath: (home as NSString).appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            setenv("CFFIXED_USER_HOME", home, 1)
            FileHandle.standardError.write(Data("TestIsolation: a test process had the person's own home; restarting it with \(home)\n".utf8))
            guard let executable = Bundle.main.executablePath else { fatalError("TestIsolation: cannot find the executable to restart with a relocated home") }
            var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.enumerated().map { strdup($0.offset == 0 ? executable : $0.element) }
            arguments.append(nil)
            execv(executable, arguments)
            fatalError("TestIsolation: could not restart with a relocated home (errno \(errno)); refusing to run a test against the person's own data")
        }
    }
    #endif
}
