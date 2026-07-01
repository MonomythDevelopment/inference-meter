import Foundation

enum Provider: Sendable {
    case claude
    case codex
}

enum UsageSource: Sendable {
    case endpoint
    case localFile
}

enum UsageState: Sendable {
    case ok
    case stale
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
}
