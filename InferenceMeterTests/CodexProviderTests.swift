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

@Test("CodexProvider adopts Codex-rotated auth.json token without network refresh")
func codexProviderAdoptsRotatedAuthFileTokenWithoutNetworkRefresh() async throws {
    try await withTemporaryHome { home in
        let endpointURL = makeCodexEndpointURL()
        let tokenURL = makeCodexTokenURL()
        let tokenRequests = CodexRequestLog()
        let authSequence = AuthFileSequence([
            try codexAuthData(
                accessToken: "expired-access-token",
                refreshToken: "refresh-token",
                lastRefresh: "2026-07-01T00:00:00Z"
            ),
            try codexAuthData(
                accessToken: "rotated-access-token",
                refreshToken: "refresh-token",
                lastRefresh: "2026-07-01T00:05:00Z"
            )
        ])
        let session = makeCodexStubbedSession(for: endpointURL) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated-access-token" {
                return CodexHTTPStubResponse(data: Data(rateLimitsLine(fiveHourPct: 18, weeklyPct: 27).utf8), statusCode: 200)
            }

            return CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        }
        CodexStubURLProtocol.register(url: tokenURL) { request in
            await tokenRequests.append(request)
            return CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 200)
        }
        let provider = CodexProvider(
            homeDirectory: home,
            endpointConfiguration: CodexEndpointConfiguration(url: endpointURL),
            session: session,
            authFileReader: FileReader { _ in try authSequence.nextData() }
        )

        let firstUsage = await provider.refresh()
        await provider.reauthenticate()
        let retryUsage = await provider.refresh()

        #expect(firstUsage.state == .unauthorized)
        #expect(retryUsage.state == .ok)
        #expect(isClose(retryUsage.fiveHourPct, to: 18))
        #expect(authSequence.readCount == 3)
        #expect(await tokenRequests.requests.isEmpty)
    }
}

@Test("CodexProvider reauthentication never calls the auth-refresh endpoint when auth.json is unchanged")
func codexProviderReauthenticationDoesNotRefreshUnchangedAuthFile() async throws {
    try await withTemporaryHome { home in
        try writeAuthFile(
            home: home,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            lastRefresh: "2026-07-01T00:00:00Z"
        )
        let endpointURL = makeCodexEndpointURL()
        let tokenURL = makeCodexTokenURL()
        let endpointRequests = CodexRequestLog()
        let tokenRequests = CodexRequestLog()
        let session = makeCodexStubbedSession(for: endpointURL) { request in
            await endpointRequests.append(request)
            return CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        }
        CodexStubURLProtocol.register(url: tokenURL) { request in
            await tokenRequests.append(request)
            return CodexHTTPStubResponse(
                data: Data(#"{"access_token":"should-not-be-used"}"#.utf8),
                statusCode: 200
            )
        }
        let provider = CodexProvider(
            homeDirectory: home,
            endpointConfiguration: CodexEndpointConfiguration(url: endpointURL),
            session: session
        )

        let firstUsage = await provider.refresh()
        await provider.reauthenticate()
        let retryUsage = await provider.refresh()

        #expect(firstUsage.state == .unauthorized)
        #expect(retryUsage.state == .unauthorized)
        #expect(await endpointRequests.requests.count == 2)
        #expect(await tokenRequests.requests.isEmpty)
    }
}

@Test("CodexProvider retry stays unauthorized when auth.json is unchanged")
func codexProviderUnchangedAuthFileLeavesRetryUnauthorized() async throws {
    try await withTemporaryHome { home in
        try writeAuthFile(
            home: home,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            lastRefresh: "2026-07-01T00:00:00Z"
        )
        let endpointURL = makeCodexEndpointURL()
        let tokenURL = makeCodexTokenURL()
        let tokenRequests = CodexRequestLog()
        let session = makeCodexStubbedSession(for: endpointURL) { _ in
            CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        }
        CodexStubURLProtocol.register(url: tokenURL) { request in
            await tokenRequests.append(request)
            return CodexHTTPStubResponse(data: Data(#"{"access_token":"should-not-be-used"}"#.utf8), statusCode: 200)
        }
        let provider = CodexProvider(
            homeDirectory: home,
            endpointConfiguration: CodexEndpointConfiguration(url: endpointURL),
            session: session
        )

        let firstUsage = await provider.refresh()
        await provider.reauthenticate()
        let retryUsage = await provider.refresh()

        #expect(firstUsage.state == .unauthorized)
        #expect(retryUsage.state == .unauthorized)
        #expect(await tokenRequests.requests.isEmpty)
    }
}

@Test("CodexProvider does not emit auth sentinels during refresh and reauthenticate")
func codexProviderDoesNotEmitAuthSentinelsDuringRefreshAndReauthenticate() async throws {
    try await withTemporaryHome { home in
        let accessToken = "codex-access-sentinel-97E94A4F"
        let refreshToken = "codex-refresh-sentinel-7697D019"
        let tokenResponseSentinel = "codex-token-response-sentinel-C06D9390"
        try writeAuthFile(
            home: home,
            accessToken: accessToken,
            refreshToken: refreshToken,
            lastRefresh: "2026-07-01T00:00:00Z"
        )
        let endpointURL = makeCodexEndpointURL()
        let tokenURL = makeCodexTokenURL()
        let tokenRequests = CodexRequestLog()
        let session = makeCodexStubbedSession(for: endpointURL) { _ in
            CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        }
        CodexStubURLProtocol.register(url: tokenURL) { request in
            await tokenRequests.append(request)
            return CodexHTTPStubResponse(
                data: Data(#"{"access_token":"\#(tokenResponseSentinel)"}"#.utf8),
                statusCode: 200
            )
        }
        let provider = CodexProvider(
            homeDirectory: home,
            endpointConfiguration: CodexEndpointConfiguration(url: endpointURL),
            session: session
        )
        var firstUsage: Usage?
        var retryUsage: Usage?

        let output = try await captureStandardOutput {
            firstUsage = await provider.refresh()
            await provider.reauthenticate()
            retryUsage = await provider.refresh()
        }

        #expect(await tokenRequests.requests.isEmpty)
        expectNoSecretLeaks(
            output: output,
            usages: [try #require(firstUsage), try #require(retryUsage)],
            sentinels: [accessToken, refreshToken, tokenResponseSentinel]
        )
    }
}

@Test("CodexProvider endpoint unauthorized does not fall back to local rollout")
func codexProviderUnauthorizedEndpointDoesNotFallBackToLocalUsage() async throws {
    try await withTemporaryHome { home in
        try writeAuthFile(
            home: home,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            lastRefresh: "2026-07-01T00:00:00Z"
        )
        try writeRollout(home: home, contents: rateLimitsLine(fiveHourPct: 99, weeklyPct: 99))
        let endpointURL = makeCodexEndpointURL()
        let session = makeCodexStubbedSession(for: endpointURL) { _ in
            CodexHTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        }
        let provider = CodexProvider(
            homeDirectory: home,
            endpointConfiguration: CodexEndpointConfiguration(url: endpointURL),
            session: session
        )

        let usage = await provider.refresh()

        #expect(usage.state == .unauthorized)
        #expect(usage.source == .endpoint)
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

@discardableResult
private func writeAuthFile(
    home: URL,
    accessToken: String,
    refreshToken: String,
    lastRefresh: String
) throws -> URL {
    let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

    let fileURL = codexDirectory.appendingPathComponent("auth.json", isDirectory: false)
    try codexAuthData(
        accessToken: accessToken,
        refreshToken: refreshToken,
        lastRefresh: lastRefresh
    ).write(to: fileURL, options: .atomic)
    return fileURL
}

private func codexAuthData(
    accessToken: String,
    refreshToken: String,
    lastRefresh: String
) throws -> Data {
    try JSONEncoder().encode(
        CodexAuthFixture(
            tokens: CodexAuthFixture.Tokens(
                accessToken: accessToken,
                refreshToken: refreshToken
            ),
            lastRefresh: lastRefresh
        )
    )
}

private struct CodexAuthFixture: Encodable {
    var tokens: Tokens
    var lastRefresh: String

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
    }

    struct Tokens: Encodable {
        var accessToken: String
        var refreshToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }
}

private final class AuthFileSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data]
    private var readCounter = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounter
    }

    init(_ data: [Data]) {
        self.data = data
    }

    func nextData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        readCounter += 1
        guard data.count > 1 else {
            return data[0]
        }

        return data.removeFirst()
    }
}

private func makeCodexEndpointURL() -> URL {
    URL(string: "https://unit.test/codex/usage/\(UUID().uuidString)")!
}

private func makeCodexTokenURL() -> URL {
    URL(string: "https://unit.test/oauth/token/\(UUID().uuidString)")!
}

private actor CodexRequestLog {
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data?] = []

    func append(_ request: URLRequest) {
        requests.append(request)
        bodies.append(codexHTTPBodyData(from: request))
    }
}

private func codexHTTPBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count > 0 else {
            break
        }
        data.append(buffer, count: count)
    }

    return data
}

private struct CodexHTTPStubResponse {
    var data: Data
    var statusCode: Int
}

private final class CodexHTTPStubRegistry: @unchecked Sendable {
    typealias Handler = (URLRequest) async throws -> CodexHTTPStubResponse

    private let lock = NSLock()
    private var handlers: [URL: Handler] = [:]

    func register(url: URL, handler: @escaping Handler) {
        lock.lock()
        handlers[url] = handler
        lock.unlock()
    }

    func handler(for request: URLRequest) -> Handler? {
        guard let url = request.url else {
            return nil
        }

        lock.lock()
        let handler = handlers[url]
        lock.unlock()
        return handler
    }
}

private final class CodexStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = CodexHTTPStubRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Task {
            do {
                let stub = try await handler(request)
                let response = HTTPURLResponse(
                    url: request.url ?? makeCodexEndpointURL(),
                    statusCode: stub.statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stub.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    static func register(url: URL, handler: @escaping CodexHTTPStubRegistry.Handler) {
        registry.register(url: url, handler: handler)
    }
}

private func makeCodexStubbedSession(
    for url: URL,
    handler: @escaping (URLRequest) async throws -> CodexHTTPStubResponse
) -> URLSession {
    CodexStubURLProtocol.register(url: url, handler: handler)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexStubURLProtocol.self]
    return URLSession(configuration: configuration)
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
