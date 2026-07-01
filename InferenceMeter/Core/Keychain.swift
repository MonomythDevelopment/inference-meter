import Foundation
import Security

enum KeychainError: Error, Equatable, Sendable {
    case itemNotFound
    case unexpectedItemData
    case unhandled(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound:
            self = .itemNotFound
        default:
            self = .unhandled(status)
        }
    }
}

struct Keychain: Sendable {
    private let readGenericPasswordHandler: @Sendable (_ service: String, _ account: String) throws -> Data

    init(
        readGenericPassword: @escaping @Sendable (_ service: String, _ account: String) throws -> Data = Keychain.secItemReadGenericPassword
    ) {
        readGenericPasswordHandler = readGenericPassword
    }

    func readGenericPassword(service: String, account: String) throws -> Data {
        try readGenericPasswordHandler(service, account)
    }
}

private extension Keychain {
    static func secItemReadGenericPassword(service: String, account: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedItemData
        }

        return data
    }
}
