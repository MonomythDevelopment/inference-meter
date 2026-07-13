import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @AppStorage("compactLabel") private var isCompactLabel = false

    var body: some View {
        composedLabelText(
            labelSegments(
                claude: appState.claude,
                codex: appState.codex,
                compact: isCompactLabel
            )
        )
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct MenuBarLabelSegment: Equatable {
    let text: String
    let color: Color
}

func isAtOrAboveUsageThreshold(_ pct: Double, threshold: Double) -> Bool {
    pct >= threshold
}

func thresholdColor(_ pct: Double) -> Color {
    if isAtOrAboveUsageThreshold(pct, threshold: 90) {
        return Color(.systemRed)
    }

    if isAtOrAboveUsageThreshold(pct, threshold: 70) {
        return Color(.systemOrange)
    }

    return Color(.systemGreen)
}

func labelSegments(claude: Usage, codex: Usage, compact: Bool) -> [MenuBarLabelSegment] {
    providerSegments(usage: claude, compact: compact)
        + [MenuBarLabelSegment(text: compact ? " " : "  ", color: .primary)]
        + providerSegments(usage: codex, compact: compact)
}

private func composedLabelText(_ segments: [MenuBarLabelSegment]) -> Text {
    segments.reduce(Text("")) { partialResult, segment in
        partialResult + Text(segment.text).foregroundStyle(segment.color)
    }
}

private func providerSegments(usage: Usage, compact: Bool) -> [MenuBarLabelSegment] {
    let displayedPercentages = displayedPercentages(for: usage, compact: compact)
    var segments = [
        MenuBarLabelSegment(text: "\(usage.provider.menuBarSymbol) ", color: .primary)
    ]

    switch usage.state {
    case .ok:
        segments.append(contentsOf: valueSegments(displayedPercentages, colorOverride: nil))
    case .stale:
        segments.append(contentsOf: valueSegments(displayedPercentages, colorOverride: .secondary))
    case .refreshRequired:
        if displayedPercentages.contains(where: { $0 != nil }) {
            segments.append(contentsOf: valueSegments(displayedPercentages, colorOverride: .secondary))
        } else {
            segments.append(MenuBarLabelSegment(text: "↻", color: Color(.systemOrange)))
        }
    case .unauthorized:
        segments.append(MenuBarLabelSegment(text: "!", color: Color(.systemOrange)))
    case .unavailable:
        segments.append(contentsOf: unavailableSegments(windowCount: displayedPercentages.count))
    }

    return segments
}

private func displayedPercentages(for usage: Usage, compact: Bool) -> [Double?] {
    let percentages: [Double?]

    switch usage.provider {
    case .claude:
        percentages = [usage.fiveHourPct, usage.weeklyPct]
    case .codex:
        percentages = [usage.fiveHourPct, usage.weeklyPct]
    }

    return compact ? Array(percentages.prefix(1)) : percentages
}

private func valueSegments(
    _ percentages: [Double?],
    colorOverride: Color?
) -> [MenuBarLabelSegment] {
    percentages.enumerated().flatMap { index, percentage in
        let value = percentageSegment(percentage, colorOverride: colorOverride)

        guard index > 0 else {
            return [value]
        }

        return [MenuBarLabelSegment(text: "·", color: .primary), value]
    }
}

private func unavailableSegments(windowCount: Int) -> [MenuBarLabelSegment] {
    valueSegments(Array(repeating: nil, count: windowCount), colorOverride: .secondary)
}

private func percentageSegment(_ pct: Double?, colorOverride: Color?) -> MenuBarLabelSegment {
    guard let pct else {
        return MenuBarLabelSegment(text: "--", color: colorOverride ?? .secondary)
    }

    return MenuBarLabelSegment(
        text: formattedPercentage(pct),
        color: colorOverride ?? thresholdColor(pct)
    )
}

private func formattedPercentage(_ pct: Double) -> String {
    let roundedPct = Int(pct.rounded())

    guard roundedPct >= 0, roundedPct < 100 else {
        return "\(roundedPct)"
    }

    return String(format: "%2d", roundedPct)
}

private extension Provider {
    var menuBarSymbol: String {
        switch self {
        case .claude:
            "✳"
        case .codex:
            "⬡"
        }
    }
}
