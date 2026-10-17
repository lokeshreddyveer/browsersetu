import Foundation

// MARK: - The merge
//
// Every synced thing (a bookmark, a setting, a workspace, a saved password) is one "cell": a value, or a tombstone meaning "deleted", with a stamp saying when it
// last changed and on which device. Two copies of a cell are combined by keeping the one with the later stamp (ties broken by device id), so any number of devices,
// syncing in any order, any number of times, end up with identical contents. A snapshot that arrives late, twice or out of order cannot undo a newer change.

struct SyncStamp: Codable, Hashable, Comparable {
    var time: Double
    var device: String
    static func < (a: SyncStamp, b: SyncStamp) -> Bool { a.time != b.time ? a.time < b.time : a.device < b.device }
}

struct SyncCell<Value: Codable & Equatable>: Codable, Equatable {
    var stamp: SyncStamp
    /// nil means deleted.
    var value: Value?
}

/// A clock that never goes backwards and never hands out a stamp lower than one it has seen, so a device with a slow clock cannot lose to older changes by accident.
struct SyncClock: Codable, Equatable {
    var highest: Double = 0
    mutating func stamp(now: Date, device: String) -> SyncStamp {
        let t = max(now.timeIntervalSince1970, highest + 0.001)
        highest = t
        return SyncStamp(time: t, device: device)
    }
    mutating func observe(_ stamp: SyncStamp) { highest = max(highest, stamp.time) }
}

struct SyncBookmark: Codable, Equatable { var title: String; var folder: String }
struct SyncWorkspace: Codable, Equatable { var icon: String; var preset: String?; var accent: String? }
struct SyncLogin: Codable, Equatable { var origin: String; var user: String; var password: String }

/// Everything that is kept in step between devices.
struct SyncState: Codable, Equatable {
    var bookmarks: [String: SyncCell<SyncBookmark>] = [:]       // by address
    var settings: [String: SyncCell<String>] = [:]              // by setting name
    var workspaces: [String: SyncCell<SyncWorkspace>] = [:]     // by name
    var logins: [String: SyncCell<SyncLogin>] = [:]             // by origin and user; only when the person turned password sync on
    var sessions: [String: SyncCell<SavedSession>] = [:]        // by session id

    init(bookmarks: [String: SyncCell<SyncBookmark>] = [:], settings: [String: SyncCell<String>] = [:], workspaces: [String: SyncCell<SyncWorkspace>] = [:],
         logins: [String: SyncCell<SyncLogin>] = [:], sessions: [String: SyncCell<SavedSession>] = [:]) {
        self.bookmarks = bookmarks; self.settings = settings; self.workspaces = workspaces; self.logins = logins; self.sessions = sessions
    }

    /// Older snapshots have no sessions; they still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookmarks = try c.decodeIfPresent([String: SyncCell<SyncBookmark>].self, forKey: .bookmarks) ?? [:]
        settings = try c.decodeIfPresent([String: SyncCell<String>].self, forKey: .settings) ?? [:]
        workspaces = try c.decodeIfPresent([String: SyncCell<SyncWorkspace>].self, forKey: .workspaces) ?? [:]
        logins = try c.decodeIfPresent([String: SyncCell<SyncLogin>].self, forKey: .logins) ?? [:]
        sessions = try c.decodeIfPresent([String: SyncCell<SavedSession>].self, forKey: .sessions) ?? [:]
    }

    static let tombstoneLifetime: Double = 90 * 24 * 3600
    static let maxCells = 12_000
}

enum SyncMerge {
    static func merge<V>(_ a: [String: SyncCell<V>], _ b: [String: SyncCell<V>]) -> [String: SyncCell<V>] {
        var out = a
        for (key, theirs) in b {
            if let mine = out[key] { if theirs.stamp > mine.stamp { out[key] = theirs } } else { out[key] = theirs }
        }
        return out
    }

    static func merge(_ a: SyncState, _ b: SyncState) -> SyncState {
        SyncState(bookmarks: merge(a.bookmarks, b.bookmarks), settings: merge(a.settings, b.settings), workspaces: merge(a.workspaces, b.workspaces), logins: merge(a.logins, b.logins), sessions: merge(a.sessions, b.sessions))
    }

    /// Notes what changed on this device since the last time: a new or different value gets a fresh stamp, and a value that has disappeared becomes a tombstone.
    static func observe<V>(ledger: inout [String: SyncCell<V>], current: [String: V], clock: inout SyncClock, device: String, now: Date) {
        for (key, value) in current where ledger[key]?.value != value { ledger[key] = SyncCell(stamp: clock.stamp(now: now, device: device), value: value) }
        for (key, cell) in ledger where cell.value != nil && current[key] == nil { ledger[key] = SyncCell(stamp: clock.stamp(now: now, device: device), value: nil) }
    }

    /// What the merged state asks this device to do to its own data.
    struct Plan<V: Equatable>: Equatable {
        var upsert: [String: V] = [:]
        var delete: [String] = []
        var isEmpty: Bool { upsert.isEmpty && delete.isEmpty }
    }

    static func plan<V: Equatable>(merged: [String: SyncCell<V>], current: [String: V]) -> Plan<V> {
        var plan = Plan<V>()
        for (key, cell) in merged {
            if let value = cell.value { if current[key] != value { plan.upsert[key] = value } }
            else if current[key] != nil { plan.delete.append(key) }
        }
        plan.delete.sort()
        return plan
    }

    /// Old tombstones are dropped, and when there are too many cells the oldest tombstones go first. A device that was off for longer than the lifetime could bring a deleted item back.
    static func pruned(_ state: SyncState, now: Date) -> SyncState {
        func prune<V>(_ cells: [String: SyncCell<V>]) -> [String: SyncCell<V>] { cells.filter { $0.value.value != nil || now.timeIntervalSince1970 - $0.value.stamp.time < SyncState.tombstoneLifetime } }
        return SyncState(bookmarks: prune(state.bookmarks), settings: prune(state.settings), workspaces: prune(state.workspaces), logins: prune(state.logins), sessions: prune(state.sessions))
    }

    static func highestStamp(in state: SyncState) -> Double {
        var top = 0.0
        for c in state.bookmarks.values { top = max(top, c.stamp.time) }
        for c in state.settings.values { top = max(top, c.stamp.time) }
        for c in state.workspaces.values { top = max(top, c.stamp.time) }
        for c in state.logins.values { top = max(top, c.stamp.time) }
        for c in state.sessions.values { top = max(top, c.stamp.time) }
        return top
    }
}
