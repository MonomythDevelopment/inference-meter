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

        let providers: [any UsageProvider] = if Self.isRunningTests {
            [
                MockUsageProvider(provider: .claude),
                MockUsageProvider(provider: .codex)
            ]
        } else {
            [
                ClaudeProvider(),
                CodexProvider()
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

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
