import Foundation
import Testing
@testable import InferenceMeter

@Test("ClaudeProvider sends endpoint request and normalizes successful usage")
func claudeProviderReturnsEndpointUsage() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_000)
    let usageURL = makeEndpointURL()
    let requestCapture = RequestCapture()
    let session = makeStubbedSession(for: usageURL) { request in
        await requestCapture.capture(request)
        return HTTPStubResponse(
            data: try fixtureData(named: "claude-usage-response.json"),
            statusCode: 200
        )
    }
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: session,
        now: { parsedAt }
    )

    let usage = await provider.refresh()
    let request = await requestCapture.request

    #expect(request?.url == usageURL)
    #expect(request?.httpMethod == "GET")
    #expect(request?.timeoutInterval == 10)
    let authorizationValue = request?.value(forHTTPHeaderField: "Authorization")
    #expect(authorizationValue?.hasPrefix("Bearer ") == true)
    #expect(authorizationValue?.dropFirst("Bearer ".count).isEmpty == false)
    #expect(usage.provider == .claude)
    #expect(usage.source == .endpoint)
    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 15))
    #expect(isClose(usage.weeklyPct, to: 4))
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider keeps weekly endpoint usage when five_hour is absent")
func claudeProviderKeepsWeeklyEndpointUsageWhenFiveHourIsAbsent() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_025)
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in
            HTTPStubResponse(
                data: try fixtureData(named: "claude-usage-absent-five-hour.json"),
                statusCode: 200
            )
        },
        now: { parsedAt }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .ok)
    #expect(usage.source == .endpoint)
    #expect(usage.fiveHourPct == nil)
    #expect(isClose(usage.weeklyPct, to: 41))
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider treats endpoint usage with both windows absent as unavailable")
func claudeProviderTreatsEndpointUsageWithBothWindowsAbsentAsUnavailable() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_050)
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in
            HTTPStubResponse(
                data: try fixtureData(named: "claude-usage-absent-both.json"),
                statusCode: 200
            )
        },
        now: { parsedAt }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .unavailable)
    #expect(usage.source == .endpoint)
    #expect(usage.fiveHourPct == nil)
    #expect(usage.weeklyPct == nil)
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider maps 401 and 403 responses to unauthorized")
func claudeProviderMapsAuthFailuresToUnauthorized() async {
    for statusCode in [401, 403] {
        let parsedAt = Date(timeIntervalSince1970: 1_800_001_100 + Double(statusCode))
        let usageURL = makeEndpointURL()
        let provider = ClaudeProvider(
            keychain: keychainReturningCredential(),
            credentialService: "unit-test-service",
            credentialAccount: "unit-test-account",
            usageURL: usageURL,
            session: makeStubbedSession(for: usageURL) { _ in
                HTTPStubResponse(data: Data("{}".utf8), statusCode: statusCode)
            },
            now: { parsedAt }
        )

        let usage = await provider.refresh()

        #expect(usage.state == .unauthorized)
        #expect(usage.source == .endpoint)
        #expect(usage.fiveHourPct == nil)
        #expect(usage.weeklyPct == nil)
        #expect(usage.updatedAt == parsedAt)
    }
}

@Test("ClaudeProvider distinguishes an expired refreshable access token from logout")
func claudeProviderDistinguishesExpiredRefreshableAccessTokenFromLogout() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_100)
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            expiresAt: parsedAt.addingTimeInterval(-1).timeIntervalSince1970 * 1_000,
            refreshTokenExpiresAt: parsedAt.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
        ),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in
            HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        },
        now: { parsedAt }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .refreshRequired)
}

@Test("ClaudeProvider treats an expired refresh token as signed out")
func claudeProviderTreatsExpiredRefreshTokenAsSignedOut() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_100)
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(
            accessToken: "expired-access-token",
            refreshToken: "expired-refresh-token",
            expiresAt: parsedAt.addingTimeInterval(-10).timeIntervalSince1970 * 1_000,
            refreshTokenExpiresAt: parsedAt.addingTimeInterval(-1).timeIntervalSince1970 * 1_000
        ),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in
            HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
        },
        now: { parsedAt }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .unauthorized)
}

@Test("ClaudeProvider maps missing Keychain credential to unauthorized")
func claudeProviderMapsMissingKeychainCredentialToUnauthorized() async {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_200)
    let usageURL = makeEndpointURL()
    let requestCapture = RequestCapture()
    let provider = ClaudeProvider(
        keychain: Keychain { _, _ in throw KeychainError.itemNotFound },
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { request in
            await requestCapture.capture(request)
            return HTTPStubResponse(data: Data("{}".utf8), statusCode: 200)
        },
        now: { parsedAt }
    )

    let usage = await provider.refresh()
    let request = await requestCapture.request

    #expect(request == nil)
    #expect(usage.state == .unauthorized)
    #expect(usage.source == .endpoint)
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider does not emit credential sentinels during refresh and reauthenticate")
func claudeProviderDoesNotEmitCredentialSentinelsDuringRefreshAndReauthenticate() async throws {
    let usageURL = makeEndpointURL()
    let tokenURL = makeTokenURL()
    let tokenRequests = RequestLog()
    let accessToken = "claude-access-sentinel-7DF4960B"
    let refreshToken = "claude-refresh-sentinel-45F71DA6"
    let clientID = "claude-client-sentinel-D7C4AB73"
    let scope = "claude-scope-sentinel-61F3D5C3"
    let tokenResponseSentinel = "claude-token-response-sentinel-0C75D1F2"
    let session = makeStubbedSession(for: usageURL) { _ in
        HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
    }
    StubURLProtocol.register(url: tokenURL) { request in
        await tokenRequests.append(request)
        return HTTPStubResponse(
            data: Data(#"{"access_token":"\#(tokenResponseSentinel)"}"#.utf8),
            statusCode: 200
        )
    }
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientID: clientID,
            scopes: [scope]
        ),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
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
        sentinels: [accessToken, refreshToken, clientID, scope, tokenResponseSentinel]
    )
}

@Test("ClaudeProvider maps malformed credentials to unauthorized")
func claudeProviderMapsMalformedCredentialToUnauthorized() async {
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: Keychain { _, _ in Data("{}".utf8) },
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in
            HTTPStubResponse(data: Data("{}".utf8), statusCode: 200)
        }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .unauthorized)
    #expect(usage.fiveHourPct == nil)
    #expect(usage.weeklyPct == nil)
}

@Test("ClaudeProvider maps network failure to unavailable without fallback by default")
func claudeProviderMapsNetworkFailureToUnavailable() async {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_300)
    let usageURL = makeEndpointURL()
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: makeStubbedSession(for: usageURL) { _ in throw URLError(.timedOut) },
        now: { parsedAt }
    )

    let usage = await provider.refresh()

    #expect(usage.state == .unavailable)
    #expect(usage.source == .endpoint)
    #expect(usage.fiveHourPct == nil)
    #expect(usage.weeklyPct == nil)
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider uses statusLine fallback only when explicitly enabled")
func claudeProviderUsesStatusLineFallbackOnlyWhenEnabled() async throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_400)
    let disabledUsageURL = makeEndpointURL()
    let enabledUsageURL = makeEndpointURL()
    let fallbackFileURL = try writeTemporaryStatusLineFixture()
    defer {
        try? FileManager.default.removeItem(at: fallbackFileURL)
    }

    let disabledProvider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: disabledUsageURL,
        session: makeStubbedSession(for: disabledUsageURL) { _ in throw URLError(.timedOut) },
        statusLineFallback: .disabled,
        now: { parsedAt }
    )
    let enabledProvider = ClaudeProvider(
        keychain: keychainReturningCredential(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: enabledUsageURL,
        session: makeStubbedSession(for: enabledUsageURL) { _ in throw URLError(.timedOut) },
        statusLineFallback: .enabled(fileURL: fallbackFileURL),
        now: { parsedAt }
    )

    let disabledUsage = await disabledProvider.refresh()
    let enabledUsage = await enabledProvider.refresh()

    #expect(disabledUsage.state == .unavailable)
    #expect(disabledUsage.source == .endpoint)
    #expect(enabledUsage.state == .ok)
    #expect(enabledUsage.source == .localFile)
    #expect(isClose(enabledUsage.fiveHourPct, to: 23.5))
    #expect(isClose(enabledUsage.weeklyPct, to: 81.25))
}

@Test("ClaudeProvider statusLine parser reads used_percentage fixture")
func claudeProviderStatusLineParserReadsUsedPercentageFixture() throws {
    let parsedAt = Date(timeIntervalSince1970: 1_800_001_500)
    let usage = try ClaudeProvider.parseStatusLine(
        try fixtureData(named: "claude-statusline.json"),
        parsedAt: parsedAt
    )

    #expect(usage.provider == .claude)
    #expect(usage.source == .localFile)
    #expect(usage.state == .ok)
    #expect(isClose(usage.fiveHourPct, to: 23.5))
    #expect(isClose(usage.weeklyPct, to: 81.25))
    #expect(usage.updatedAt == parsedAt)
}

@Test("ClaudeProvider reauthentication never calls the token endpoint when credential is unchanged")
func claudeProviderReauthenticationDoesNotRefreshUnchangedCredential() async throws {
    let usageURL = makeEndpointURL()
    let tokenURL = makeTokenURL()
    let usageRequests = RequestLog()
    let tokenRequests = RequestLog()
    let session = makeStubbedSession(for: usageURL) { request in
        await usageRequests.append(request)
        return HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
    }
    StubURLProtocol.register(url: tokenURL) { request in
        await tokenRequests.append(request)
        return HTTPStubResponse(data: Data(#"{"access_token":"should-not-be-used"}"#.utf8), statusCode: 200)
    }
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            clientID: "unit-test-client"
        ),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: session
    )

    let firstUsage = await provider.refresh()
    let didAdoptCredential = await provider.reauthenticate()
    let retryUsage = await provider.refresh()

    #expect(firstUsage.state == .unauthorized)
    #expect(retryUsage.state == .unauthorized)
    #expect(!didAdoptCredential)
    #expect(await usageRequests.requests.count == 2)
    #expect(await tokenRequests.requests.isEmpty)
}

@Test("ClaudeProvider adopts a rotated Keychain token without network refresh")
func claudeProviderAdoptsRotatedKeychainTokenWithoutNetworkRefresh() async throws {
    let usageURL = makeEndpointURL()
    let tokenURL = makeTokenURL()
    let tokenRequests = RequestLog()
    let refreshInvocations = RefreshInvocationRecorder()
    let keychainSequence = CredentialSequence([
        try claudeCredentialData(accessToken: "expired-access-token", refreshToken: "refresh-token"),
        try claudeCredentialData(accessToken: "rotated-access-token", refreshToken: "refresh-token")
    ])
    let session = makeStubbedSession(for: usageURL) { request in
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated-access-token" {
            return HTTPStubResponse(
                data: try fixtureData(named: "claude-usage-response.json"),
                statusCode: 200
            )
        }

        return HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
    }
    StubURLProtocol.register(url: tokenURL) { request in
        await tokenRequests.append(request)
        return HTTPStubResponse(data: Data("{}".utf8), statusCode: 200)
    }
    let provider = ClaudeProvider(
        keychain: keychainSequence.keychain(),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: session,
        credentialOwnerRefresher: ClaudeCredentialOwnerRefresher {
            await refreshInvocations.record()
        }
    )

    let firstUsage = await provider.refresh()
    let didAdoptCredential = await provider.reauthenticate()
    let retryUsage = await provider.refresh()

    #expect(firstUsage.state == .unauthorized)
    #expect(retryUsage.state == .ok)
    #expect(didAdoptCredential)
    #expect(keychainSequence.readCount == 3)
    #expect(await refreshInvocations.count == 1)
    #expect(await tokenRequests.requests.isEmpty)
}

@Test("ClaudeProvider retry stays unauthorized when credential is unchanged")
func claudeProviderUnchangedCredentialLeavesRetryUnauthorized() async throws {
    let usageURL = makeEndpointURL()
    let tokenURL = makeTokenURL()
    let tokenRequests = RequestLog()
    let session = makeStubbedSession(for: usageURL) { _ in
        HTTPStubResponse(data: Data("{}".utf8), statusCode: 401)
    }
    StubURLProtocol.register(url: tokenURL) { request in
        await tokenRequests.append(request)
        return HTTPStubResponse(data: Data(#"{"access_token":"should-not-be-used"}"#.utf8), statusCode: 200)
    }
    let provider = ClaudeProvider(
        keychain: keychainReturningCredential(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token"
        ),
        credentialService: "unit-test-service",
        credentialAccount: "unit-test-account",
        usageURL: usageURL,
        session: session
    )

    let firstUsage = await provider.refresh()
    let didAdoptCredential = await provider.reauthenticate()
    let retryUsage = await provider.refresh()

    #expect(firstUsage.state == .unauthorized)
    #expect(retryUsage.state == .unauthorized)
    #expect(!didAdoptCredential)
    #expect(await tokenRequests.requests.isEmpty)
}

private func makeEndpointURL() -> URL {
    URL(string: "https://unit.test/oauth/usage/\(UUID().uuidString)")!
}

private func makeTokenURL() -> URL {
    URL(string: "https://unit.test/oauth/token/\(UUID().uuidString)")!
}

private actor RequestCapture {
    private(set) var request: URLRequest?

    func capture(_ request: URLRequest) {
        self.request = request
    }
}

private actor RequestLog {
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data?] = []

    func append(_ request: URLRequest) {
        requests.append(request)
        bodies.append(httpBodyData(from: request))
    }
}

private actor RefreshInvocationRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private func httpBodyData(from request: URLRequest) -> Data? {
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

private struct HTTPStubResponse {
    var data: Data
    var statusCode: Int
}

private final class HTTPStubRegistry: @unchecked Sendable {
    typealias Handler = (URLRequest) async throws -> HTTPStubResponse

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

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = HTTPStubRegistry()

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
                    url: request.url ?? makeEndpointURL(),
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

    static func register(url: URL, handler: @escaping HTTPStubRegistry.Handler) {
        registry.register(url: url, handler: handler)
    }
}

private func makeStubbedSession(
    for url: URL,
    handler: @escaping (URLRequest) async throws -> HTTPStubResponse
) -> URLSession {
    StubURLProtocol.register(url: url, handler: handler)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func keychainReturningCredential(
    accessToken: String = "unit-test-access-token",
    refreshToken: String? = nil,
    expiresAt: Double? = nil,
    refreshTokenExpiresAt: Double? = nil,
    clientID: String? = nil,
    scopes: [String]? = nil
) -> Keychain {
    Keychain { _, _ in
        try claudeCredentialData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            clientID: clientID,
            scopes: scopes
        )
    }
}

private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [Data]
    private var readCounter = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounter
    }

    init(_ credentials: [Data]) {
        self.credentials = credentials
    }

    func keychain() -> Keychain {
        Keychain { _, _ in
            self.nextCredential()
        }
    }

    private func nextCredential() -> Data {
        lock.lock()
        defer { lock.unlock() }

        readCounter += 1
        guard credentials.count > 1 else {
            return credentials[0]
        }

        return credentials.removeFirst()
    }
}

private func claudeCredentialData(
    accessToken: String,
    refreshToken: String? = nil,
    expiresAt: Double? = nil,
    refreshTokenExpiresAt: Double? = nil,
    clientID: String? = nil,
    scopes: [String]? = nil
) throws -> Data {
    try JSONEncoder().encode(
        ClaudeCredentialFixture(
            claudeAiOauth: ClaudeCredentialFixture.OAuth(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                refreshTokenExpiresAt: refreshTokenExpiresAt,
                clientID: clientID,
                scopes: scopes
            )
        )
    )
}

private struct ClaudeCredentialFixture: Encodable {
    var claudeAiOauth: OAuth

    struct OAuth: Encodable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Double?
        var refreshTokenExpiresAt: Double?
        var clientID: String?
        var scopes: [String]?

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case expiresAt
            case refreshTokenExpiresAt
            case clientID = "clientId"
            case scopes
        }
    }
}

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

private func writeTemporaryStatusLineFixture() throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("inference-meter-statusline-\(UUID().uuidString).json")

    try fixtureData(named: "claude-statusline.json").write(to: fileURL, options: .atomic)
    return fileURL
}

private func isClose(_ actual: Double?, to expected: Double) -> Bool {
    guard let actual else {
        return false
    }

    return abs(actual - expected) < 0.000_001
}
