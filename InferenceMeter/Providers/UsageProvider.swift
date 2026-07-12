protocol UsageProvider: Sendable {
    var provider: Provider { get }
    func refresh() async -> Usage
    func reauthenticate() async -> Bool
}

extension UsageProvider {
    func reauthenticate() async -> Bool {
        false
    }
}
