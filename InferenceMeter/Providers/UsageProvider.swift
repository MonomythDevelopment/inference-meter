protocol UsageProvider: Sendable {
    var provider: Provider { get }
    func refresh() async -> Usage
    func reauthenticate() async
}

extension UsageProvider {
    func reauthenticate() async {
        // Real token refresh is wired by the authentication provider work.
    }
}
