import SwiftUI
import Testing
@testable import InferenceMeter

@Test("Threshold colors follow green, amber, red boundaries")
func thresholdColorsFollowBoundaries() {
    #expect(thresholdColor(0) == Color(.systemGreen))
    #expect(thresholdColor(69.9) == Color(.systemGreen))
    #expect(thresholdColor(70.0) == Color(.systemOrange))
    #expect(thresholdColor(89.9) == Color(.systemOrange))
    #expect(thresholdColor(90.0) == Color(.systemRed))
    #expect(thresholdColor(100) == Color(.systemRed))
}

@Test("Threshold predicate treats equality as crossing the boundary")
func thresholdPredicateTreatsEqualityAsCrossingBoundary() {
    #expect(!isAtOrAboveUsageThreshold(79.9, threshold: 80))
    #expect(isAtOrAboveUsageThreshold(80, threshold: 80))
    #expect(isAtOrAboveUsageThreshold(95.1, threshold: 95))
}

@Test("Full mode renders both providers with independently colored values")
func fullModeRendersBothProvidersWithIndependentValueColors() {
    let segments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 45, weeklyPct: 70),
        codex: usage(provider: .codex, fiveHourPct: 30, weeklyPct: 90),
        compact: false
    )

    #expect(segmentText(segments) == "✳ 45·70  ⬡ 30·90")
    #expect(segments == [
        MenuBarLabelSegment(text: "✳ ", color: .primary),
        MenuBarLabelSegment(text: "45", color: Color(.systemGreen)),
        MenuBarLabelSegment(text: "·", color: .primary),
        MenuBarLabelSegment(text: "70", color: Color(.systemOrange)),
        MenuBarLabelSegment(text: "  ", color: .primary),
        MenuBarLabelSegment(text: "⬡ ", color: .primary),
        MenuBarLabelSegment(text: "30", color: Color(.systemGreen)),
        MenuBarLabelSegment(text: "·", color: .primary),
        MenuBarLabelSegment(text: "90", color: Color(.systemRed))
    ])
}

@Test("Compact mode drops weekly values and keeps five-hour colors")
func compactModeDropsWeeklyValuesAndKeepsFiveHourColors() {
    let segments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 45, weeklyPct: 70),
        codex: usage(provider: .codex, fiveHourPct: 30, weeklyPct: 55),
        compact: true
    )

    #expect(segmentText(segments) == "✳ 45 ⬡ 30")
    #expect(segments == [
        MenuBarLabelSegment(text: "✳ ", color: .primary),
        MenuBarLabelSegment(text: "45", color: Color(.systemGreen)),
        MenuBarLabelSegment(text: " ", color: .primary),
        MenuBarLabelSegment(text: "⬡ ", color: .primary),
        MenuBarLabelSegment(text: "30", color: Color(.systemGreen))
    ])
}

@Test("Stale providers keep values visible in secondary gray")
func staleProvidersKeepValuesVisibleInSecondaryGray() {
    let fullSegments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 69.9, weeklyPct: 89.9, state: .stale),
        codex: usage(provider: .codex, fiveHourPct: 90, weeklyPct: 100),
        compact: false
    )
    let compactSegments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 69.9, weeklyPct: 89.9, state: .stale),
        codex: usage(provider: .codex, fiveHourPct: 90, weeklyPct: 100),
        compact: true
    )

    #expect(segmentText(fullSegments) == "✳ 70·90  ⬡ 90·100")
    #expect(fullSegments[1].color == .secondary)
    #expect(fullSegments[3].color == .secondary)
    #expect(fullSegments[6].color == Color(.systemRed))
    #expect(fullSegments[8].color == Color(.systemRed))

    #expect(segmentText(compactSegments) == "✳ 70 ⬡ 90")
    #expect(compactSegments[1].color == .secondary)
    #expect(compactSegments[4].color == Color(.systemRed))
}

@Test("Refresh-required providers preserve prior values or show a renewal marker")
func refreshRequiredProvidersPreserveValuesOrShowRenewalMarker() {
    let segments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 45, weeklyPct: 70, state: .refreshRequired),
        codex: usage(provider: .codex, fiveHourPct: nil, weeklyPct: nil, state: .refreshRequired),
        compact: false
    )

    #expect(segmentText(segments) == "✳ 45·70  ⬡ ↻")
    #expect(segments[1].color == .secondary)
    #expect(segments[3].color == .secondary)
    #expect(segments.last == MenuBarLabelSegment(text: "↻", color: Color(.systemOrange)))
}

@Test("Unauthorized providers render auth markers in full and compact modes")
func unauthorizedProvidersRenderAuthMarkersInFullAndCompactModes() {
    let fullSegments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 45, weeklyPct: 70),
        codex: usage(provider: .codex, fiveHourPct: 30, weeklyPct: 55, state: .unauthorized),
        compact: false
    )
    let compactSegments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 45, weeklyPct: 70, state: .unauthorized),
        codex: usage(provider: .codex, fiveHourPct: 30, weeklyPct: 55),
        compact: true
    )

    #expect(segmentText(fullSegments) == "✳ 45·70  ⬡ !")
    #expect(fullSegments.last == MenuBarLabelSegment(text: "!", color: Color(.systemOrange)))

    #expect(segmentText(compactSegments) == "✳ ! ⬡ 30")
    #expect(compactSegments[1] == MenuBarLabelSegment(text: "!", color: Color(.systemOrange)))
}

@Test("Unavailable providers render dashes instead of zero values")
func unavailableProvidersRenderDashesInsteadOfZeroValues() {
    let fullSegments = labelSegments(
        claude: .unavailable(provider: .claude),
        codex: usage(provider: .codex, fiveHourPct: 0, weeklyPct: 69.9),
        compact: false
    )
    let compactSegments = labelSegments(
        claude: .unavailable(provider: .claude),
        codex: usage(provider: .codex, fiveHourPct: 0, weeklyPct: 69.9),
        compact: true
    )

    #expect(segmentText(fullSegments) == "✳ --·--  ⬡  0·70")
    #expect(fullSegments[1].color == .secondary)
    #expect(fullSegments[3].color == .secondary)
    #expect(fullSegments[6].color == Color(.systemGreen))
    #expect(fullSegments[8].color == Color(.systemGreen))

    #expect(segmentText(compactSegments) == "✳ -- ⬡  0")
    #expect(compactSegments[1].color == .secondary)
    #expect(compactSegments[4].color == Color(.systemGreen))
}

@Test("Nil values render as dashes and single digits use a stable two-character slot")
func nilValuesRenderAsDashesAndSingleDigitsUseStableSlot() {
    let segments = labelSegments(
        claude: usage(provider: .claude, fiveHourPct: 9.4, weeklyPct: nil),
        codex: usage(provider: .codex, fiveHourPct: nil, weeklyPct: 10.4),
        compact: false
    )

    #expect(segmentText(segments) == "✳  9·--  ⬡ --·10")
    #expect(segments[1] == MenuBarLabelSegment(text: " 9", color: Color(.systemGreen)))
    #expect(segments[3] == MenuBarLabelSegment(text: "--", color: .secondary))
    #expect(segments[6] == MenuBarLabelSegment(text: "--", color: .secondary))
    #expect(segments[8] == MenuBarLabelSegment(text: "10", color: Color(.systemGreen)))
}

private func segmentText(_ segments: [MenuBarLabelSegment]) -> String {
    segments.map(\.text).joined()
}

private func usage(
    provider: Provider,
    fiveHourPct: Double?,
    weeklyPct: Double?,
    state: UsageState = .ok
) -> Usage {
    Usage(
        provider: provider,
        fiveHourPct: fiveHourPct,
        weeklyPct: weeklyPct,
        fiveHourResetsAt: nil,
        weeklyResetsAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: .endpoint,
        state: state
    )
}
