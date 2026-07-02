import Foundation

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
    private let now: @Sendable () -> Date

    init(
        keychain: Keychain = Keychain(),
        credentialService: String = ClaudeProvider.defaultCredentialService,
        credentialAccount: String = NSUserName(),
        usageURL: URL = ClaudeProvider.defaultUsageURL,
        session: URLSession = .shared,
        statusLineFallback: StatusLineFallback = .disabled,
        tokenStore: TokenStore = TokenStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.credentialService = credentialService
        self.credentialAccount = credentialAccount
        self.usageURL = usageURL
        self.session = session
        self.statusLineFallback = statusLineFallback
        self.tokenStore = tokenStore
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
                return unauthorizedUsage(parsedAt: parsedAt)
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

    func reauthenticate() async {
        // Read-only monitor: never perform an OAuth refresh_token exchange.
        // Anthropic rotates the shared refresh token on use, which would invalidate
        // the copy the Claude Code CLI stores on disk and force the CLI to re-login.
        // We only adopt a token the CLI itself has already refreshed in the Keychain.
        guard let credential = try? readCredential() else {
            return
        }
        _ = await tokenStore.adoptOwnerTokenIfChanged(credential.ownerSnapshot)
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
    var clientID: String?
    var scopes: [String]

    var ownerSnapshot: OwnerTokenSnapshot {
        OwnerTokenSnapshot(accessToken: accessToken, refreshToken: refreshToken)
    }
}

private struct ClaudeCodeCredential: Decodable, Sendable {
    private var claudeAiOauth: ClaudeAIOAuthCredential?
    private var topLevelAccessToken: String?
    private var topLevelRefreshToken: String?
    private var topLevelClientID: String?
    private var topLevelScopes: [String]?

    var accessToken: String {
        claudeAiOauth?.accessToken ?? topLevelAccessToken ?? ""
    }

    var refreshToken: String {
        claudeAiOauth?.refreshToken ?? topLevelRefreshToken ?? ""
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
        case topLevelClientID = "clientId"
        case topLevelScopes = "scopes"
    }
}

private struct ClaudeAIOAuthCredential: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var clientID: String?
    var scopes: [String]?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case clientID = "clientId"
        case scopes
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
