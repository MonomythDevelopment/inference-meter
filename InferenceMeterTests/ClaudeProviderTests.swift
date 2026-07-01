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

private func makeEndpointURL() -> URL {
    URL(string: "https://unit.test/oauth/usage/\(UUID().uuidString)")!
}

private actor RequestCapture {
    private(set) var request: URLRequest?

    func capture(_ request: URLRequest) {
        self.request = request
    }
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
    private nonisolated(unsafe) static let registry = HTTPStubRegistry()

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

private func keychainReturningCredential(accessToken: String = "unit-test-access-token") -> Keychain {
    Keychain { _, _ in
        Data(#"{"claudeAiOauth":{"accessToken":"\#(accessToken)"}}"#.utf8)
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
