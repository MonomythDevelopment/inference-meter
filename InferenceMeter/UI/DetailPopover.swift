import AppKit
import Foundation
import ServiceManagement
import SwiftUI

func countdownString(to resetsAt: Date?, now: Date) -> String? {
    guard let resetsAt else {
        return nil
    }

    let remainingSeconds = Int(resetsAt.timeIntervalSince(now))

    guard remainingSeconds > 0 else {
        return "resetting…"
    }

    let remainingMinutes = max(1, remainingSeconds / 60)
    let totalHours = remainingMinutes / 60
    let days = totalHours / 24
    let hours = totalHours % 24
    let minutes = remainingMinutes % 60

    guard days == 0 else {
        return "\(days)d \(hours)h"
    }

    guard hours > 0 else {
        return "\(minutes)m"
    }

    return "\(hours)h \(minutes)m"
}

func relativeUpdatedString(from updatedAt: Date, now: Date) -> String {
    let elapsedSeconds = max(0, Int(now.timeIntervalSince(updatedAt)))

    switch elapsedSeconds {
    case ..<60:
        return "\(elapsedSeconds)s ago"
    case ..<3_600:
        return "\(elapsedSeconds / 60)m ago"
    case ..<86_400:
        return "\(elapsedSeconds / 3_600)h ago"
    default:
        return "\(elapsedSeconds / 86_400)d ago"
    }
}

struct DetailPopover: View {
    @Environment(AppState.self) private var appState
    @AppStorage("compactLabel") private var isCompactLabel = false
    @AppStorage(Notifier.notificationsEnabledKey) private var notificationsEnabled = false
    @State private var launchAtLoginState = LaunchAtLoginState.current()
    @State private var launchAtLoginError: String?

    let engine: RefreshEngine
    let notifier: Notifier

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 12) {
                ProviderUsageSection(
                    usage: appState.claude,
                    configuration: .claude,
                    now: timeline.date
                )

                Divider()

                ProviderUsageSection(
                    usage: appState.codex,
                    configuration: .codex,
                    now: timeline.date
                )

                Divider()

                controls
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .task(id: timeline.date) {
                refreshLaunchAtLoginStatus()
            }
        }
        .onAppear(perform: refreshLaunchAtLoginStatus)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Refresh now") {
                engine.manualRefresh()
            }
                .keyboardShortcut("r")

            Toggle("Compact menu bar label", isOn: $isCompactLabel)

            Toggle(
                "Notify at 80% / 95%",
                isOn: Binding(
                    get: { notificationsEnabled },
                    set: { shouldEnable in
                        handleNotificationToggleChange(shouldEnable)
                    }
                )
            )

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLoginState == .enabled },
                    set: { shouldEnable in
                        handleLaunchAtLoginChange(shouldEnable)
                    }
                )
            )

            launchAtLoginMessage

            Button("Quit Inference Meter", role: .destructive, action: handleQuit)
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var launchAtLoginMessage: some View {
        if launchAtLoginState == .requiresApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Inference Meter in System Settings to finish enabling Launch at Login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
            }
        } else if let launchAtLoginError {
            Text(launchAtLoginError)
                .font(.caption)
                .foregroundStyle(Color(.systemRed))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleLaunchAtLoginChange(_ shouldEnable: Bool) {
        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    private func handleNotificationToggleChange(_ shouldEnable: Bool) {
        guard shouldEnable else {
            notificationsEnabled = false
            return
        }

        notificationsEnabled = true

        Task {
            let isAuthorized = await notifier.requestAuthorizationIfNeeded()

            guard !isAuthorized else {
                return
            }

            notificationsEnabled = false
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginState = .current()
    }

    private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}

private enum LaunchAtLoginState {
    case enabled
    case requiresApproval
    case disabled

    static func current() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .disabled
        @unknown default:
            .disabled
        }
    }
}

private struct ProviderUsageSection: View {
    let usage: Usage
    let configuration: ProviderDisplayConfiguration
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(configuration.glyph)
                    .font(.headline)

                Text(configuration.name)
                    .font(.headline)

                Spacer(minLength: 8)

                StatusBadge(state: usage.state)
            }

            VStack(alignment: .leading, spacing: 8) {
                UsageWindowRow(
                    title: "5-hour",
                    percentage: usage.fiveHourPct,
                    resetsAt: usage.fiveHourResetsAt,
                    state: usage.state,
                    now: now
                )

                UsageWindowRow(
                    title: "Weekly",
                    percentage: usage.weeklyPct,
                    resetsAt: usage.weeklyResetsAt,
                    state: usage.state,
                    now: now
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(sourceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color(.controlBackgroundColor))
                    )

                if usage.state == .unauthorized {
                    Text("Sign in via \(configuration.signInName), then Refresh")
                        .font(.caption)
                        .foregroundStyle(Color(.systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                } else if usage.state == .refreshRequired {
                    Text("Open \(configuration.signInName) and run a command to renew the session, then Refresh")
                        .font(.caption)
                        .foregroundStyle(Color(.systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var updatedText: String {
        guard let updatedAt = usage.updatedAt else {
            return "Not yet updated"
        }

        return "Updated \(relativeUpdatedString(from: updatedAt, now: now))"
    }

    private var sourceText: String {
        switch usage.source {
        case .endpoint:
            "endpoint"
        case .localFile:
            "local file — as of last CLI request"
        }
    }
}

private struct UsageWindowRow: View {
    let title: String
    let percentage: Double?
    let resetsAt: Date?
    let state: UsageState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)

                Spacer(minLength: 8)

                Text(percentageText)
                    .font(.subheadline)
                    .foregroundStyle(percentage == nil || hidesUsageValues ? .secondary : .primary)
                    .monospacedDigit()
            }

            if let progressValue {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView(value: progressValue)
                        .tint(thresholdColor(visiblePercentage))

                    countdownText
                }
            }
        }
    }

    @ViewBuilder
    private var countdownText: some View {
        if let countdown = countdownString(to: resetsAt, now: now) {
            Text(countdown == "resetting…" ? countdown : "resets in \(countdown)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var hidesUsageValues: Bool {
        switch state {
        case .ok, .stale, .refreshRequired:
            false
        case .unauthorized, .unavailable:
            true
        }
    }

    private var visiblePercentage: Double {
        guard !hidesUsageValues, let percentage else {
            return 0
        }

        return percentage
    }

    private var progressValue: Double? {
        guard !hidesUsageValues, let percentage else {
            return nil
        }

        return min(max(percentage / 100, 0), 1)
    }

    private var percentageText: String {
        guard !hidesUsageValues, let percentage else {
            return "Unavailable"
        }

        return String(format: "%.1f%%", percentage)
    }
}

private struct StatusBadge: View {
    let state: UsageState

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(accentColor.opacity(0.12))
            )
    }

    private var title: String {
        switch state {
        case .ok:
            "OK"
        case .stale:
            "Stale"
        case .refreshRequired:
            "Session refresh needed"
        case .unauthorized:
            "Sign in required"
        case .unavailable:
            "Unavailable"
        }
    }

    private var accentColor: Color {
        switch state {
        case .ok:
            Color(.systemGreen)
        case .stale, .refreshRequired, .unauthorized:
            Color(.systemOrange)
        case .unavailable:
            .secondary
        }
    }
}

private struct ProviderDisplayConfiguration {
    let glyph: String
    let name: String
    let signInName: String

    static let claude = ProviderDisplayConfiguration(
        glyph: "✳",
        name: "Claude Code",
        signInName: "Claude Code"
    )

    static let codex = ProviderDisplayConfiguration(
        glyph: "⬡",
        name: "Codex",
        signInName: "Codex"
    )
}
