import Foundation
import Testing
@testable import InferenceMeter

@Test("Claude's fixture with a five-hour window renders every window")
func claudeFixtureWithFiveHourWindowRendersEveryWindow() throws {
    let usage = UsageNormalizer.claudeEndpoint(from: try fixtureData(named: "claude-usage-response.json"))

    #expect(usage.reportsFiveHourWindow)
    #expect(ProviderDisplayConfiguration.claude.displayedWindows(for: usage).map(\.title) == [
        "5-hour",
        "Weekly",
        "Fable"
    ])
    #expect(labelText(claude: usage, compact: false).hasPrefix("✳ \(rounded(usage.fiveHourPct))·\(rounded(usage.weeklyPct))"))
    #expect(labelText(claude: usage, compact: true).hasPrefix("✳ \(rounded(usage.fiveHourPct)) "))
}

@Test("Claude's fixture without a five-hour window leaves it out")
func claudeFixtureWithoutFiveHourWindowLeavesItOut() throws {
    let usage = UsageNormalizer.claudeEndpoint(
        from: try fixtureData(named: "claude-usage-absent-five-hour.json")
    )

    #expect(usage.state == .ok)
    #expect(!usage.reportsFiveHourWindow)
    #expect(ProviderDisplayConfiguration.claude.displayedWindows(for: usage).map(\.title) == [
        "Weekly",
        "Fable"
    ])
    #expect(labelText(claude: usage, compact: false).hasPrefix("✳ 41  "))
    #expect(labelText(claude: usage, compact: true).hasPrefix("✳ 41 "))
}

@Test("Codex's fixture with a five-hour window renders both windows")
func codexFixtureWithFiveHourWindowRendersBothWindows() throws {
    let usage = UsageNormalizer.codexRateLimits(
        from: try fixtureData(named: "codex-rollout-rate-limits.jsonl"),
        parsedAt: Date(timeIntervalSince1970: 1_782_900_000)
    )

    #expect(ProviderDisplayConfiguration.codex.displayedWindows(for: usage).map(\.title) == [
        "5-hour",
        "Weekly"
    ])
    #expect(labelText(codex: usage, compact: false).hasSuffix("⬡ 10·15"))
    #expect(labelText(codex: usage, compact: true).hasSuffix("⬡ 10"))
}

@Test("Codex's weekly-only app-server response leaves the five-hour window out")
func codexWeeklyOnlyResponseLeavesFiveHourWindowOut() {
    let usage = UsageNormalizer.codexAppServerRateLimits(
        from: Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1800604800},"secondary":null}}}
        """.utf8),
        parsedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(usage.state == .ok)
    #expect(ProviderDisplayConfiguration.codex.displayedWindows(for: usage).map(\.title) == ["Weekly"])
    #expect(labelText(codex: usage, compact: false).hasSuffix("⬡ 42"))
    #expect(labelText(codex: usage, compact: true).hasSuffix("⬡ 42"))
}

@Test("A provider with no usage values shows one dash and no five-hour row")
func providerWithNoUsageValuesShowsOneDashAndNoFiveHourRow() {
    let claude = Usage.unavailable(provider: .claude)
    let codex = Usage.unavailable(provider: .codex)

    #expect(labelText(claude: claude, codex: codex, compact: false) == "✳ --  ⬡ --")
    #expect(labelText(claude: claude, codex: codex, compact: true) == "✳ -- ⬡ --")
    #expect(ProviderDisplayConfiguration.claude.displayedWindows(for: claude).map(\.title) == [
        "Weekly",
        "Fable"
    ])
    #expect(ProviderDisplayConfiguration.codex.displayedWindows(for: codex).map(\.title) == ["Weekly"])
}

@Test("An expired Codex five-hour window is not shown and its value never appears as weekly")
func expiredCodexFiveHourWindowIsNotShownOrShownAsWeekly() {
    let parsedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let usage = UsageNormalizer.codexAppServerRateLimits(
        from: Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":88,"windowDurationMins":300,"resetsAt":1799999999},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1800604800}}}}
        """.utf8),
        parsedAt: parsedAt
    )

    #expect(usage.fiveHourPct == nil)
    #expect(ProviderDisplayConfiguration.codex.displayedWindows(for: usage).map(\.title) == ["Weekly"])
    #expect(labelText(codex: usage, compact: false).hasSuffix("⬡ 42"))
    #expect(labelText(codex: usage, compact: true).hasSuffix("⬡ 42"))
}

@Test("A Codex rollout window whose reset has passed since it was written is not shown")
func codexRolloutWindowWhoseResetHasPassedIsNotShown() async throws {
    // Valid when written on 2026-10-01: the five-hour window resets two hours later.
    let home = try temporaryCodexHome(rollout: """
    {"timestamp":"2026-10-01T10:00:00Z","rate_limits":{"primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1790856000},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1791300000}}}
    """)
    defer { try? FileManager.default.removeItem(at: home) }

    let provider = { (now: Date) in
        CodexProvider(
            homeDirectory: home,
            appServerClient: CodexAppServerClient { nil },
            now: { now }
        )
    }

    let beforeReset = await provider(Date(timeIntervalSince1970: 1_790_855_999)).refresh()
    #expect(beforeReset.fiveHourPct == 88)
    #expect(beforeReset.weeklyPct == 42)

    let atReset = await provider(Date(timeIntervalSince1970: 1_790_856_000)).refresh()
    #expect(atReset.state == .ok)
    #expect(atReset.fiveHourPct == nil)
    #expect(atReset.fiveHourResetsAt == nil)
    #expect(atReset.weeklyPct == 42)
    #expect(labelText(codex: atReset, compact: false).hasSuffix("⬡ 42"))
}

@Test("A Codex rollout holding only a reset five-hour window is a failed refresh")
func codexRolloutHoldingOnlyResetFiveHourWindowIsFailedRefresh() async throws {
    let home = try temporaryCodexHome(rollout: """
    {"timestamp":"2026-10-01T10:00:00Z","rate_limits":{"primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1790856000}}}
    """)
    defer { try? FileManager.default.removeItem(at: home) }

    let usage = await CodexProvider(
        homeDirectory: home,
        appServerClient: CodexAppServerClient { nil },
        now: { Date(timeIntervalSince1970: 1_790_856_000) }
    ).refresh()

    #expect(usage.state == .unavailable)
    #expect(usage.fiveHourPct == nil)
}

private func temporaryCodexHome(rollout: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("InferenceMeterFiveHourTests-\(UUID().uuidString)", isDirectory: true)
    let dayDirectory = home.appendingPathComponent(".codex/sessions/2026/10/01", isDirectory: true)
    try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
    try Data(rollout.utf8).write(to: dayDirectory.appendingPathComponent("rollout-test.jsonl"))
    return home
}

private func labelText(
    claude: Usage = .unavailable(provider: .claude),
    codex: Usage = .unavailable(provider: .codex),
    compact: Bool
) -> String {
    labelSegments(claude: claude, codex: codex, compact: compact).map(\.text).joined()
}

private func rounded(_ percentage: Double?) -> String {
    String(format: "%2d", Int((percentage ?? -1).rounded()))
}

private final class FixtureBundleMarker {}

private func fixtureData(named name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)

    if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }

    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)

    return try Data(contentsOf: fixtureURL)
}
