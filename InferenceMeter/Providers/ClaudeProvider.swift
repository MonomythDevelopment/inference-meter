import Foundation

struct ClaudeCredentialOwnerRefresher: Sendable {
    private let refreshHandler: @Sendable () async -> Void

    init(refresh: @escaping @Sendable () async -> Void) {
        refreshHandler = refresh
    }

    func refresh() async {
        await refreshHandler()
    }

    static let live = ClaudeCredentialOwnerRefresher {
        await Task.detached {
            guard let executableURL = claudeExecutableURL() else {
                return
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["auth", "status", "--json"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
        }.value
    }

    static let noOp = ClaudeCredentialOwnerRefresher {}
}

struct ClaudeProvider: UsageProvider {
    enum StatusLineFallback: Sendable, Equatable {
        case disabled
        case enabled(fileURL: URL)
    }

    static let defaultCredentialService = "Claude Code-credentials"
    static let defaultUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let defaultStatusLineFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/inference-meter-status.json")

    let provider = Provider.claude

    private let keychain: Keychain
    private let credentialService: String
    private let credentialAccount: String
    private let usageURL: URL
    private let session: URLSession
    private let statusLineFallback: StatusLineFallback
    private let tokenStore: TokenStore
    private let credentialOwnerRefresher: ClaudeCredentialOwnerRefresher
    private let now: @Sendable () -> Date

    init(
        keychain: Keychain = Keychain(),
        credentialService: String = ClaudeProvider.defaultCredentialService,
        credentialAccount: String = NSUserName(),
        usageURL: URL = ClaudeProvider.defaultUsageURL,
        session: URLSession = .shared,
        statusLineFallback: StatusLineFallback = .disabled,
        tokenStore: TokenStore = TokenStore(),
        credentialOwnerRefresher: ClaudeCredentialOwnerRefresher = .noOp,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.credentialService = credentialService
        self.credentialAccount = credentialAccount
        self.usageURL = usageURL
        self.session = session
        self.statusLineFallback = statusLineFallback
        self.tokenStore = tokenStore
        self.credentialOwnerRefresher = credentialOwnerRefresher
        self.now = now
    }

    func refresh() async -> Usage {
        let parsedAt = now()

        do {
            let credential = try readCredential()
            let accessToken = await tokenStore.accessToken(for: credential.ownerSnapshot)
            let (data, response) = try await session.data(for: endpointRequest(accessToken: accessToken))

            guard let httpResponse = response as? HTTPURLResponse else {
                return fallbackOrUnavailable(parsedAt: parsedAt)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return UsageNormalizer.claudeEndpoint(from: data, parsedAt: parsedAt)
            case 401, 403:
                return authorizationFailureUsage(credential: credential, parsedAt: parsedAt)
            default:
                return fallbackOrUnavailable(parsedAt: parsedAt)
            }
        } catch KeychainError.itemNotFound {
            return unauthorizedUsage(parsedAt: parsedAt)
        } catch is ClaudeCredentialError {
            return unauthorizedUsage(parsedAt: parsedAt)
        } catch {
            return fallbackOrUnavailable(parsedAt: parsedAt)
        }
    }

    func reauthenticate() async -> Bool {
        // Ask Claude Code to inspect its own auth state so any renewal remains owned
        // by the CLI. Inference Meter never reads the refresh token into a request and
        // never writes the shared Keychain credential.
        await credentialOwnerRefresher.refresh()

        guard let credential = try? readCredential() else {
            return false
        }
        return await tokenStore.adoptOwnerTokenIfChanged(credential.ownerSnapshot)
    }

    static func parseStatusLine(_ data: Data, parsedAt: Date = Date()) throws -> Usage {
        let usage = UsageNormalizer.claudeStatusLine(from: data, parsedAt: parsedAt)

        guard usage.state != .unavailable else {
            throw ClaudeStatusLineError.unusablePayload
        }

        return usage
    }
}

private extension ClaudeProvider {
    enum ClaudeCredentialError: Error, Sendable {
        case invalidCredential
        case missingAccessToken
    }

    enum ClaudeStatusLineError: Error, Sendable {
        case unusablePayload
    }

    func readCredential() throws -> ClaudeCredential {
        let credentialData = try keychain.readGenericPassword(
            service: credentialService,
            account: credentialAccount
        )
        return try decodeCredential(from: credentialData)
    }

    func endpointRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    func decodeCredential(from data: Data) throws -> ClaudeCredential {
        do {
            let credential = try JSONDecoder().decode(ClaudeCodeCredential.self, from: data)
            let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !token.isEmpty else {
                throw ClaudeCredentialError.missingAccessToken
            }

            return ClaudeCredential(
                accessToken: token,
                refreshToken: credential.refreshToken.nonEmpty,
                expiresAt: credential.expiresAt.map(millisecondsSince1970Date),
                refreshTokenExpiresAt: credential.refreshTokenExpiresAt.map(millisecondsSince1970Date),
                clientID: credential.clientID.nonEmpty,
                scopes: credential.scopes
            )
        } catch is ClaudeCredentialError {
            throw ClaudeCredentialError.missingAccessToken
        } catch {
            throw ClaudeCredentialError.invalidCredential
        }
    }

    func fallbackOrUnavailable(parsedAt: Date) -> Usage {
        guard case let .enabled(fileURL) = statusLineFallback else {
            return unavailableUsage(parsedAt: parsedAt)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try ClaudeProvider.parseStatusLine(data, parsedAt: parsedAt)
        } catch {
            return unavailableUsage(parsedAt: parsedAt)
        }
    }

    func unauthorizedUsage(parsedAt: Date) -> Usage {
        Usage(
            provider: .claude,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: parsedAt,
            source: .endpoint,
            state: .unauthorized
        )
    }

    func authorizationFailureUsage(credential: ClaudeCredential, parsedAt: Date) -> Usage {
        guard credential.requiresOwnerRefresh(at: parsedAt) else {
            return unauthorizedUsage(parsedAt: parsedAt)
        }

        return Usage(
            provider: .claude,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: parsedAt,
            source: .endpoint,
            state: .refreshRequired
        )
    }

    func unavailableUsage(parsedAt: Date) -> Usage {
        Usage(
            provider: .claude,
            fiveHourPct: nil,
            weeklyPct: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            updatedAt: parsedAt,
            source: .endpoint,
            state: .unavailable
        )
    }
}

private struct ClaudeCredential: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshTokenExpiresAt: Date?
    var clientID: String?
    var scopes: [String]

    var ownerSnapshot: OwnerTokenSnapshot {
        OwnerTokenSnapshot(accessToken: accessToken, refreshToken: refreshToken)
    }

    func requiresOwnerRefresh(at date: Date) -> Bool {
        guard let expiresAt,
              expiresAt <= date,
              refreshToken != nil else {
            return false
        }

        return refreshTokenExpiresAt.map { $0 > date } ?? true
    }
}

private struct ClaudeCodeCredential: Decodable, Sendable {
    private var claudeAiOauth: ClaudeAIOAuthCredential?
    private var topLevelAccessToken: String?
    private var topLevelRefreshToken: String?
    private var topLevelExpiresAt: Double?
    private var topLevelRefreshTokenExpiresAt: Double?
    private var topLevelClientID: String?
    private var topLevelScopes: [String]?

    var accessToken: String {
        claudeAiOauth?.accessToken ?? topLevelAccessToken ?? ""
    }

    var refreshToken: String {
        claudeAiOauth?.refreshToken ?? topLevelRefreshToken ?? ""
    }

    var expiresAt: Double? {
        claudeAiOauth?.expiresAt ?? topLevelExpiresAt
    }

    var refreshTokenExpiresAt: Double? {
        claudeAiOauth?.refreshTokenExpiresAt ?? topLevelRefreshTokenExpiresAt
    }

    var clientID: String {
        claudeAiOauth?.clientID ?? topLevelClientID ?? ""
    }

    var scopes: [String] {
        claudeAiOauth?.scopes ?? topLevelScopes ?? []
    }

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth
        case topLevelAccessToken = "accessToken"
        case topLevelRefreshToken = "refreshToken"
        case topLevelExpiresAt = "expiresAt"
        case topLevelRefreshTokenExpiresAt = "refreshTokenExpiresAt"
        case topLevelClientID = "clientId"
        case topLevelScopes = "scopes"
    }
}

private struct ClaudeAIOAuthCredential: Decodable, Sendable {
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

private func millisecondsSince1970Date(_ milliseconds: Double) -> Date {
    Date(timeIntervalSince1970: milliseconds / 1_000)
}

private func claudeExecutableURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL? {
    let candidates = [
        homeDirectory.appendingPathComponent(".local/bin/claude"),
        homeDirectory.appendingPathComponent(".claude/local/claude"),
        URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        URL(fileURLWithPath: "/usr/local/bin/claude")
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
