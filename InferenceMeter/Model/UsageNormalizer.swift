import Foundation

enum UsageNormalizer {
    static func codexRateLimits(
        from data: Data,
        source: UsageSource = .localFile,
        parsedAt: Date = Date()
    ) -> Usage {
        guard let rateLimits = decodeCodexRateLimits(from: data) else {
            return unavailableUsage(provider: .codex, source: source, parsedAt: parsedAt)
        }

        var fiveHourPct: Double?
        var weeklyPct: Double?
        var fiveHourResetsAt: Date?
        var weeklyResetsAt: Date?

        for window in [rateLimits.primary, rateLimits.secondary].compactMap({ $0 }) {
            switch window.windowMinutes {
            case 300:
                fiveHourPct = window.usedPercent.map(clampPercentage)
                fiveHourResetsAt = window.resetsAt
            case 10_080:
                weeklyPct = window.usedPercent.map(clampPercentage)
                weeklyResetsAt = window.resetsAt
            default:
                continue
            }
        }

        return usage(
            provider: .codex,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: parsedAt,
            source: source
        )
    }

    static func claudeEndpoint(
        from data: Data,
        parsedAt: Date = Date()
    ) -> Usage {
        let decoder = JSONDecoder()

        guard let response = try? decoder.decode(ClaudeEndpointResponseDTO.self, from: data) else {
            return unavailableUsage(provider: .claude, source: .endpoint, parsedAt: parsedAt)
        }

        let fiveHourLimit = matchingEndpointLimitPercent(for: .fiveHour, in: response.limits)
        let weeklyLimit = matchingEndpointLimitPercent(for: .weekly, in: response.limits)

        return usage(
            provider: .claude,
            fiveHourPct: normalizeClaudeEndpointUtilization(
                response.fiveHour?.utilization,
                matchingLimitPercent: fiveHourLimit
            ),
            weeklyPct: normalizeClaudeEndpointUtilization(
                response.sevenDay?.utilization,
                matchingLimitPercent: weeklyLimit
            ),
            fiveHourResetsAt: response.fiveHour?.resetsAt,
            weeklyResetsAt: response.sevenDay?.resetsAt,
            updatedAt: parsedAt,
            source: .endpoint
        )
    }

    static func claudeStatusLine(
        from data: Data,
        parsedAt: Date = Date()
    ) -> Usage {
        let decoder = JSONDecoder()

        guard let response = try? decoder.decode(ClaudeStatusLineResponseDTO.self, from: data) else {
            return unavailableUsage(provider: .claude, source: .localFile, parsedAt: parsedAt)
        }

        return usage(
            provider: .claude,
            fiveHourPct: response.fiveHour?.usedPercentage.map(clampPercentage),
            weeklyPct: response.sevenDay?.usedPercentage.map(clampPercentage),
            fiveHourResetsAt: response.fiveHour?.resetsAt,
            weeklyResetsAt: response.sevenDay?.resetsAt,
            updatedAt: parsedAt,
            source: .localFile
        )
    }
}

private extension UsageNormalizer {
    enum ClaudeEndpointWindow {
        case fiveHour
        case weekly
    }

    static func decodeCodexRateLimits(from data: Data) -> CodexRateLimitsDTO? {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(CodexRateLimitsEnvelopeDTO.self, from: data),
           let rateLimits = envelope.rateLimits {
            return rateLimits
        }

        if let rateLimits = try? decoder.decode(CodexRateLimitsDTO.self, from: data),
           rateLimits.hasWindow {
            return rateLimits
        }

        guard let jsonLines = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in jsonLines.split(whereSeparator: \.isNewline).reversed() {
            let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty,
                  let lineData = trimmedLine.data(using: .utf8) else {
                continue
            }

            if let envelope = try? decoder.decode(CodexRateLimitsEnvelopeDTO.self, from: lineData),
               let rateLimits = envelope.rateLimits {
                return rateLimits
            }

            if let rateLimits = try? decoder.decode(CodexRateLimitsDTO.self, from: lineData),
               rateLimits.hasWindow {
                return rateLimits
            }
        }

        return nil
    }

    static func matchingEndpointLimitPercent(
        for window: ClaudeEndpointWindow,
        in limits: [ClaudeEndpointLimitDTO]
    ) -> Double? {
        switch window {
        case .fiveHour:
            return limits.first { $0.kind == "session" || $0.group == "session" }?.percent
        case .weekly:
            return limits.first { $0.kind == "weekly_all" }?.percent
                ?? limits.first { $0.group == "weekly" }?.percent
        }
    }

    static func normalizeClaudeEndpointUtilization(
        _ utilization: Double?,
        matchingLimitPercent: Double?
    ) -> Double? {
        guard let utilization else {
            return nil
        }

        let fractionScalePercent = utilization * 100

        // The issue contract says `utilization` is a 0-1 fraction, but the IM-001
        // fixture observed percentage-scale values matching `limits[].percent`.
        if let matchingLimitPercent,
           isApproximatelyEqual(utilization, matchingLimitPercent) {
            return clampPercentage(utilization)
        }

        if let matchingLimitPercent,
           isApproximatelyEqual(fractionScalePercent, matchingLimitPercent) {
            return clampPercentage(fractionScalePercent)
        }

        return clampPercentage(fractionScalePercent)
    }

    static func usage(
        provider: Provider,
        fiveHourPct: Double?,
        weeklyPct: Double?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        updatedAt: Date?,
        source: UsageSource
    ) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: updatedAt,
            source: source,
            state: fiveHourPct == nil && weeklyPct == nil ? .unavailable : .ok
        )
    }

    static func unavailableUsage(provider: Provider, source: UsageSource, parsedAt: Date) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: parsedAt,
            source: source,
            state: .unavailable
        )
    }

    static func clampPercentage(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    static func isApproximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }
}

private struct CodexRateLimitsEnvelopeDTO: Codable, Sendable {
    var rateLimits: CodexRateLimitsDTO?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct CodexRateLimitsDTO: Codable, Sendable {
    var primary: CodexRateLimitWindowDTO?
    var secondary: CodexRateLimitWindowDTO?
    var planType: String?
    var hasWindow: Bool {
        primary != nil || secondary != nil
    }

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
    }
}

private struct CodexRateLimitWindowDTO: Codable, Sendable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        usedPercent = container.decodeLossyDoubleIfPresent(forKey: .usedPercent)
        windowMinutes = container.decodeLossyIntIfPresent(forKey: .windowMinutes)
        resetsAt = container.decodeFlexibleDateIfPresent(forKey: .resetsAt)
    }
}

private struct ClaudeEndpointResponseDTO: Codable, Sendable {
    var fiveHour: ClaudeEndpointWindowDTO?
    var sevenDay: ClaudeEndpointWindowDTO?
    var limits: [ClaudeEndpointLimitDTO]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        fiveHour = try container.decodeIfPresent(ClaudeEndpointWindowDTO.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(ClaudeEndpointWindowDTO.self, forKey: .sevenDay)
        limits = try container.decodeIfPresent([ClaudeEndpointLimitDTO].self, forKey: .limits) ?? []
    }
}

private struct ClaudeEndpointWindowDTO: Codable, Sendable {
    var utilization: Double?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        utilization = container.decodeLossyDoubleIfPresent(forKey: .utilization)
        resetsAt = container.decodeFlexibleDateIfPresent(forKey: .resetsAt)
    }
}

private struct ClaudeEndpointLimitDTO: Codable, Sendable {
    var kind: String?
    var group: String?
    var percent: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        percent = container.decodeLossyDoubleIfPresent(forKey: .percent)
    }
}

private struct ClaudeStatusLineResponseDTO: Codable, Sendable {
    var fiveHour: ClaudeStatusLineWindowDTO?
    var sevenDay: ClaudeStatusLineWindowDTO?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeStatusLineWindowDTO: Codable, Sendable {
    var usedPercentage: Double?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        usedPercentage = container.decodeLossyDoubleIfPresent(forKey: .usedPercentage)
        resetsAt = container.decodeFlexibleDateIfPresent(forKey: .resetsAt)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return nil
        }

        if let value = try? decode(Double.self, forKey: key) {
            return value
        }

        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }

        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }

        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return nil
        }

        if let value = try? decode(Int.self, forKey: key) {
            return value
        }

        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }

        if let value = try? decode(String.self, forKey: key) {
            return Int(value)
        }

        return nil
    }

    func decodeFlexibleDateIfPresent(forKey key: Key) -> Date? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return nil
        }

        if let seconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }

        if let seconds = try? decode(Int.self, forKey: key) {
            return Date(timeIntervalSince1970: Double(seconds))
        }

        guard let value = try? decode(String.self, forKey: key) else {
            return nil
        }

        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }

        return parseISO8601Date(value)
    }
}

private func parseISO8601Date(_ value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    if let date = fractionalFormatter.date(from: value) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    return formatter.date(from: value)
}
