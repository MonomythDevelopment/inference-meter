@preconcurrency import AppKit
@preconcurrency import CoreServices
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var claude: Usage
    var codex: Usage

    init(
        claude: Usage = .unavailable(provider: .claude),
        codex: Usage = .unavailable(provider: .codex)
    ) {
        self.claude = claude
        self.codex = codex
    }

    func usage(for provider: Provider) -> Usage {
        switch provider {
        case .claude:
            claude
        case .codex:
            codex
        }
    }

    func setUsage(_ usage: Usage) {
        switch usage.provider {
        case .claude:
            claude = usage
        case .codex:
            codex = usage
        }
    }
}

@MainActor
protocol RefreshClock: AnyObject {
    var now: Date { get }
    func sleep(for interval: TimeInterval) async
}

@MainActor
final class SystemRefreshClock: RefreshClock {
    var now: Date {
        Date()
    }

    func sleep(for interval: TimeInterval) async {
        guard interval > 0 else {
            return
        }

        let nanoseconds = UInt64(interval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct RefreshEngineConfiguration {
    var pollInterval: TimeInterval = 60
    var staleAfter: TimeInterval = 300
    var fileSystemCoalescingWindow: TimeInterval = 2
    var watchedDirectories: [Provider: URL] = Self.defaultWatchedDirectories()

    static func defaultWatchedDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Provider: URL] {
        [
            .claude: homeDirectory.appendingPathComponent(".claude", isDirectory: true),
            .codex: homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        ]
    }
}

@MainActor
final class RefreshEngine {
    private let appState: AppState
    private let providers: [any UsageProvider]
    private let notifier: (any UsageThresholdNotifying)?
    private let clock: RefreshClock
    private let configuration: RefreshEngineConfiguration
    private var refreshState: [Provider: ProviderRefreshState]
    private var inFlightProviders: Set<Provider> = []
    private var timerTask: Task<Void, Never>?
    private var stalenessTask: Task<Void, Never>?
    private var coalescingTasks: [Provider: Task<Void, Never>] = [:]
    private var directoryWatchers: [Provider: DirectoryWatcher] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false

    init(
        appState: AppState,
        providers: [any UsageProvider],
        notifier: (any UsageThresholdNotifying)? = nil,
        clock: RefreshClock = SystemRefreshClock(),
        configuration: RefreshEngineConfiguration = RefreshEngineConfiguration()
    ) {
        self.appState = appState
        self.providers = providers
        self.notifier = notifier
        self.clock = clock
        self.configuration = configuration
        self.refreshState = Dictionary(
            uniqueKeysWithValues: providers.map { provider in
                (provider.provider, ProviderRefreshState())
            }
        )
    }

    func stop() {
        timerTask?.cancel()
        stalenessTask?.cancel()
        for task in coalescingTasks.values {
            task.cancel()
        }
        for watcher in directoryWatchers.values {
            watcher.cancel()
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        timerTask = nil
        stalenessTask = nil
        coalescingTasks = [:]
        directoryWatchers = [:]
        wakeObserver = nil
        isStarted = false
    }

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        startTimer()
        startStalenessTick()
        startFileSystemWatches()
        registerWakeObserver()
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refreshAll(bypassingBackoff: true)
        }
    }

    func manualRefresh() {
        refreshNow()
    }

    func handleTimerTick() async {
        await refreshAll(bypassingBackoff: false)
        evaluateStaleness()
    }

    func handleFileSystemEvent(for provider: Provider) {
        coalescingTasks[provider]?.cancel()

        coalescingTasks[provider] = Task { [weak self] in
            guard let self else {
                return
            }

            await clock.sleep(for: configuration.fileSystemCoalescingWindow)

            guard !Task.isCancelled else {
                return
            }

            await refresh(provider: provider, bypassingBackoff: false)
            coalescingTasks[provider] = nil
        }
    }

    func handleCoalescedFileSystemEvent(for provider: Provider) {
        coalescingTasks[provider]?.cancel()
        coalescingTasks[provider] = nil

        Task { [weak self] in
            await self?.refresh(provider: provider, bypassingBackoff: false)
        }
    }

    func startFileSystemWatches() {
        for (provider, directory) in configuration.watchedDirectories where directoryWatchers[provider] == nil {
            guard let watcher = DirectoryWatcher(
                url: directory,
                latency: configuration.fileSystemCoalescingWindow,
                eventHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleCoalescedFileSystemEvent(for: provider)
                    }
                }
            ) else {
                continue
            }

            directoryWatchers[provider] = watcher
        }
    }

    var activeWatchCount: Int {
        directoryWatchers.count
    }

    func refresh(provider providerID: Provider, bypassingBackoff: Bool) async {
        guard let provider = providers.first(where: { $0.provider == providerID }) else {
            return
        }

        guard shouldAttemptRefresh(provider: providerID, bypassingBackoff: bypassingBackoff) else {
            return
        }

        guard !inFlightProviders.contains(providerID) else {
            return
        }

        inFlightProviders.insert(providerID)
        defer {
            inFlightProviders.remove(providerID)
        }

        let firstUsage = await provider.refresh()

        if firstUsage.state == .unauthorized {
            await provider.reauthenticate()
            let retryUsage = await provider.refresh()
            await applyRefreshResult(retryUsage.state == .ok ? retryUsage : markedUnauthorized(provider: providerID))
            return
        }

        await applyRefreshResult(firstUsage)
    }

    func evaluateStaleness() {
        for provider in providers.map(\.provider) {
            let usage = appState.usage(for: provider)

            guard usage.state != .unauthorized,
                  let updatedAt = usage.updatedAt,
                  clock.now.timeIntervalSince(updatedAt) >= configuration.staleAfter else {
                continue
            }

            appState.setUsage(usage.replacingState(.stale))
        }
    }

    func nextAttemptDelay(for provider: Provider) -> TimeInterval? {
        guard let state = refreshState[provider],
              state.nextAllowedAt > clock.now else {
            return nil
        }

        return state.nextAllowedAt.timeIntervalSince(clock.now)
    }

    func currentBackoffDelay(for provider: Provider) -> TimeInterval {
        refreshState[provider]?.nextFailureBackoff ?? ProviderRefreshState.baseBackoff
    }
}

private extension RefreshEngine {
    func startTimer() {
        timerTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await handleTimerTick()
                await clock.sleep(for: configuration.pollInterval)
            }
        }
    }

    func startStalenessTick() {
        stalenessTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                evaluateStaleness()
                await clock.sleep(for: configuration.pollInterval)
            }
        }
    }

    func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll(bypassingBackoff: true)
            }
        }
    }

    func refreshAll(bypassingBackoff: Bool) async {
        for provider in providers.map(\.provider) {
            await refresh(provider: provider, bypassingBackoff: bypassingBackoff)
        }
    }

    func shouldAttemptRefresh(provider: Provider, bypassingBackoff: Bool) -> Bool {
        if bypassingBackoff {
            return true
        }

        guard let state = refreshState[provider] else {
            return true
        }

        return clock.now >= state.nextAllowedAt
    }

    func applyRefreshResult(_ usage: Usage) async {
        switch usage.state {
        case .ok:
            await applySuccessfulRefresh(usage)
        case .unauthorized:
            applyFailedRefresh(provider: usage.provider, state: .unauthorized)
        case .stale, .unavailable:
            applyFailedRefresh(provider: usage.provider, state: .unavailable)
        }
    }

    func applySuccessfulRefresh(_ usage: Usage) async {
        var refreshedUsage = usage
        refreshedUsage.updatedAt = usage.updatedAt ?? clock.now
        appState.setUsage(refreshedUsage)
        refreshState[usage.provider, default: ProviderRefreshState()].recordSuccess()
        await notifier?.evaluate(state: appState)
    }

    func applyFailedRefresh(provider: Provider, state: UsageState) {
        let previousUsage = appState.usage(for: provider)
        appState.setUsage(previousUsage.replacingState(state))
        refreshState[provider, default: ProviderRefreshState()].recordFailure(now: clock.now)
    }

    func markedUnauthorized(provider: Provider) -> Usage {
        appState.usage(for: provider).replacingState(.unauthorized)
    }
}

private struct ProviderRefreshState {
    static let baseBackoff: TimeInterval = 60
    private static let secondBackoff: TimeInterval = 120
    private static let thirdBackoff: TimeInterval = 300
    private static let maxBackoff: TimeInterval = 900

    var nextAllowedAt: Date = .distantPast
    var nextFailureBackoff: TimeInterval = Self.baseBackoff

    mutating func recordSuccess() {
        nextAllowedAt = .distantPast
        nextFailureBackoff = Self.baseBackoff
    }

    mutating func recordFailure(now: Date) {
        nextAllowedAt = now.addingTimeInterval(nextFailureBackoff)
        nextFailureBackoff = Self.backoff(after: nextFailureBackoff)
    }

    private static func backoff(after interval: TimeInterval) -> TimeInterval {
        switch interval {
        case ..<secondBackoff:
            secondBackoff
        case ..<thirdBackoff:
            thirdBackoff
        default:
            maxBackoff
        }
    }
}

private extension Usage {
    func replacingState(_ state: UsageState) -> Usage {
        Usage(
            provider: provider,
            fiveHourPct: fiveHourPct,
            weeklyPct: weeklyPct,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: updatedAt,
            source: source,
            state: state
        )
    }
}

private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let eventHandler: () -> Void
    private var isCancelled = false

    init?(url: URL, latency: TimeInterval, eventHandler: @escaping () -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        self.eventHandler = eventHandler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            nil,
            Self.streamCallback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, .main)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        self.stream = stream
    }

    private static let streamCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else {
            return
        }

        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.eventHandler()
    }

    func cancel() {
        guard !isCancelled else {
            return
        }

        isCancelled = true
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        cancel()
    }
}

struct MockUsageProvider: UsageProvider {
    let provider: Provider

    func refresh() async -> Usage {
        // Swap this provider for the real Claude/Codex providers when IM-005 and IM-006 land.
        .unavailable(provider: provider)
    }
}
