import Foundation

struct CodexEndpointConfiguration: Sendable, Equatable {
    var url: URL
    var additionalHeaders: [String: String]

    init(url: URL, additionalHeaders: [String: String] = [:]) {
        self.url = url
        self.additionalHeaders = additionalHeaders
    }
}

struct CodexProvider: UsageProvider {
    let provider: Provider = .codex

    private let homeDirectory: URL
    private let endpointConfiguration: CodexEndpointConfiguration?
    private let session: URLSession
    private let authFileReader: FileReader
    private let tokenStore: TokenStore
    private let appServerClient: CodexAppServerClient?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        endpointConfiguration: CodexEndpointConfiguration? = nil,
        session: URLSession = .shared,
        authFileReader: FileReader = FileReader(),
        tokenStore: TokenStore = TokenStore(),
        appServerClient: CodexAppServerClient? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.endpointConfiguration = endpointConfiguration
        self.session = session
        self.authFileReader = authFileReader
        self.tokenStore = tokenStore
        self.appServerClient = appServerClient ?? Self.defaultAppServerClient(
            homeDirectory: homeDirectory
        )
    }

    func refresh() async -> Usage {
        guard endpointConfiguration == nil else {
            let endpointUsage = await refreshFromEndpoint()
            guard endpointUsage.state != .ok else {
                return endpointUsage
            }

            guard endpointUsage.state != .unauthorized else {
                return endpointUsage
            }

            let localUsage = refreshFromLocalFile()
            if localUsage.state == .ok {
                return localUsage
            }

            return localUsage
        }

        if let appServerData = await appServerClient?.fetchRateLimits() {
            let appServerUsage = UsageNormalizer.codexAppServerRateLimits(from: appServerData)

            if appServerUsage.state == .ok {
                return appServerUsage
            }
        }

        return refreshFromLocalFile()
    }

    private static func defaultAppServerClient(homeDirectory: URL) -> CodexAppServerClient? {
        guard homeDirectory.standardizedFileURL
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL else {
            return nil
        }

        return .live(homeDirectory: homeDirectory)
    }

    func reauthenticate() async -> Bool {
        guard endpointConfiguration != nil else {
            return false
        }

        // Read-only monitor: never perform an OAuth refresh_token exchange. OpenAI
        // rotates the shared refresh token on use, which would invalidate the copy the
        // Codex CLI stores in ~/.codex/auth.json and force the CLI to re-login. We only
        // adopt a token the CLI itself has already refreshed on disk.
        guard let authSnapshot = try? readAuthTokenSnapshot() else {
            return false
        }
        return await tokenStore.adoptOwnerTokenIfChanged(authSnapshot.ownerSnapshot)
    }
}

private extension CodexProvider {
    static let chunkSize = 64 * 1024
    static let maxRecentRolloutFiles = 20
    static let newlineByte: UInt8 = 10
    static let carriageReturnByte: UInt8 = 13
    static let rateLimitsNeedle = Data(#""rate_limits""#.utf8)

    var codexDirectory: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    var sessionsDirectory: URL {
        codexDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    var authFileURL: URL {
        codexDirectory.appendingPathComponent("auth.json", isDirectory: false)
    }

    func refreshFromLocalFile() -> Usage {
        guard let rolloutURLs = try? recentRolloutFiles(), !rolloutURLs.isEmpty else {
            return unavailableUsage(source: .localFile)
        }

        var accumulator = CodexUsageAccumulator()

        for rolloutURL in rolloutURLs {
            guard let fileModificationDate = modificationDate(for: rolloutURL),
                  let usage = try? lastRateLimitsUsage(
                    in: rolloutURL,
                    fileModificationDate: fileModificationDate
                  ) else {
                continue
            }

            accumulator.merge(usage)

            if accumulator.isComplete {
                break
            }
        }

        return accumulator.usage ?? unavailableUsage(source: .localFile)
    }

    func recentRolloutFiles(limit: Int = Self.maxRecentRolloutFiles) throws -> [URL] {
        guard directoryExists(at: sessionsDirectory) else {
            return []
        }

        var rolloutURLs: [URL] = []

        for yearURL in try sortedDirectories(in: sessionsDirectory, matching: { isDigits($0, count: 4) }) {
            for monthURL in try sortedDirectories(in: yearURL, matching: { isDigits($0, count: 2) }) {
                for dayURL in try sortedDirectories(in: monthURL, matching: { isDigits($0, count: 2) }) {
                    rolloutURLs.append(contentsOf: try rolloutFiles(in: dayURL))

                    if rolloutURLs.count >= limit {
                        return Array(rolloutURLs.prefix(limit))
                    }
                }
            }
        }

        return rolloutURLs
    }

    func sortedDirectories(in directory: URL, matching predicate: (String) -> Bool) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard predicate(url.lastPathComponent) else {
                    return false
                }

                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { compareSessionPathComponent($0.lastPathComponent, $1.lastPathComponent) }
    }

    func rolloutFiles(in dayDirectory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                url.lastPathComponent.hasPrefix("rollout-")
                    && url.pathExtension == "jsonl"
                    && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
            }
            .sorted {
                let lhsDate = modificationDate(for: $0) ?? .distantPast
                let rhsDate = modificationDate(for: $1) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    func lastRateLimitsUsage(in fileURL: URL, fileModificationDate: Date) throws -> Usage? {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset = try fileHandle.seekToEnd()
        var pendingPrefix = Data()
        var accumulator = CodexUsageAccumulator()

        while offset > 0 {
            let readSize = min(Self.chunkSize, Int(offset))
            offset -= UInt64(readSize)

            try fileHandle.seek(toOffset: offset)

            var buffer = try fileHandle.read(upToCount: readSize) ?? Data()
            buffer.append(pendingPrefix)

            guard let firstNewlineIndex = buffer.firstIndex(of: Self.newlineByte) else {
                pendingPrefix = buffer
                continue
            }

            let completeStart = offset == 0
                ? buffer.startIndex
                : buffer.index(after: firstNewlineIndex)
            let completeData = buffer[completeStart..<buffer.endIndex]

            mergeRateLimitsUsage(
                inCompleteLines: completeData,
                fileModificationDate: fileModificationDate,
                accumulator: &accumulator
            )

            if accumulator.isComplete {
                return accumulator.usage
            }

            pendingPrefix = offset == 0
                ? Data()
                : Data(buffer[buffer.startIndex..<firstNewlineIndex])
        }

        if !pendingPrefix.isEmpty,
           let usage = usage(fromCandidateLine: pendingPrefix, fileModificationDate: fileModificationDate) {
            accumulator.merge(usage)
        }

        return accumulator.usage
    }

    func mergeRateLimitsUsage(
        inCompleteLines linesData: Data.SubSequence,
        fileModificationDate: Date,
        accumulator: inout CodexUsageAccumulator
    ) {
        for line in linesData.split(separator: Self.newlineByte, omittingEmptySubsequences: true).reversed() {
            if let usage = usage(fromCandidateLine: Data(line), fileModificationDate: fileModificationDate) {
                accumulator.merge(usage)

                if accumulator.isComplete {
                    return
                }
            }
        }
    }

    func usage(fromCandidateLine lineData: Data, fileModificationDate: Date) -> Usage? {
        let trimmedLineData = trimLineEnding(from: lineData)

        guard trimmedLineData.range(of: Self.rateLimitsNeedle) != nil else {
            return nil
        }

        let updatedAt = eventTimestamp(from: trimmedLineData) ?? fileModificationDate
        let usage = UsageNormalizer.codexRateLimits(
            from: trimmedLineData,
            source: .localFile,
            parsedAt: updatedAt
        )

        return usage.state == .unavailable ? nil : usage
    }

    func refreshFromEndpoint() async -> Usage {
        guard let endpointConfiguration else {
            return unavailableUsage(source: .endpoint)
        }

        guard let authSnapshot = try? readAuthTokenSnapshot() else {
            return unauthorizedUsage(source: .endpoint)
        }
        let accessToken = await tokenStore.accessToken(for: authSnapshot.ownerSnapshot)

        return await requestEndpoint(
            endpointConfiguration,
            accessToken: accessToken
        )
    }

    func requestEndpoint(
        _ configuration: CodexEndpointConfiguration,
        accessToken: String
    ) async -> Usage {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        for (field, value) in configuration.additionalHeaders {
            guard field.caseInsensitiveCompare("Authorization") != .orderedSame else {
                continue
            }

            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return unavailableUsage(source: .endpoint)
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return unauthorizedUsage(source: .endpoint)
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return unavailableUsage(source: .endpoint)
            }

            let usage = UsageNormalizer.codexRateLimits(
                from: data,
                source: .endpoint,
                parsedAt: Date()
            )

            return usage.state == .unavailable ? unavailableUsage(source: .endpoint) : usage
        } catch {
            return unavailableUsage(source: .endpoint)
        }
    }

    func readAuthTokenSnapshot() throws -> CodexAuthTokenSnapshot? {
        let data = try authFileReader.data(contentsOf: authFileURL)
        let authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard let accessToken = authFile.tokens?.accessToken?.nonEmpty else {
            return nil
        }

        return CodexAuthTokenSnapshot(
            accessToken: accessToken,
            refreshToken: authFile.tokens?.refreshToken?.nonEmpty,
            lastRefresh: authFile.lastRefresh
        )
    }

    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func compareSessionPathComponent(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsNumber = Int(lhs),
           let rhsNumber = Int(rhs),
           lhsNumber != rhsNumber {
            return lhsNumber > rhsNumber
        }

        return lhs > rhs
    }

    func isDigits(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy(\.isNumber)
    }

    func trimLineEnding(from data: Data) -> Data {
        var trimmed = data

        while trimmed.last == Self.newlineByte || trimmed.last == Self.carriageReturnByte {
            trimmed.removeLast()
        }

        return trimmed
    }

    func eventTimestamp(from data: Data) -> Date? {
        try? JSONDecoder().decode(CodexEventTimestamp.self, from: data).timestamp
    }

    func unavailableUsage(source: UsageSource) -> Usage {
        Usage(
            provider: .codex,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: nil,
            source: source,
            state: .unavailable
        )
    }

    func unauthorizedUsage(source: UsageSource) -> Usage {
        Usage(
            provider: .codex,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: nil,
            source: source,
            state: .unauthorized
        )
    }
}

private struct CodexUsageAccumulator {
    private static let untimestampedWindowMergeHorizon: TimeInterval = 300

    private var fiveHourPct: Double?
    private var weeklyPct: Double?
    private var fiveHourResetsAt: Date?
    private var weeklyResetsAt: Date?
    private var updatedAt: Date?
    private var source: UsageSource = .localFile

    var isComplete: Bool {
        fiveHourPct != nil && weeklyPct != nil
    }

    var usage: Usage? {
        guard fiveHourPct != nil || weeklyPct != nil else {
            return nil
        }

        return Usage(
            provider: .codex,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: updatedAt,
            source: source,
            state: .ok
        )
    }

    mutating func merge(_ usage: Usage) {
        if updatedAt == nil {
            updatedAt = usage.updatedAt
            source = usage.source
        }

        if fiveHourPct == nil,
           let percentage = usage.fiveHourPct,
           isCurrentWindow(resetsAt: usage.fiveHourResetsAt, observedAt: usage.updatedAt) {
            fiveHourPct = percentage
            fiveHourResetsAt = usage.fiveHourResetsAt
        }

        if weeklyPct == nil,
           let percentage = usage.weeklyPct,
           isCurrentWindow(resetsAt: usage.weeklyResetsAt, observedAt: usage.updatedAt) {
            weeklyPct = percentage
            weeklyResetsAt = usage.weeklyResetsAt
        }
    }

    private func isCurrentWindow(resetsAt: Date?, observedAt: Date?) -> Bool {
        guard let updatedAt else {
            return true
        }

        if let resetsAt,
           resetsAt <= (observedAt ?? updatedAt) {
            return false
        }

        if observedAt == updatedAt {
            return true
        }

        if let resetsAt {
            return resetsAt > updatedAt
        }

        guard let observedAt else {
            return true
        }

        return updatedAt.timeIntervalSince(observedAt) <= Self.untimestampedWindowMergeHorizon
    }
}

private struct CodexAuthTokenSnapshot: Sendable {
    var accessToken: String
    var refreshToken: String?
    var lastRefresh: Date?

    var ownerSnapshot: OwnerTokenSnapshot {
        OwnerTokenSnapshot(accessToken: accessToken, refreshedAt: lastRefresh, refreshToken: refreshToken)
    }
}

private struct CodexAuthFile: Decodable, Sendable {
    var tokens: CodexAuthTokens?
    var lastRefresh: Date?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent(CodexAuthTokens.self, forKey: .tokens)
        lastRefresh = container.decodeFlexibleDateIfPresent(forKey: .lastRefresh)
    }
}

private struct CodexAuthTokens: Decodable, Sendable {
    var accessToken: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct CodexEventTimestamp: Decodable, Sendable {
    var timestamp: Date?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case ts
        case time
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        timestamp = container.decodeFlexibleDateIfPresent(forKey: .timestamp)
            ?? container.decodeFlexibleDateIfPresent(forKey: .ts)
            ?? container.decodeFlexibleDateIfPresent(forKey: .time)
            ?? container.decodeFlexibleDateIfPresent(forKey: .createdAt)
    }
}

private extension KeyedDecodingContainer {
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

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
