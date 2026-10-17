import Foundation
import SetuPrivacyCore
import WebKit

struct HealthItem: Identifiable, Equatable {
    enum Status { case ok, warning, failed }
    let name: String
    let status: Status
    let detail: String
    var id: String { name }

    var symbol: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

/// A local check of the parts the browser depends on. It reads state and writes one probe setting; nothing is sent
/// anywhere and no browsing data is looked at.
@MainActor
enum HealthCheck {
    static func run(model: BrowserModel) async -> [HealthItem] {
        var items: [HealthItem] = []

        // Storage
        if model.recovery != nil {
            items.append(HealthItem(name: "Profile database", status: .failed,
                                    detail: "The profile database could not be opened normally and is in recovery."))
        } else {
            let probe = "ok-\(UInt32.random(in: 0...UInt32.max))"
            let wrote = (try? model.core.setSetting(key: "health_probe", value: probe)) != nil
            let read = (try? model.core.getSetting(key: "health_probe")) ?? nil
            items.append(wrote && read == probe
                         ? HealthItem(name: "Profile database", status: .ok, detail: "Readable and writable.")
                         : HealthItem(name: "Profile database", status: .failed, detail: "A test write could not be read back."))
        }

        // Engine
        let webKit = Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleShortVersionString"] as? String
        items.append(HealthItem(name: "Web engine", status: .ok, detail: "\(model.engine.name)\(webKit.map { " \($0)" } ?? "")."))

        if let engine = model.engine as? WebKitEngine {
            let stores = await WebKitEngine.existingDataStoreIDs()
            let expected = ProfileIdentity.dataStoreID(for: model.profileName)
            items.append(stores.contains(expected)
                         ? HealthItem(name: "Website data store", status: .ok, detail: "The profile’s own cookie and storage area exists.")
                         : HealthItem(name: "Website data store", status: .warning, detail: "Created the first time a page is loaded."))
            _ = engine
        }

        // Privacy
        let state = model.privacy.state(forHost: nil)
        items.append(HealthItem(name: "Ad and tracker protection",
                                status: state == .active ? .ok : (state == .disabled ? .warning : .warning),
                                detail: state.detail ?? state.statusWord))
        items.append(HealthItem(name: "Link cleaning", status: model.stripTrackingParameters ? .ok : .warning,
                                detail: model.stripTrackingParameters ? "Tracking parameters are removed from links." : "Turned off."))
        items.append(HealthItem(name: "Threat list", status: model.threatList.isEmpty ? .warning : .ok,
                                detail: model.threatList.isEmpty ? "No list imported. Pages are checked only by WebKit’s own warning."
                                                                 : "\(model.threatList.count) hosts loaded from your file."))

        // Isolation and sandbox
        #if os(macOS)
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        items.append(HealthItem(name: "App Sandbox", status: sandboxed ? .ok : .warning,
                                detail: sandboxed ? "The app runs inside the macOS sandbox." : "Not sandboxed (a debug or test build)."))
        #endif

        // Resources
        let discarded = model.tabs.filter(\.isDiscarded).count
        items.append(HealthItem(name: "Tabs", status: .ok,
                                detail: "\(model.tabs.count) open, \(model.tabs.filter(\.hasLoadedPage).count) loaded, \(discarded) released to save memory."))
        if let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            items.append(HealthItem(name: "Free disk space", status: free < 1_000_000_000 ? .warning : .ok, detail: "\(text) available."))
        }
        return items
    }
}
