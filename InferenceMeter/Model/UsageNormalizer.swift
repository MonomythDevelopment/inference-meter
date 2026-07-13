import Foundation

enum UsageNormalizer {
    static func codexAppServerRateLimits(
        from data: Data,
        parsedAt: Date = Date()
    ) -> Usage {
        let decoder = JSONDecoder()

        guard let response = try? decoder.decode(CodexAppServerRateLimitsResponseDTO.self, from: data),
              let result = response.result else {
            return unavailableUsage(provider: .codex, source: .commandLine, parsedAt: parsedAt)
        }

        guard let rateLimits = result.rateLimitsByLimitID?["codex"] ?? result.rateLimits else {
            return unavailableUsage(provider: .codex, source: .commandLine, parsedAt: parsedAt)
        }

        return codexUsage(
            windows: [rateLimits.primary, rateLimits.secondary].compactMap { $0 },
            parsedAt: parsedAt,
            source: .commandLine,
            rejectsExpiredWindows: true
        )
    }

    static func codexRateLimits(
        from data: Data,
        source: UsageSource = .localFile,
        parsedAt: Date = Date()
    ) -> Usage {
        guard let rateLimits = decodeCodexRateLimits(from: data) else {
            return unavailableUsage(provider: .codex, source: source, parsedAt: parsedAt)
        }

        return codexUsage(
            windows: [rateLimits.primary, rateLimits.secondary].compactMap { $0 },
            parsedAt: parsedAt,
            source: source,
            rejectsExpiredWindows: false
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
        let fableLimit = matchingScopedEndpointLimit(named: "Fable", in: response.limits)

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
            source: .endpoint,
            fablePct: fableLimit?.percent.map(clampPercentage),
            fableResetsAt: fableLimit?.resetsAt
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

    static func codexUsage(
        windows: [CodexRateLimitWindow],
        parsedAt: Date,
        source: UsageSource,
        rejectsExpiredWindows: Bool
    ) -> Usage {
        var fiveHourPct: Double?
        var weeklyPct: Double?
        var fiveHourResetsAt: Date?
        var weeklyResetsAt: Date?

        for window in windows {
            if rejectsExpiredWindows,
               let resetsAt = window.resetsAt,
               resetsAt <= parsedAt {
                continue
            }

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

        if let searchResult = try? decoder.decode(CodexRateLimitsSearchDTO.self, from: data),
           let rateLimits = searchResult.rateLimits {
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

            if let searchResult = try? decoder.decode(CodexRateLimitsSearchDTO.self, from: lineData),
               let rateLimits = searchResult.rateLimits {
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

    static func matchingScopedEndpointLimit(
        named modelName: String,
        in limits: [ClaudeEndpointLimitDTO]
    ) -> ClaudeEndpointLimitDTO? {
        limits.first { limit in
            guard limit.kind == "weekly_scoped",
                  let displayName = limit.scope?.model?.displayName else {
                return false
            }

            return displayName.localizedCaseInsensitiveContains(modelName)
        }
    }

    static func usage(
        provider: Provider,
        fiveHourPct: Double?,
        weeklyPct: Double?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        updatedAt: Date?,
        source: UsageSource,
        fablePct: Double? = nil,
        fableResetsAt: Date? = nil
    ) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: updatedAt,
            source: source,
            state: fiveHourPct == nil && weeklyPct == nil && fablePct == nil ? .unavailable : .ok,
            fablePct: fablePct,
            fableResetsAt: fableResetsAt
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

private struct CodexRateLimitsSearchDTO: Decodable, Sendable {
    var rateLimits: CodexRateLimitsDTO?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            let rateLimitsKey = DynamicCodingKey(stringValue: "rate_limits")

            if let rateLimitsKey,
               let rateLimits = try? container.decode(CodexRateLimitsDTO.self, forKey: rateLimitsKey),
               rateLimits.hasWindow {
                self.rateLimits = rateLimits
                return
            }

            for key in container.allKeys {
                if let nested = try? container.decode(CodexRateLimitsSearchDTO.self, forKey: key),
                   let rateLimits = nested.rateLimits {
                    self.rateLimits = rateLimits
                    return
                }
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                if let nested = try? container.decode(CodexRateLimitsSearchDTO.self),
                   let rateLimits = nested.rateLimits {
                    self.rateLimits = rateLimits
                    return
                }
            }
        }

        rateLimits = nil
    }
}

private protocol CodexRateLimitWindow {
    var usedPercent: Double? { get }
    var windowMinutes: Int? { get }
    var resetsAt: Date? { get }
}

private struct CodexRateLimitWindowDTO: Codable, Sendable, CodexRateLimitWindow {
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

private struct CodexAppServerRateLimitsResponseDTO: Decodable, Sendable {
    var result: CodexAppServerRateLimitsResultDTO?
}

private struct CodexAppServerRateLimitsResultDTO: Decodable, Sendable {
    var rateLimits: CodexAppServerRateLimitSnapshotDTO?
    var rateLimitsByLimitID: [String: CodexAppServerRateLimitSnapshotDTO]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }
}

private struct CodexAppServerRateLimitSnapshotDTO: Decodable, Sendable {
    var primary: CodexAppServerRateLimitWindowDTO?
    var secondary: CodexAppServerRateLimitWindowDTO?
}

private struct CodexAppServerRateLimitWindowDTO: Decodable, Sendable, CodexRateLimitWindow {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowMinutes = "windowDurationMins"
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        usedPercent = container.decodeLossyDoubleIfPresent(forKey: .usedPercent)
        windowMinutes = container.decodeLossyIntIfPresent(forKey: .windowMinutes)
        resetsAt = container.decodeFlexibleDateIfPresent(forKey: .resetsAt)
    }
}

private struct DynamicCodingKey: CodingKey, Sendable {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
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
    var resetsAt: Date?
    var scope: ClaudeEndpointLimitScopeDTO?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        percent = container.decodeLossyDoubleIfPresent(forKey: .percent)
        resetsAt = container.decodeFlexibleDateIfPresent(forKey: .resetsAt)
        scope = try container.decodeIfPresent(ClaudeEndpointLimitScopeDTO.self, forKey: .scope)
    }
}

private struct ClaudeEndpointLimitScopeDTO: Codable, Sendable {
    var model: ClaudeEndpointLimitModelDTO?
}

private struct ClaudeEndpointLimitModelDTO: Codable, Sendable {
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
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
