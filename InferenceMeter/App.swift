import AppKit
import SwiftUI

@main
@MainActor
struct InferenceMeterApp: App {
    @State private var appState: AppState
    private let refreshEngine: RefreshEngine

    init() {
        let appState = AppState()
        self._appState = State(initialValue: appState)

        let providers: [any UsageProvider] = if Self.isRunningTests {
            [
                MockUsageProvider(provider: .claude),
                MockUsageProvider(provider: .codex)
            ]
        } else {
            [
                ClaudeProvider(),
                MockUsageProvider(provider: .codex)
            ]
        }

        self.refreshEngine = RefreshEngine(
            appState: appState,
            providers: providers
        )

        guard !Self.isRunningTests else {
            return
        }

        refreshEngine.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(appState)
        } label: {
            Text("✳ --·--  ⬡ --·--")
                .monospacedDigit()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

struct MenuContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inference Meter")
                .font(.headline)

            Text("Usage data will appear here.")
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit Inference Meter", action: handleQuit)
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 260)
    }

    private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}
