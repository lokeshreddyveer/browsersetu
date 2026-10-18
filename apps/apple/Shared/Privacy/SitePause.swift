import Foundation

/// Blocking paused on one website: until a time, or, with no time, until the browser quits.
struct SitePause: Codable, Equatable, Identifiable {
    var domain: String
    var until: Date?
    var id: String { domain }

    /// "ends in 42 minutes" or "until you quit".
    func summary(now: Date = Date()) -> String {
        guard let until else { return "until you quit" }
        let remaining = Int(until.timeIntervalSince(now) / 60.0)
        if remaining < 1 { return "ends in under a minute" }
        if remaining < 60 { return "ends in \(remaining) min" }
        return "ends in \(remaining / 60) h \(remaining % 60) min"
    }
}

/// How long blocking stays paused: a short time (a visit), an hour, until the browser quits, or for good (the old switch).
enum PauseLength: CaseIterable, Identifiable {
    case tenMinutes, hour, untilQuit, always
    var id: Self { self }
    var title: String {
        switch self {
        case .tenMinutes: "Pause for 10 minutes"
        case .hour: "Pause for 1 hour"
        case .untilQuit: "Pause until I quit"
        case .always: "Turn off for this site"
        }
    }
    func endDate(from now: Date = Date()) -> Date? {
        switch self {
        case .tenMinutes: now.addingTimeInterval(600)
        case .hour: now.addingTimeInterval(3600)
        case .untilQuit, .always: nil
        }
    }
}
