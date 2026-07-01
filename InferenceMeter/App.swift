import AppKit
import SwiftUI

@main
struct InferenceMeterApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
        } label: {
            Text("✳ --·--  ⬡ --·--")
                .monospacedDigit()
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
