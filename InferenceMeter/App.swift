import SwiftUI

@main
@MainActor
struct InferenceMeterApp: App {
    @State private var appState: AppState
    private let refreshEngine: RefreshEngine
    private let notifier: Notifier

    init() {
        let appState = AppState()
        let notifier = Notifier()
        self._appState = State(initialValue: appState)
        self.notifier = notifier
        let codexProvider = CodexProvider()

        let providers: [any UsageProvider] = if Self.isRunningTests {
            [
                MockUsageProvider(provider: .claude),
                MockUsageProvider(provider: .codex)
            ]
        } else {
            [
                ClaudeProvider(),
                codexProvider
            ]
        }

        self.refreshEngine = RefreshEngine(
            appState: appState,
            providers: providers,
            notifier: notifier
        )

        guard !Self.isRunningTests else {
            return
        }

        refreshEngine.start()

        Task {
            let usage = await codexProvider.refresh()
            Self.printTemporaryCodexUsage(usage)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DetailPopover(engine: refreshEngine, notifier: notifier)
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }

    // Temporary IM-006 launch wiring. RefreshEngine owns scheduled provider refreshes in IM-007.
    private static func printTemporaryCodexUsage(_ usage: Usage) {
        let fiveHourPct = usage.fiveHourPct.map { String(format: "%.1f%%", $0) } ?? "unavailable"
        let weeklyPct = usage.weeklyPct.map { String(format: "%.1f%%", $0) } ?? "unavailable"

        print(
            "Codex usage: 5h \(fiveHourPct), weekly \(weeklyPct), "
                + "source \(usageSourceDescription(usage.source)), "
                + "state \(usageStateDescription(usage.state))"
        )
    }

    private static func usageSourceDescription(_ source: UsageSource) -> String {
        switch source {
        case .endpoint:
            return "endpoint"
        case .localFile:
            return "localFile"
        }
    }

    private static func usageStateDescription(_ state: UsageState) -> String {
        switch state {
        case .ok:
            return "ok"
        case .stale:
            return "stale"
        case .unauthorized:
            return "unauthorized"
        case .unavailable:
            return "unavailable"
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
