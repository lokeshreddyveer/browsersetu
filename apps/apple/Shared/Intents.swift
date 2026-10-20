import AppIntents
import Foundation

/// Where an action from Shortcuts waits until the browser is ready for it.
@MainActor
enum IntentInbox {
    private static var pending: [URLAction] = []
    private static var handler: ((URLAction) -> Void)?

    static func attach(_ handle: @escaping (URLAction) -> Void) {
        handler = handle
        let waiting = pending; pending = []
        waiting.forEach(handle)
    }

    static func send(_ action: URLAction) {
        if let handler { handler(action) } else { pending.append(action) }
    }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Page"
    static let description = IntentDescription("Opens a web address in Browser Setu.")
    static let openAppWhenRun = true

    @Parameter(title: "Address") var address: URL
    @Parameter(title: "In a private tab", default: false) var isPrivate: Bool

    @MainActor func perform() async throws -> some IntentResult {
        guard let action = URLAction.parse(URL(string: "browsersetu://open?url=\(address.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&private=\(isPrivate ? 1 : 0)")!) else {
            throw $address.needsValueError("Use a web address that starts with http or https.")
        }
        IntentInbox.send(action)
        return .result()
    }
}

struct SearchWebIntent: AppIntent {
    static let title: LocalizedStringResource = "Search the Web"
    static let openAppWhenRun = true

    @Parameter(title: "Search for") var text: String

    @MainActor func perform() async throws -> some IntentResult {
        IntentInbox.send(.search(String(text.prefix(500))))
        return .result()
    }
}

struct RunWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Workflow"
    static let description = IntentDescription("Runs one of your Browser Setu workflows by name.")
    static let openAppWhenRun = true

    @Parameter(title: "Workflow name") var name: String

    @MainActor func perform() async throws -> some IntentResult {
        IntentInbox.send(.workflow(name))
        return .result()
    }
}

struct ReopenLastSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Reopen My Last Session"
    static let description = IntentDescription("Opens again the pages from your most recent saved checkpoint.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        IntentInbox.send(.command("restore-last-session"))
        return .result()
    }
}

struct BrowserSetuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenPageIntent(), phrases: ["Open a page in \(.applicationName)"], shortTitle: "Open a Page", systemImageName: "safari")
        AppShortcut(intent: SearchWebIntent(), phrases: ["Search the web in \(.applicationName)"], shortTitle: "Search the Web", systemImageName: "magnifyingglass")
        AppShortcut(intent: ReopenLastSessionIntent(), phrases: ["Reopen my last session in \(.applicationName)"], shortTitle: "Reopen Last Session", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: RunWorkflowIntent(), phrases: ["Run a workflow in \(.applicationName)"], shortTitle: "Run a Workflow", systemImageName: "list.bullet.rectangle")
    }
}
