protocol UsageProvider: Sendable {
    var provider: Provider { get }
    func refresh() async -> Usage
}
