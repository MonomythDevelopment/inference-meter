import Foundation

enum Provider: Sendable, Hashable {
    case claude
    case codex
}

enum UsageSource: Sendable {
    case commandLine
    case endpoint
    case localFile
}

enum UsageState: Sendable {
    case ok
    case stale
    case refreshRequired
    case unauthorized
    case unavailable
}

struct Usage: Sendable, Equatable {
    var provider: Provider
    var fiveHourPct: Double?
    var weeklyPct: Double?
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?
    var updatedAt: Date?
    var source: UsageSource
    var state: UsageState
    var fablePct: Double? = nil
    var fableResetsAt: Date? = nil
}

extension Usage {
    /// The single rule for showing a five-hour window, for every provider: the current
    /// data has a value for it. Plans do not predict this, and an idle window is still
    /// reported at 0%, so an absent value means the window does not apply right now.
    var reportsFiveHourWindow: Bool {
        fiveHourPct != nil
    }

    static func unavailable(
        provider: Provider,
        source: UsageSource = .localFile,
        updatedAt: Date? = nil
    ) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: updatedAt,
            source: source,
            state: .unavailable
        )
    }
}
