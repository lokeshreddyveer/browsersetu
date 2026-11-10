import Foundation
import SwiftUI
import UserNotifications

// Native notifications for downloads. They read the one event feed; they do not watch the ledger, and they never make a request of their own: every action goes through the
// coordinator after the task, its profile and its state are checked again.

struct DownloadNotificationPreferences: Codable, Equatable, Sendable {
    enum Delivery: String, Codable, CaseIterable, Sendable { case system, inApp, both
        var title: String { switch self { case .system: "System notifications"; case .inApp: "Inside Browser Setu only"; case .both: "Both" } }
    }
    /// Off until the person turns it on. Turning it on is also when the system is asked for permission.
    var enabled = false
    var completion = true
    var failure = true
    var recoveryRequired = true
    var integrityFailed = true
    var queueCompleted = false
    var scheduledReady = false
    var sounds = false
    var grouping = true
    var delivery = Delivery.system
    /// Stay quiet while the Downloads window is open and Browser Setu is in front: the list already shows it.
    var quietWhileDownloadsVisible = true

    func encoded() -> String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> DownloadNotificationPreferences? { text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
}

enum NotificationPermission: Equatable, Sendable { case notDetermined, denied, allowed }

struct NotificationPayload: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    var category: String
    var thread: String?
    var userInfo: [String: String]
    var sound: Bool
}

/// The system's notification center, as far as this needs it. The real one wraps UNUserNotificationCenter; tests use a fake.
@MainActor
protocol NotificationCenterProviding: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async -> Bool
    func deliver(_ payload: NotificationPayload) async
    func registerCategories()
    func remove(identifiers: [String])
}

@MainActor
final class SystemNotificationCenter: NSObject, NotificationCenterProviding, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { .current() }
    var onAction: ((String, [String: String]) async -> Void)?

    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: .allowed
        case .denied: .denied
        default: .notDetermined
        }
    }
    func requestPermission() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    func deliver(_ p: NotificationPayload) async {
        let content = UNMutableNotificationContent()
        content.title = p.title; content.body = p.body; content.categoryIdentifier = p.category
        if let t = p.thread { content.threadIdentifier = t }
        content.userInfo = p.userInfo
        if p.sound { content.sound = .default }
        try? await center.add(UNNotificationRequest(identifier: p.identifier, content: content, trigger: nil))
    }
    func registerCategories() {
        func act(_ id: String, _ title: String) -> UNNotificationAction { UNNotificationAction(identifier: id, title: title, options: id == "open" ? [.foreground] : []) }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "download.completed", actions: [act("reveal", "Show in Finder"), act("open", "Open Downloads")], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "download.failed", actions: [act("retry", "Try Again"), act("details", "View Details")], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "download.info", actions: [act("open", "Open Downloads")], intentIdentifiers: [], options: []),
        ])
    }
    func remove(identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo { if let k = k as? String, let v = v as? String { info[k] = v } }
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier
        await onAction?(action, info)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

/// What a notification says and whether one is sent at all. Pure: no clock, no system, no ledger.
enum NotificationPlanner {
    struct Facts {
        var filename: String
        var host: String?
        var failure: DownloadFailureCategory?
        var retryable: Bool
    }
    struct Context {
        var prefs: DownloadNotificationPreferences
        var permission: NotificationPermission
        var downloadsVisible: Bool
        var appActive: Bool
    }

    /// nil when nothing should be sent.
    static func plan(_ event: AutomationEvent, facts: Facts?, context: Context) -> NotificationPayload? {
        let p = context.prefs
        guard p.enabled else { return nil }
        let wanted: Bool
        switch event.type {
        case "task.completed": wanted = p.completion
        case "task.failed": wanted = p.failure
        case "task.recovery_required": wanted = p.recoveryRequired
        case "task.integrity_failed": wanted = p.integrityFailed
        case "queue.completed": wanted = p.queueCompleted
        case "task.scheduled_ready": wanted = p.scheduledReady
        default: wanted = false
        }
        guard wanted else { return nil }
        if p.quietWhileDownloadsVisible, context.downloadsVisible, context.appActive { return nil }
        var info = ["profile": event.profile]
        if let t = event.taskID { info["task"] = t }
        let thread = p.grouping ? "downloads.\(event.profile)" : nil
        let name = facts.map { String($0.filename.prefix(80)) } ?? "A download"
        switch event.type {
        case "queue.completed":
            return NotificationPayload(identifier: "queue-\(event.epoch)-\(event.id)", title: "Downloads finished", body: "Everything in the queue is done.", category: "download.info", thread: thread, userInfo: info, sound: p.sounds)
        case "task.completed":
            return NotificationPayload(identifier: "done-\(event.taskID ?? "")", title: "Download finished", body: name, category: "download.completed", thread: thread, userInfo: info, sound: p.sounds)
        case "task.failed":
            let f = facts?.failure ?? .unknown
            return NotificationPayload(identifier: "failed-\(event.taskID ?? "")-\(event.epoch)-\(event.id)", title: "Download failed", body: "\(name) — \(f.title). \(f.advice)", category: (facts?.retryable ?? false) ? "download.failed" : "download.info", thread: thread, userInfo: info, sound: p.sounds)
        case "task.recovery_required":
            return NotificationPayload(identifier: "recovery-\(event.taskID ?? "")-\(event.epoch)-\(event.id)", title: "Download needs attention", body: "\(name) stopped and needs you to decide what to do.", category: "download.info", thread: thread, userInfo: info, sound: p.sounds)
        case "task.integrity_failed":
            return NotificationPayload(identifier: "integrity-\(event.taskID ?? "")", title: "File does not match", body: "\(name) was kept but is not the size expected.", category: "download.info", thread: thread, userInfo: info, sound: p.sounds)
        default:
            return NotificationPayload(identifier: "ready-\(event.taskID ?? "")", title: "Scheduled download started", body: name, category: "download.info", thread: thread, userInfo: info, sound: p.sounds)
        }
    }
}

@MainActor
final class DownloadNotificationService: ObservableObject {
    @Published var preferences = DownloadNotificationPreferences()
    @Published private(set) var permission = NotificationPermission.notDetermined
    @Published private(set) var delivered = 0
    @Published private(set) var lastActionRefusal: String?
    private let center: NotificationCenterProviding
    private let coordinators: () -> [DownloadCoordinator]
    private let downloadsVisible: () -> Bool
    private let appActive: () -> Bool
    private let openDownloads: (UUID?) -> Void
    private let reveal: (URL) -> Void
    private let inApp: (String, String) -> Void
    private var seen: [String] = []
    private var seenSet = Set<String>()
    private var observer: (feed: DownloadEventFeed, id: UUID)?
    static let memory = 500

    init(center: NotificationCenterProviding, coordinators: @escaping () -> [DownloadCoordinator], downloadsVisible: @escaping () -> Bool, appActive: @escaping () -> Bool,
         openDownloads: @escaping (UUID?) -> Void, reveal: @escaping (URL) -> Void, inApp: @escaping (String, String) -> Void = { _, _ in }) {
        self.center = center; self.coordinators = coordinators; self.downloadsVisible = downloadsVisible; self.appActive = appActive
        self.openDownloads = openDownloads; self.reveal = reveal; self.inApp = inApp
    }

    /// Reads events from the shared feed. Safe to call twice; `detach` removes the one observer.
    func attach(to feed: DownloadEventFeed) {
        detach()
        observer = (feed, feed.observe { [weak self] event, coordinator in Task { @MainActor in await self?.handle(event, coordinator: coordinator) } })
    }
    func detach() { if let o = observer { o.feed.unobserve(o.id) }; observer = nil }
    var isAttached: Bool { observer != nil }

    func refreshPermission() async { permission = await center.permission() }

    /// Makes the action buttons known to the system (no permission is asked here).
    func prepare() { center.registerCategories() }

    /// Called when the person turns notifications on (a relevant moment), never at launch.
    func requestPermission() async {
        center.registerCategories()
        _ = await center.requestPermission()
        await refreshPermission()
    }

    private func remember(_ key: String) -> Bool {
        guard !seenSet.contains(key) else { return false }
        seenSet.insert(key); seen.append(key)
        if seen.count > Self.memory { seenSet.remove(seen.removeFirst()) }
        return true
    }

    func handle(_ event: AutomationEvent, coordinator: DownloadCoordinator?) async {
        guard preferences.enabled else { return }
        // A shared feed can carry another profile's events; this service speaks only for the profiles it was given.
        guard coordinators().contains(where: { $0.profileName == event.profile }) else { return }
        permission = await center.permission()
        var facts: NotificationPlanner.Facts?
        if let id = event.taskID.flatMap(UUID.init(uuidString:)), let record = coordinator?.ledger.record(id) {
            guard !record.isPrivate else { return }                    // a private download never produces a notification
            let cat = record.failure.map { DownloadFailureCategory.classify(code: $0.code, reason: $0.reason) }
            facts = .init(filename: DiagnosticRedactor.filename(record.file.filename) ?? "A download", host: record.source.host, failure: cat,
                          retryable: (cat?.retryable ?? false) && (coordinator?.failures.first { $0.id == id }?.canRetry ?? false))
        } else if event.taskID != nil { return }
        let mode = preferences.delivery
        let systemAllowed = permission == .allowed && mode != .inApp
        let ctx = NotificationPlanner.Context(prefs: preferences, permission: systemAllowed ? .allowed : (mode == .inApp ? .allowed : permission), downloadsVisible: downloadsVisible(), appActive: appActive())
        guard let payload = NotificationPlanner.plan(event, facts: facts, context: ctx) else { return }
        // Nothing to show anywhere (system-only and not allowed): not remembered, so it can still be shown if the permission is granted later.
        guard systemAllowed || mode != .system else { return }
        // One notice per task and kind, however many times the feed repeats it. A failure after a retry is a new event and is told again.
        guard remember(payload.identifier) else { return }
        if mode != .system { inApp(payload.title, payload.body) }
        if systemAllowed { await center.deliver(payload); delivered += 1 }
    }

    // MARK: Actions

    enum ActionResult: Equatable { case done, refused(String) }

    /// An action the person chose on a notification. Everything is checked again now: the profile, that the task still exists and is not private, and what state it is in.
    @discardableResult
    func perform(action: String, userInfo: [String: String]) -> ActionResult {
        lastActionRefusal = nil
        func refuse(_ why: String) -> ActionResult { lastActionRefusal = why; return .refused(why) }
        guard let profile = userInfo["profile"], let coordinator = coordinators().first(where: { $0.profileName == profile }) else { return refuse("That download belongs to a profile that is not open.") }
        let id = userInfo["task"].flatMap(UUID.init(uuidString:))
        if action == "open" { openDownloads(nil); return .done }
        guard let id, let record = coordinator.ledger.record(id), !record.isPrivate, record.profile == profile else { return refuse("That download is no longer in the list.") }
        switch action {
        case "details": openDownloads(id); return .done
        case "reveal":
            guard record.state == .completed, let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: [DownloadCoordinator.directory] + DownloadDestinationAccess.grantedRoots),
                  FileManager.default.fileExists(atPath: path) else { return refuse("The file is not there any more.") }
            reveal(URL(fileURLWithPath: path))          // shown in Finder, never opened
            return .done
        case "retry":
            guard let failure = coordinator.failures.first(where: { $0.id == id }), failure.canRetry else { return refuse("This download cannot be tried again from here.") }
            coordinator.retryFailure(id)
            return .done
        default: return refuse("Unknown action.")
        }
    }
}

// MARK: - Settings

struct DownloadNotificationSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { NotificationSettingsContent(service: model.notifications, model: model) }
}

private struct NotificationSettingsContent: View {
    @ObservedObject var service: DownloadNotificationService
    @ObservedObject var model: BrowserModel

    var body: some View {
        Section("Download notifications") {
            Text("Tells you when a download finishes, fails or needs you. Nothing is sent for private downloads. Off until you turn it on; macOS asks your permission then.").settingsNote()
            Toggle("Notify me about downloads", isOn: Binding(
                get: { model.downloadNotifications.enabled },
                set: { on in
                    model.downloadNotifications.enabled = on
                    if on { Task { await service.requestPermission() } }
                }))
            LabeledContent("System permission", value: permissionText)
            if model.downloadNotifications.enabled {
                Toggle("When a download finishes", isOn: $model.downloadNotifications.completion)
                Toggle("When a download fails", isOn: $model.downloadNotifications.failure)
                Toggle("When a download needs attention", isOn: $model.downloadNotifications.recoveryRequired)
                Toggle("When a file does not match its size", isOn: $model.downloadNotifications.integrityFailed)
                Toggle("When the whole queue is finished", isOn: $model.downloadNotifications.queueCompleted)
                Toggle("When a scheduled download starts", isOn: $model.downloadNotifications.scheduledReady)
                Toggle("Play a sound", isOn: $model.downloadNotifications.sounds)
                Toggle("Group by profile", isOn: $model.downloadNotifications.grouping)
                Toggle("Stay quiet while the Downloads window is open", isOn: $model.downloadNotifications.quietWhileDownloadsVisible)
                Picker("Show as", selection: $model.downloadNotifications.delivery) {
                    ForEach(DownloadNotificationPreferences.Delivery.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .task { await service.refreshPermission() }
    }

    private var permissionText: String {
        switch service.permission {
        case .allowed: "Allowed"
        case .denied: "Denied in System Settings › Notifications"
        case .notDetermined: "Not asked yet"
        }
    }
}
