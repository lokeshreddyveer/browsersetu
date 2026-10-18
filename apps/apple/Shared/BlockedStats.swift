import Foundation

/// How many requests were refused over time, an hour at a time, kept on this device in one small file per profile.
/// The numbers are estimates (see `BlockedCounter`): WebKit never says what it blocked.
struct BlockedStats: Codable, Equatable {
    /// Seconds since 1970, rounded down to the hour, mapped to the count in that hour. Hours older than 400 days are folded into `older`.
    private(set) var hours: [Int: Int] = [:]
    private(set) var older = 0
    /// Per site, per day (days since 1970): how many were refused. Kept for 90 days, for the "top sites" list.
    private(set) var siteDays: [Int: [String: Int]] = [:]

    init() {}

    // Files written before the per-site counts existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = try c.decodeIfPresent([Int: Int].self, forKey: .hours) ?? [:]
        older = try c.decodeIfPresent(Int.self, forKey: .older) ?? 0
        siteDays = try c.decodeIfPresent([Int: [String: Int]].self, forKey: .siteDays) ?? [:]
    }

    enum Range: String, CaseIterable, Identifiable {
        case today, day, week, month, year, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .year: "Last 12 months"
            case .all: "All time"
            }
        }
    }

    mutating func add(_ count: Int, host: String? = nil, at date: Date = Date()) {
        guard count > 0 else { return }
        if let host, !host.isEmpty {
            let day = Self.day(of: date)
            siteDays[day, default: [:]][host, default: 0] += count
            for key in siteDays.keys where key < day - 90 { siteDays.removeValue(forKey: key) }
        }
        hours[Self.hour(of: date), default: 0] += count
        let cutoff = Self.hour(of: date) - 400 * 24 * 3600
        let stale = hours.keys.filter { $0 < cutoff }
        if !stale.isEmpty { for key in stale { older += hours.removeValue(forKey: key) ?? 0 } }
    }

    func total(_ range: Range, now: Date = Date(), calendar: Calendar = .current) -> Int {
        switch range {
        case .all: return older + hours.values.reduce(0, +)
        case .today: return sum(since: calendar.startOfDay(for: now), now: now)
        case .day: return sum(since: now.addingTimeInterval(-24 * 3600), now: now)
        case .week: return sum(since: now.addingTimeInterval(-7 * 24 * 3600), now: now)
        case .month: return sum(since: now.addingTimeInterval(-30 * 24 * 3600), now: now)
        case .year: return sum(since: now.addingTimeInterval(-365 * 24 * 3600), now: now)
        }
    }

    /// Hours that start at or after the moment, up to now. An hour that began just before the moment counts only if it ends after it.
    private func sum(since start: Date, now: Date) -> Int {
        let first = Self.hour(of: start), last = Self.hour(of: now)
        return hours.reduce(0) { $1.key >= first && $1.key <= last ? $0 + $1.value : $0 }
    }

    static func hour(of date: Date) -> Int { Int(date.timeIntervalSince1970) / 3600 * 3600 }
    static func day(of date: Date) -> Int { Int(date.timeIntervalSince1970) / 86_400 }

    /// The sites with the most refused loads over the last `days` days, most first.
    func topSites(days: Int, limit: Int = 10, now: Date = Date()) -> [(host: String, count: Int)] {
        let first = Self.day(of: now) - days + 1
        var totals: [String: Int] = [:]
        for (day, sites) in siteDays where day >= first { for (host, count) in sites { totals[host, default: 0] += count } }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// One total per calendar day for the last `days` days, oldest first, including days with nothing.
    func dailyTotals(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, count: Int)] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().map { back in
            let start = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let first = Self.hour(of: start), last = Self.hour(of: end) - 1
            return (start, hours.reduce(0) { $1.key >= first && $1.key <= last ? $0 + $1.value : $0 })
        }
    }

    // MARK: Storage

    static func load(from url: URL) -> BlockedStats {
        guard let data = try? Data(contentsOf: url), let stats = try? JSONDecoder().decode(BlockedStats.self, from: data) else { return BlockedStats() }
        return stats
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
