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
    private let now: @Sendable () -> Date

    init(
        keychain: Keychain = Keychain(),
        credentialService: String = ClaudeProvider.defaultCredentialService,
        credentialAccount: String = NSUserName(),
        usageURL: URL = ClaudeProvider.defaultUsageURL,
        session: URLSession = .shared,
        statusLineFallback: StatusLineFallback = .disabled,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.credentialService = credentialService
        self.credentialAccount = credentialAccount
        self.usageURL = usageURL
        self.session = session
        self.statusLineFallback = statusLineFallback
        self.now = now
    }

    func refresh() async -> Usage {
        let parsedAt = now()

        do {
            let credentialData = try keychain.readGenericPassword(
                service: credentialService,
                account: credentialAccount
            )
            let accessToken = try decodeAccessToken(from: credentialData)
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

    func endpointRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    func decodeAccessToken(from data: Data) throws -> String {
        do {
            let credential = try JSONDecoder().decode(ClaudeCodeCredential.self, from: data)
            let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !token.isEmpty else {
                throw ClaudeCredentialError.missingAccessToken
            }

            return token
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

private struct ClaudeCodeCredential: Decodable, Sendable {
    private var claudeAiOauth: ClaudeAIOAuthCredential?
    private var topLevelAccessToken: String?

    var accessToken: String {
        claudeAiOauth?.accessToken ?? topLevelAccessToken ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth
        case topLevelAccessToken = "accessToken"
    }
}

private struct ClaudeAIOAuthCredential: Decodable, Sendable {
    var accessToken: String
}
