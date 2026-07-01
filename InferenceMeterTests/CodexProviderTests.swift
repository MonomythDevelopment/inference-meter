import Foundation
import Testing
@testable import InferenceMeter

@Test("CodexProvider returns unavailable when sessions directory is missing")
func codexProviderReturnsUnavailableWhenSessionsDirectoryIsMissing() async throws {
    try await withTemporaryHome { home in
        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.provider == .codex)
        #expect(usage.source == .localFile)
        #expect(usage.state == .unavailable)
        #expect(usage.fiveHourPct == nil)
        #expect(usage.weeklyPct == nil)
        #expect(usage.updatedAt == nil)
    }
}

@Test("CodexProvider returns unavailable when newest rollout has no rate limits")
func codexProviderReturnsUnavailableWhenNewestRolloutHasNoRateLimits() async throws {
    try await withTemporaryHome { home in
        try writeRollout(
            home: home,
            contents: try fixtureString(named: "codex-rollout-no-rate-limits.jsonl")
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .unavailable)
        #expect(usage.fiveHourPct == nil)
        #expect(usage.weeklyPct == nil)
    }
}

@Test("CodexProvider maps shuffled windows by window_minutes")
func codexProviderMapsShuffledWindowsByMinutes() async throws {
    try await withTemporaryHome { home in
        try writeRollout(
            home: home,
            contents: try fixtureString(named: "codex-rollout-shuffled-windows.jsonl")
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(usage.source == .localFile)
        #expect(isClose(usage.fiveHourPct, to: 7.5))
        #expect(isClose(usage.weeklyPct, to: 88))
        #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_782_948_546))
        #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 1_783_469_995))
        #expect(usage.updatedAt == isoDate("2026-07-01T12:00:00Z"))
    }
}

@Test("CodexProvider tail scan selects the last rate limit event")
func codexProviderTailScanSelectsLastRateLimitEvent() async throws {
    try await withTemporaryHome { home in
        try writeRollout(
            home: home,
            contents: try fixtureString(named: "codex-rollout-multi-event.jsonl")
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(isClose(usage.fiveHourPct, to: 33))
        #expect(isClose(usage.weeklyPct, to: 44))
        #expect(usage.updatedAt == isoDate("2026-07-01T10:02:00Z"))
    }
}

@Test("CodexProvider parses rate limits nested inside a JSONL event payload")
func codexProviderParsesNestedRateLimitPayload() async throws {
    try await withTemporaryHome { home in
        try writeRollout(
            home: home,
            contents: """
            {"timestamp":"2026-07-01T11:00:00Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":17.0,"window_minutes":300,"resets_at":1782948546},"secondary":{"used_percent":29.0,"window_minutes":10080,"resets_at":1783469995},"plan_type":"pro"}}}
            """
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(isClose(usage.fiveHourPct, to: 17))
        #expect(isClose(usage.weeklyPct, to: 29))
        #expect(usage.updatedAt == isoDate("2026-07-01T11:00:00Z"))
    }
}

@Test("CodexProvider uses file mtime when a rate limit line has no timestamp")
func codexProviderUsesFileModificationDateWhenLineHasNoTimestamp() async throws {
    try await withTemporaryHome { home in
        let modificationDate = Date(timeIntervalSince1970: 1_800_001_234)
        try writeRollout(
            home: home,
            contents: """
            {"rate_limits":{"primary":{"used_percent":21.0,"window_minutes":300,"resets_at":1782948546},"secondary":{"used_percent":34.0,"window_minutes":10080,"resets_at":1783469995},"plan_type":"pro"}}
            """,
            modificationDate: modificationDate
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(isClose(usage.fiveHourPct, to: 21))
        #expect(isClose(usage.weeklyPct, to: 34))
        #expect(usage.updatedAt == modificationDate)
    }
}

@Test("CodexProvider walks newest year month day and newest rollout within that day")
func codexProviderWalksNewestSessionDirectoryWithoutGlobalFileSort() async throws {
    try await withTemporaryHome { home in
        try writeRollout(
            home: home,
            year: "2025",
            month: "12",
            day: "31",
            name: "rollout-old-day.jsonl",
            contents: rateLimitsLine(fiveHourPct: 99, weeklyPct: 99),
            modificationDate: Date(timeIntervalSince1970: 1_900_000_000)
        )
        try writeRollout(
            home: home,
            year: "2026",
            month: "07",
            day: "02",
            name: "rollout-older-in-new-day.jsonl",
            contents: rateLimitsLine(fiveHourPct: 11, weeklyPct: 22),
            modificationDate: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try writeRollout(
            home: home,
            year: "2026",
            month: "07",
            day: "02",
            name: "rollout-newer-in-new-day.jsonl",
            contents: rateLimitsLine(fiveHourPct: 55, weeklyPct: 66),
            modificationDate: Date(timeIntervalSince1970: 1_800_000_200)
        )

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(isClose(usage.fiveHourPct, to: 55))
        #expect(isClose(usage.weeklyPct, to: 66))
    }
}

@Test("CodexProvider reads a large rollout tail without decoding earlier noise lines")
func codexProviderReadsLargeRolloutTail() async throws {
    try await withTemporaryHome { home in
        let noiseLines = (0..<5_000).map { index in
            #"{"timestamp":"2026-07-01T10:00:00Z","type":"message","index":\#(index)}"#
        }
        let contents = (noiseLines + [
            rateLimitsLine(timestamp: "2026-07-01T10:01:00Z", fiveHourPct: 12, weeklyPct: 24),
            #"{"timestamp":"2026-07-01T10:02:00Z","type":"message","index":"tail-noise"}"#,
            rateLimitsLine(timestamp: "2026-07-01T10:03:00Z", fiveHourPct: 61, weeklyPct: 72)
        ]).joined(separator: "\n")

        try writeRollout(home: home, contents: contents)

        let usage = await CodexProvider(homeDirectory: home).refresh()

        #expect(usage.state == .ok)
        #expect(isClose(usage.fiveHourPct, to: 61))
        #expect(isClose(usage.weeklyPct, to: 72))
        #expect(usage.updatedAt == isoDate("2026-07-01T10:03:00Z"))
    }
}

private final class CodexProviderFixtureBundleMarker {}

private func withTemporaryHome(_ body: (URL) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("InferenceMeterCodexProviderTests-\(UUID().uuidString)", isDirectory: true)

    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try await body(home)
}

@discardableResult
private func writeRollout(
    home: URL,
    year: String = "2026",
    month: String = "07",
    day: String = "01",
    name: String = "rollout-test.jsonl",
    contents: String,
    modificationDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
) throws -> URL {
    let dayDirectory = home
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(year, isDirectory: true)
        .appendingPathComponent(month, isDirectory: true)
        .appendingPathComponent(day, isDirectory: true)

    try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

    let fileURL = dayDirectory.appendingPathComponent(name, isDirectory: false)
    try Data(contents.utf8).write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fileURL.path)

    return fileURL
}

private func fixtureString(named name: String) throws -> String {
    let bundle = Bundle(for: CodexProviderFixtureBundleMarker.self)

    if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    let sourceURL = URL(fileURLWithPath: #filePath)
    let fixtureURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)

    return String(decoding: try Data(contentsOf: fixtureURL), as: UTF8.self)
}

private func rateLimitsLine(
    timestamp: String = "2026-07-01T10:00:00Z",
    fiveHourPct: Double,
    weeklyPct: Double
) -> String {
    """
    {"timestamp":"\(timestamp)","rate_limits":{"primary":{"used_percent":\(fiveHourPct),"window_minutes":300,"resets_at":1782948546},"secondary":{"used_percent":\(weeklyPct),"window_minutes":10080,"resets_at":1783469995},"plan_type":"pro"}}
    """
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }

    return date
}

private func isClose(_ actual: Double?, to expected: Double) -> Bool {
    guard let actual else {
        return false
    }

    return abs(actual - expected) < 0.000_001
}
