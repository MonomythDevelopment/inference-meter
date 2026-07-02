import Foundation
import Testing
@testable import InferenceMeter

@MainActor
@Test("Crossing 80 percent upward posts once until the value recovers below threshold")
func crossingEightyPercentPostsOnceUntilRecovery() async {
    let fixture = NotifierFixture()

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 79))
    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 80))
    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 88))

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Codex 5-hour window at 80% — resets in 1h 40m"
    ])

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 79))
    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 81))

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Codex 5-hour window at 80% — resets in 1h 40m",
        "Codex 5-hour window at 81% — resets in 1h 40m"
    ])
}

@MainActor
@Test("Crossing 95 percent is independent and a jump across both thresholds posts both")
func jumpAcrossBothThresholdsPostsEightyAndNinetyFive() async {
    let fixture = NotifierFixture()

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 60))
    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 96))

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Codex 5-hour window at 96% — resets in 1h 40m",
        "Codex 5-hour window at 96% — resets in 1h 40m"
    ])
    #expect(fixture.poster.notifications.map(\.identifier) == [
        "inference-meter.threshold.codex.five-hour.80",
        "inference-meter.threshold.codex.five-hour.95"
    ])
}

@MainActor
@Test("Window reset re-arms sent thresholds")
func windowResetRearmsSentThresholds() async {
    let fixture = NotifierFixture()
    let nextReset = fixture.codexFiveHourReset.addingTimeInterval(5 * 60 * 60)

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 85))
    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 87))
    await fixture.notifier.evaluate(
        state: fixture.state(codexFiveHourPct: 86, codexFiveHourResetsAt: nextReset)
    )

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Codex 5-hour window at 85% — resets in 1h 40m",
        "Codex 5-hour window at 86% — resets in 6h 40m"
    ])
}

@MainActor
@Test("Non-ok states never post notifications and do not corrupt markers")
func nonOkStatesDoNotPostOrCorruptMarkers() async {
    let fixture = NotifierFixture()

    for state in [UsageState.stale, .unauthorized, .unavailable] {
        await fixture.notifier.evaluate(
            state: fixture.state(codexFiveHourPct: 96, codexState: state)
        )
    }

    #expect(fixture.poster.notifications.isEmpty)

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 96))

    #expect(fixture.poster.notifications.map(\.identifier) == [
        "inference-meter.threshold.codex.five-hour.80",
        "inference-meter.threshold.codex.five-hour.95"
    ])
}

@MainActor
@Test("Disabled notification setting makes evaluation a no-op")
func disabledNotificationSettingMakesEvaluationNoOp() async {
    let fixture = NotifierFixture(notificationsEnabled: false)

    await fixture.notifier.evaluate(state: fixture.state(codexFiveHourPct: 96))

    #expect(fixture.poster.notifications.isEmpty)
}

@MainActor
@Test("Notification copy uses provider window percent and shared countdown formatting")
func notificationCopyUsesProviderWindowPercentAndCountdown() async {
    let fixture = NotifierFixture()

    await fixture.notifier.evaluate(state: fixture.state(claudeFiveHourPct: 82))

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Claude 5-hour window at 82% — resets in 1h 40m"
    ])
}

@MainActor
@Test("Weekly notification copy uses weekly label and multi-day countdown")
func weeklyNotificationCopyUsesWeeklyLabelAndMultiDayCountdown() async {
    let fixture = NotifierFixture()

    await fixture.notifier.evaluate(state: fixture.state(codexWeeklyPct: 96))

    #expect(fixture.poster.notifications.map(\.renderedText) == [
        "Codex weekly window at 96% — resets in 3d 5h",
        "Codex weekly window at 96% — resets in 3d 5h"
    ])
    #expect(fixture.poster.notifications.map(\.identifier) == [
        "inference-meter.threshold.codex.weekly.80",
        "inference-meter.threshold.codex.weekly.95"
    ])
}

@MainActor
@Test("Authorization denial reverts the persisted toggle")
func authorizationDenialRevertsPersistedToggle() async {
    let fixture = NotifierFixture(authorizationStatus: .denied)

    let isAuthorized = await fixture.notifier.requestAuthorizationIfNeeded()

    #expect(!isAuthorized)
    #expect(!fixture.settingsStore.notificationsEnabled)
    #expect(fixture.poster.authorizationRequestCount == 0)
}

@MainActor
@Test("First enable requests authorization only while status is undetermined")
func firstEnableRequestsAuthorizationOnlyWhenUndetermined() async {
    let fixture = NotifierFixture(authorizationStatus: .notDetermined)
    fixture.poster.authorizationRequestResult = true

    let isAuthorized = await fixture.notifier.requestAuthorizationIfNeeded()

    #expect(isAuthorized)
    #expect(fixture.settingsStore.notificationsEnabled)
    #expect(fixture.poster.authorizationRequestCount == 1)

    _ = await fixture.notifier.requestAuthorizationIfNeeded()
    #expect(fixture.poster.authorizationRequestCount == 1)
}

@MainActor
private final class NotifierFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codexFiveHourReset: Date
    let weeklyReset: Date
    let settingsStore: MemoryNotificationSettingsStore
    let poster: RecordingThresholdNotificationPoster
    let notifier: Notifier

    init(
        notificationsEnabled: Bool = true,
        authorizationStatus: ThresholdNotificationAuthorizationStatus = .authorized
    ) {
        codexFiveHourReset = now.addingTimeInterval(100 * 60)
        weeklyReset = now.addingTimeInterval((3 * 24 * 60 * 60) + (5 * 60 * 60))
        settingsStore = MemoryNotificationSettingsStore(notificationsEnabled: notificationsEnabled)
        poster = RecordingThresholdNotificationPoster(authorizationStatus: authorizationStatus)
        let currentDate = now
        notifier = Notifier(
            settingsStore: settingsStore,
            poster: poster,
            now: { currentDate }
        )
    }

    func state(
        claudeFiveHourPct: Double? = nil,
        claudeWeeklyPct: Double? = nil,
        claudeFiveHourResetsAt: Date? = nil,
        claudeWeeklyResetsAt: Date? = nil,
        claudeState: UsageState = .ok,
        codexFiveHourPct: Double? = nil,
        codexWeeklyPct: Double? = nil,
        codexFiveHourResetsAt: Date? = nil,
        codexWeeklyResetsAt: Date? = nil,
        codexState: UsageState = .ok
    ) -> AppState {
        AppState(
            claude: usage(
                provider: .claude,
                fiveHourPct: claudeFiveHourPct,
                weeklyPct: claudeWeeklyPct,
                fiveHourResetsAt: claudeFiveHourResetsAt ?? codexFiveHourReset,
                weeklyResetsAt: claudeWeeklyResetsAt ?? weeklyReset,
                state: claudeState
            ),
            codex: usage(
                provider: .codex,
                fiveHourPct: codexFiveHourPct,
                weeklyPct: codexWeeklyPct,
                fiveHourResetsAt: codexFiveHourResetsAt ?? codexFiveHourReset,
                weeklyResetsAt: codexWeeklyResetsAt ?? weeklyReset,
                state: codexState
            )
        )
    }

    private func usage(
        provider: Provider,
        fiveHourPct: Double?,
        weeklyPct: Double?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        state: UsageState
    ) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: now,
            source: .endpoint,
            state: state
        )
    }
}

@MainActor
private final class MemoryNotificationSettingsStore: NotificationSettingsStoring {
    var notificationsEnabled: Bool

    init(notificationsEnabled: Bool) {
        self.notificationsEnabled = notificationsEnabled
    }
}

@MainActor
private final class RecordingThresholdNotificationPoster: ThresholdNotificationPosting {
    var authorizationStatusValue: ThresholdNotificationAuthorizationStatus
    var authorizationRequestResult = false
    private(set) var authorizationRequestCount = 0
    private(set) var notifications: [ThresholdNotification] = []

    init(authorizationStatus: ThresholdNotificationAuthorizationStatus) {
        authorizationStatusValue = authorizationStatus
    }

    func authorizationStatus() async -> ThresholdNotificationAuthorizationStatus {
        authorizationStatusValue
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        authorizationStatusValue = authorizationRequestResult ? .authorized : .denied
        return authorizationRequestResult
    }

    func post(_ notification: ThresholdNotification) async throws {
        notifications.append(notification)
    }
}
