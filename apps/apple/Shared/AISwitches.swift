import SwiftUI

/// The two switches for everything AI-related, kept for the whole app (not per profile), so one switch really turns it all off.
///
/// `aiEnabled` is the master: off, the on-device page summaries and "Ask This Page" are unavailable and the AI-tool connection (Mac) is closed.
/// `toolsOn` is the separate, off-by-default permission for outside AI tools (Claude, Gemini, Codex and others) to use shared tabs.
@MainActor
final class AISwitches: ObservableObject {
    static let shared = AISwitches()
    static let masterKey = "AIFeaturesOn"
    static let toolsKey = "AIToolsOn"

    @Published var aiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiEnabled, forKey: Self.masterKey)
            #if os(macOS) && DIRECT_BUILD
            AgentBridge.shared.sync()
            #endif
        }
    }

    @Published var toolsOn: Bool {
        didSet {
            UserDefaults.standard.set(toolsOn, forKey: Self.toolsKey)
            #if os(macOS) && DIRECT_BUILD
            AgentBridge.shared.sync()
            #endif
        }
    }

    private init() {
        aiEnabled = UserDefaults.standard.object(forKey: Self.masterKey) as? Bool ?? true
        toolsOn = UserDefaults.standard.bool(forKey: Self.toolsKey)
    }

    /// Whether an outside AI tool may be connected right now.
    var toolsActive: Bool { aiEnabled && toolsOn }

    static let offMessage = "AI features are turned off in Settings."
}
