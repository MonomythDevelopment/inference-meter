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

        self.refreshEngine = RefreshEngine(
            appState: appState,
            providers: [
                MockUsageProvider(provider: .claude),
                MockUsageProvider(provider: .codex)
            ]
        )
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
