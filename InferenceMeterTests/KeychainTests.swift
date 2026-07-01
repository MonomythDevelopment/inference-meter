import Foundation
import Security
import Testing
@testable import InferenceMeter

@Test("Keychain reads generic password data through injectable reader")
func keychainReadsGenericPasswordDataThroughInjectableReader() throws {
    let expectedData = Data("credential-json".utf8)
    let keychain = Keychain { service, account in
        #expect(service == "unit-test-service")
        #expect(account == "unit-test-account")
        return expectedData
    }

    let data = try keychain.readGenericPassword(
        service: "unit-test-service",
        account: "unit-test-account"
    )

    #expect(data == expectedData)
}

@Test("Keychain preserves missing item as typed non-crashing outcome")
func keychainPreservesMissingItemAsTypedOutcome() {
    let keychain = Keychain { _, _ in throw KeychainError.itemNotFound }
    var didCatchMissingItem = false

    do {
        _ = try keychain.readGenericPassword(service: "unit-test-service", account: "unit-test-account")
    } catch KeychainError.itemNotFound {
        didCatchMissingItem = true
    } catch {
        didCatchMissingItem = false
    }

    #expect(didCatchMissingItem)
}

@Test("Keychain maps Security framework statuses")
func keychainMapsSecurityFrameworkStatuses() {
    #expect(KeychainError(status: errSecItemNotFound) == .itemNotFound)

    if case let .unhandled(status) = KeychainError(status: errSecInteractionNotAllowed) {
        #expect(status == errSecInteractionNotAllowed)
    } else {
        #expect(false)
    }
}
