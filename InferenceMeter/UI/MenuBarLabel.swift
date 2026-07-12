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
    providerSegments(symbol: "✳", usage: claude, compact: compact)
        + [MenuBarLabelSegment(text: compact ? " " : "  ", color: .primary)]
        + providerSegments(symbol: "⬡", usage: codex, compact: compact)
}

private func composedLabelText(_ segments: [MenuBarLabelSegment]) -> Text {
    segments.reduce(Text("")) { partialResult, segment in
        partialResult + Text(segment.text).foregroundStyle(segment.color)
    }
}

private func providerSegments(symbol: String, usage: Usage, compact: Bool) -> [MenuBarLabelSegment] {
    var segments = [
        MenuBarLabelSegment(text: "\(symbol) ", color: .primary)
    ]

    switch usage.state {
    case .ok:
        segments.append(contentsOf: valueSegments(usage: usage, colorOverride: nil, compact: compact))
    case .stale:
        segments.append(contentsOf: valueSegments(usage: usage, colorOverride: .secondary, compact: compact))
    case .refreshRequired:
        if usage.fiveHourPct != nil || usage.weeklyPct != nil {
            segments.append(contentsOf: valueSegments(usage: usage, colorOverride: .secondary, compact: compact))
        } else {
            segments.append(MenuBarLabelSegment(text: "↻", color: Color(.systemOrange)))
        }
    case .unauthorized:
        segments.append(MenuBarLabelSegment(text: "!", color: Color(.systemOrange)))
    case .unavailable:
        segments.append(contentsOf: unavailableSegments(compact: compact))
    }

    return segments
}

private func valueSegments(
    usage: Usage,
    colorOverride: Color?,
    compact: Bool
) -> [MenuBarLabelSegment] {
    var segments = [percentageSegment(usage.fiveHourPct, colorOverride: colorOverride)]

    guard !compact else {
        return segments
    }

    segments.append(MenuBarLabelSegment(text: "·", color: .primary))
    segments.append(percentageSegment(usage.weeklyPct, colorOverride: colorOverride))
    return segments
}

private func unavailableSegments(compact: Bool) -> [MenuBarLabelSegment] {
    var segments = [
        MenuBarLabelSegment(text: "--", color: .secondary)
    ]

    guard !compact else {
        return segments
    }

    segments.append(MenuBarLabelSegment(text: "·", color: .primary))
    segments.append(MenuBarLabelSegment(text: "--", color: .secondary))
    return segments
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
