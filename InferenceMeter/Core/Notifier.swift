import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol UsageThresholdNotifying: AnyObject {
    func evaluate(state: AppState) async
}

@MainActor
protocol NotificationSettingsStoring: AnyObject {
    var notificationsEnabled: Bool { get set }
}

enum ThresholdNotificationAuthorizationStatus {
    case notDetermined
    case denied
    case authorized
}

@MainActor
protocol ThresholdNotificationPosting: AnyObject {
    func authorizationStatus() async -> ThresholdNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func post(_ notification: ThresholdNotification) async throws
}

struct ThresholdNotification: Equatable {
    let identifier: String
    let title: String
    let body: String

    var renderedText: String {
        "\(title) — \(body)"
    }
}

@MainActor
final class Notifier: UsageThresholdNotifying {
    static let notificationsEnabledKey = "notificationsEnabled"

    private static let notificationThresholds = [80.0, 95.0]
    private let settingsStore: NotificationSettingsStoring
    private let poster: ThresholdNotificationPosting
    private let now: () -> Date

    // In-memory by design: relaunches re-observe current values and rebuild slot state
    // instead of persisting notification history across app versions or reset periods.
    private var sentMarkers: [NotificationSlot: SentMarker] = [:]
    private var lastObservations: [NotificationSlot: SlotObservation] = [:]

    init(
        settingsStore: NotificationSettingsStoring = UserDefaultsNotificationSettingsStore(),
        poster: ThresholdNotificationPosting = UserNotificationCenterPoster(),
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.poster = poster
        self.now = now
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        switch await poster.authorizationStatus() {
        case .authorized:
            return true
        case .denied:
            settingsStore.notificationsEnabled = false
            return false
        case .notDetermined:
            do {
                let isAuthorized = try await poster.requestAuthorization()
                if !isAuthorized {
                    settingsStore.notificationsEnabled = false
                }
                return isAuthorized
            } catch {
                settingsStore.notificationsEnabled = false
                return false
            }
        }
    }

    func evaluate(state: AppState) async {
        guard settingsStore.notificationsEnabled else {
            return
        }

        await evaluate(usage: state.claude)
        await evaluate(usage: state.codex)
    }
}

private extension Notifier {
    func evaluate(usage: Usage) async {
        guard usage.state == .ok else {
            return
        }

        for window in NotificationWindow.allCases {
            guard let percentage = window.percentage(in: usage) else {
                continue
            }

            for threshold in Self.notificationThresholds {
                await evaluate(
                    usage: usage,
                    window: window,
                    percentage: percentage,
                    threshold: threshold
                )
            }
        }
    }

    func evaluate(
        usage: Usage,
        window: NotificationWindow,
        percentage: Double,
        threshold: Double
    ) async {
        let slot = NotificationSlot(
            provider: usage.provider,
            window: window,
            threshold: threshold
        )
        let resetsAt = window.resetsAt(in: usage)
        let currentObservation = SlotObservation(percentage: percentage, resetsAt: resetsAt)
        let previousObservation = lastObservations[slot]
        let isNewResetPeriod = previousObservation.map { $0.resetsAt != resetsAt } ?? false

        if isNewResetPeriod {
            sentMarkers.removeValue(forKey: slot)
        }

        guard isAtOrAboveUsageThreshold(percentage, threshold: threshold) else {
            sentMarkers.removeValue(forKey: slot)
            lastObservations[slot] = currentObservation
            return
        }

        let previousPercentage = isNewResetPeriod ? nil : previousObservation?.percentage
        let wasPreviouslyBelow = previousPercentage.map {
            !isAtOrAboveUsageThreshold($0, threshold: threshold)
        } ?? true

        if wasPreviouslyBelow, sentMarkers[slot] == nil,
           let notification = makeNotification(
               slot: slot,
               percentage: percentage,
               resetsAt: resetsAt
        ) {
            do {
                try await poster.post(notification)
                sentMarkers[slot] = SentMarker(resetsAt: resetsAt)
            } catch {
            }
        }

        lastObservations[slot] = currentObservation
    }

    func makeNotification(
        slot: NotificationSlot,
        percentage: Double,
        resetsAt: Date?
    ) -> ThresholdNotification? {
        guard let countdown = countdownString(to: resetsAt, now: now()) else {
            return nil
        }

        let roundedPercentage = Int(percentage.rounded())
        let title = "\(slot.provider.notificationLabel) \(slot.window.label) window at \(roundedPercentage)%"
        let body = "resets in \(countdown)"

        return ThresholdNotification(
            identifier: slot.identifier,
            title: title,
            body: body
        )
    }
}

private final class UserDefaultsNotificationSettingsStore: NotificationSettingsStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var notificationsEnabled: Bool {
        get {
            defaults.bool(forKey: Notifier.notificationsEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: Notifier.notificationsEnabledKey)
        }
    }
}

private final class UserNotificationCenterPoster: ThresholdNotificationPosting {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> ThresholdNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ notification: ThresholdNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

private enum NotificationWindow: CaseIterable, Hashable {
    case fiveHour
    case weekly
    case fable

    var label: String {
        switch self {
        case .fiveHour:
            "5-hour"
        case .weekly:
            "weekly"
        case .fable:
            "Fable"
        }
    }

    func percentage(in usage: Usage) -> Double? {
        switch self {
        case .fiveHour:
            usage.fiveHourPct
        case .weekly:
            usage.weeklyPct
        case .fable:
            usage.fablePct
        }
    }

    func resetsAt(in usage: Usage) -> Date? {
        switch self {
        case .fiveHour:
            usage.fiveHourResetsAt
        case .weekly:
            usage.weeklyResetsAt
        case .fable:
            usage.fableResetsAt
        }
    }
}

private struct NotificationSlot: Hashable {
    let provider: Provider
    let window: NotificationWindow
    let threshold: Double

    var identifier: String {
        let thresholdValue = Int(threshold.rounded())
        return "inference-meter.threshold.\(provider.identifier).\(window.identifier).\(thresholdValue)"
    }
}

private struct SentMarker {
    let resetsAt: Date?
}

private struct SlotObservation {
    let percentage: Double
    let resetsAt: Date?
}

private extension Provider {
    var identifier: String {
        switch self {
        case .claude:
            "claude"
        case .codex:
            "codex"
        }
    }

    var notificationLabel: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }
}

private extension NotificationWindow {
    var identifier: String {
        switch self {
        case .fiveHour:
            "five-hour"
        case .weekly:
            "weekly"
        case .fable:
            "fable"
        }
    }
}
