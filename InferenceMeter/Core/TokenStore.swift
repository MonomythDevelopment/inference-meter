import CryptoKit
import Foundation

struct OwnerTokenSnapshot: Sendable {
    let accessToken: String
    let refreshedAt: Date?
    let credentialFingerprint: String?

    init(accessToken: String, refreshedAt: Date? = nil, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshedAt = refreshedAt
        credentialFingerprint = refreshToken.flatMap(Self.fingerprintIfPresent)
    }

    private static func fingerprintIfPresent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : makeSecretFingerprint(for: trimmed)
    }
}

actor TokenStore {
    private var inMemoryAccessToken: String?
    private var lastSeenOwnerIdentity: OwnerTokenIdentity?

    func accessToken(for ownerSnapshot: OwnerTokenSnapshot) -> String {
        let ownerIdentity = OwnerTokenIdentity(ownerSnapshot)

        if lastSeenOwnerIdentity != ownerIdentity {
            lastSeenOwnerIdentity = ownerIdentity
            inMemoryAccessToken = nil
            return ownerSnapshot.accessToken
        }

        return inMemoryAccessToken ?? ownerSnapshot.accessToken
    }

    func adoptOwnerTokenIfChanged(_ ownerSnapshot: OwnerTokenSnapshot) -> Bool {
        let ownerIdentity = OwnerTokenIdentity(ownerSnapshot)

        guard lastSeenOwnerIdentity != ownerIdentity else {
            return false
        }

        lastSeenOwnerIdentity = ownerIdentity
        inMemoryAccessToken = nil
        return true
    }
}

private struct OwnerTokenIdentity: Equatable, Sendable {
    var accessTokenFingerprint: String
    var refreshedAt: Date?
    var credentialFingerprint: String?

    init(_ snapshot: OwnerTokenSnapshot) {
        accessTokenFingerprint = makeSecretFingerprint(for: snapshot.accessToken)
        refreshedAt = snapshot.refreshedAt
        credentialFingerprint = snapshot.credentialFingerprint
    }
}

private func makeSecretFingerprint(for value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
