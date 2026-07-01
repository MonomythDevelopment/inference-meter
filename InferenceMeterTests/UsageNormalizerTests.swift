import Foundation
import Testing
@testable import InferenceMeter

@Test("Codex JSONL fixture maps windows by window_minutes")
func codexJSONLFixtureMapsWindowsByMinutes() throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let usage = UsageNormalizer.codexRateLimits(
        from: try fixtureData(named: "codex-rollout-rate-limits.jsonl"),
        parsedAt: parsedAt
    )

    #expect(usage.provider == .codex)
    #expect(usage.source == .localFile)
    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 10))
    #expect(isClose(usage.weeklyPct, to: 15))
    #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_782_948_546))
    #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 1_783_469_995))
    #expect(usage.updatedAt == parsedAt)
}

@Test("Codex JSONL maps reordered primary and secondary windows by descriptor")
func codexJSONLMapsReorderedWindowsByDescriptor() {
    let payload = data("""
    {"rate_limits":{"primary":{"used_percent":130,"window_minutes":10080,"resets_at":2000},"secondary":{"used_percent":-5,"window_minutes":300,"resets_at":1000},"plan_type":"pro"}}
    """)

    let usage = UsageNormalizer.codexRateLimits(from: payload)

    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 0))
    #expect(isClose(usage.weeklyPct, to: 100))
    #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_000))
    #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 2_000))
}

@Test("Codex JSONL skips non-rate-limit lines while scanning backward")
func codexJSONLSkipsNonRateLimitLinesWhileScanningBackward() {
    let payload = data("""
    {"type":"message","content":"not a rate limit"}
    {"rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"resets_at":3000},"plan_type":"pro"}}
    {"type":"message","content":"newer non-rate-limit event"}
    """)

    let usage = UsageNormalizer.codexRateLimits(from: payload)

    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 12))
    #expect(usage.weeklyPct == nil)
    #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 3_000))
}

@Test("Claude endpoint fixture parses observed percentage-scale utilization")
func claudeEndpointFixtureParsesObservedPercentScaleUtilization() throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let usage = UsageNormalizer.claudeEndpoint(
        from: try fixtureData(named: "claude-usage-response.json"),
        parsedAt: parsedAt
    )

    #expect(usage.provider == .claude)
    #expect(usage.source == .endpoint)
    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 15))
    #expect(isClose(usage.weeklyPct, to: 4))
    #expect(usage.fiveHourResetsAt != nil)
    #expect(usage.weeklyResetsAt != nil)
    #expect(usage.updatedAt == parsedAt)
}

@Test("Claude endpoint converts fraction utilization and clamps over range")
func claudeEndpointConvertsFractionUtilizationAndClamps() {
    let payload = data("""
    {
      "five_hour": {"utilization": 0.42, "resets_at": 1782948546},
      "seven_day": {"utilization": 1.4, "resets_at": 1783469995}
    }
    """)

    let usage = UsageNormalizer.claudeEndpoint(from: payload)

    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 42))
    #expect(isClose(usage.weeklyPct, to: 100))
    #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_782_948_546))
    #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 1_783_469_995))
}

@Test("Claude statusLine fixture parses used_percentage")
func claudeStatusLineFixtureParsesUsedPercentage() throws {
    let usage = UsageNormalizer.claudeStatusLine(
        from: try fixtureData(named: "claude-statusline.json")
    )

    #expect(usage.provider == .claude)
    #expect(usage.source == .localFile)
    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 23.5))
    #expect(isClose(usage.weeklyPct, to: 81.25))
    #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_782_948_546))
    #expect(usage.weeklyResetsAt != nil)
}

@Test("Absent windows preserve nil and missing both is unavailable")
func absentWindowsPreserveNilAndMissingBothIsUnavailable() {
    let oneWindowPayload = data("""
    {
      "five_hour": {"used_percentage": 25, "resets_at": 1782948546}
    }
    """)

    let oneWindowUsage = UsageNormalizer.claudeStatusLine(from: oneWindowPayload)

    #expect(oneWindowUsage.state == .ok)
    #expect(isClose(oneWindowUsage.fiveHourPct, to: 25))
    #expect(oneWindowUsage.weeklyPct == nil)

    let noWindowUsage = UsageNormalizer.claudeStatusLine(from: data("{}"))

    #expect(noWindowUsage.state == .unavailable)
    #expect(noWindowUsage.fiveHourPct == nil)
    #expect(noWindowUsage.weeklyPct == nil)
}

@Test("Malformed payloads return unavailable usage without crashing")
func malformedPayloadsReturnUnavailableUsage() {
    let parsedAt = Date(timeIntervalSince1970: 1_800_000_200)
    let malformedPayload = data("not-json")
    let usages = [
        UsageNormalizer.codexRateLimits(from: malformedPayload, parsedAt: parsedAt),
        UsageNormalizer.claudeEndpoint(from: malformedPayload, parsedAt: parsedAt),
        UsageNormalizer.claudeStatusLine(from: malformedPayload, parsedAt: parsedAt)
    ]

    for usage in usages {
        #expect(usage.state == .unavailable)
        #expect(usage.fiveHourPct == nil)
        #expect(usage.weeklyPct == nil)
        #expect(usage.updatedAt == parsedAt)
    }
}

@Test("StatusLine percentages clamp negative and over-range values")
func statusLinePercentagesClampOutOfRangeValues() {
    let payload = data("""
    {
      "five_hour": {"used_percentage": -10, "resets_at": 1782948546},
      "seven_day": {"used_percentage": 130, "resets_at": 1783469995}
    }
    """)

    let usage = UsageNormalizer.claudeStatusLine(from: payload)

    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 0))
    #expect(isClose(usage.weeklyPct, to: 100))
}

// Hand-authored stand-in because IM-001 did not exercise statusLine fallback.
// Replace it with a real capture if a future spike records one.
private final class FixtureBundleMarker {}

private func fixtureData(named name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)

    if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }

    let sourceURL = URL(fileURLWithPath: #filePath)
    let fixtureURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)

    return try Data(contentsOf: fixtureURL)
}

private func data(_ value: String) -> Data {
    Data(value.utf8)
}

private func isClose(_ actual: Double?, to expected: Double) -> Bool {
    guard let actual else {
        return false
    }

    return abs(actual - expected) < 0.000_001
}
