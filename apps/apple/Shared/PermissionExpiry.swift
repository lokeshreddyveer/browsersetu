import Foundation

/// How long a saved "Always Allow" for the camera, microphone or location lasts before the site has to ask again.
enum PermissionExpiry: String, CaseIterable, Identifiable {
    case off, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Never"
        case .day: "After a day"
        case .week: "After a week"
        case .month: "After 30 days"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }
}

extension BrowserModel {
    private static let expiring: [PermissionType] = [.camera, .microphone, .location]

    private func permissionKey(_ origin: String, _ kind: PermissionType) -> String { "\(origin)|\(kind)" }

    /// Remembers when access was given, so it can lapse later.
    func notePermissionGranted(origin: String, kinds: [PermissionType], now: Date = Date()) {
        var dates = permissionDates
        for kind in kinds where Self.expiring.contains(kind) { dates[permissionKey(origin, kind)] = now.timeIntervalSince1970 }
        setPermissionDates(dates)
    }

    /// Turns saved "Allow" decisions older than the chosen time back into "Ask". Access given before this existed starts counting from now.
    /// Returns how many were turned back.
    @discardableResult
    func expirePermissions(now: Date = Date()) -> Int {
        guard let limit = permissionExpiry.seconds, let grants = try? core.listPermissions() else { return 0 }
        var dates = permissionDates
        var expired = 0
        for grant in grants where grant.decision == .allow && Self.expiring.contains(grant.kind) {
            let key = permissionKey(grant.origin, grant.kind)
            guard let given = dates[key] else { dates[key] = now.timeIntervalSince1970; continue }
            if now.timeIntervalSince1970 - given > limit {
                try? core.rememberPermission(origin: grant.origin, kind: grant.kind, decision: .prompt)
                dates.removeValue(forKey: key)
                expired += 1
            }
        }
        setPermissionDates(dates)
        return expired
    }
}
