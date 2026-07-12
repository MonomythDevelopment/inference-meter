import Foundation
import Testing
@testable import InferenceMeter

@MainActor
@Test("Backoff progression follows 60s, 2m, 5m, then caps at 15m")
func backoffProgressionCapsAtFifteenMinutes() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: Array(repeating: .unavailable(provider: .codex), count: 5)
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    var delays: [TimeInterval] = []

    for _ in 0..<5 {
        await engine.refresh(provider: .codex, bypassingBackoff: true)
        delays.append(engine.nextAttemptDelay(for: .codex) ?? -1)
    }

    #expect(delays == [60, 120, 300, 900, 900])
}

@MainActor
@Test("Success resets backoff to the base interval")
func successResetsBackoffToBaseInterval() async {
    let clock = TestRefreshClock()
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [
            .unavailable(provider: .codex),
            .unavailable(provider: .codex),
            usage(provider: .codex, fiveHourPct: 21, weeklyPct: 34, updatedAt: clock.now),
            .unavailable(provider: .codex)
        ]
    )
    let appState = AppState()
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)
    await engine.refresh(provider: .codex, bypassingBackoff: true)
    #expect(engine.currentBackoffDelay(for: .codex) == 300)

    await engine.refresh(provider: .codex, bypassingBackoff: true)
    #expect(appState.codex.state == .ok)
    #expect(engine.nextAttemptDelay(for: .codex) == nil)
    #expect(engine.currentBackoffDelay(for: .codex) == 60)

    await engine.refresh(provider: .codex, bypassingBackoff: true)
    #expect(engine.nextAttemptDelay(for: .codex) == 60)
}

@MainActor
@Test("Successful refresh evaluates notifier after publishing state")
func successfulRefreshEvaluatesNotifierAfterPublishingState() async {
    let clock = TestRefreshClock()
    let notifier = RecordingUsageThresholdNotifier()
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [
            usage(provider: .codex, fiveHourPct: 82, weeklyPct: 41, updatedAt: clock.now)
        ]
    )
    let appState = AppState()
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        notifier: notifier,
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)

    #expect(notifier.codexFiveHourPercentages == [82])
    #expect(notifier.codexStates == [.ok])
}

@MainActor
@Test("Failed refresh does not evaluate notifier")
func failedRefreshDoesNotEvaluateNotifier() async {
    let notifier = RecordingUsageThresholdNotifier()
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [.unavailable(provider: .codex)]
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [provider],
        notifier: notifier,
        clock: TestRefreshClock(),
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)

    #expect(notifier.codexFiveHourPercentages.isEmpty)
    #expect(notifier.codexStates.isEmpty)
}

@MainActor
@Test("Per-provider backoff and minimum refresh intervals are independent")
func perProviderBackoffAndMinimumRefreshIntervalsAreIndependent() async {
    let clock = TestRefreshClock()
    let codexProvider = ScriptedUsageProvider(
        provider: .codex,
        responses: [.unavailable(provider: .codex)]
    )
    let claudeProvider = ScriptedUsageProvider(
        provider: .claude,
        responses: [
            usage(provider: .claude, fiveHourPct: 10, weeklyPct: 20, updatedAt: clock.now),
            usage(provider: .claude, fiveHourPct: 11, weeklyPct: 21, updatedAt: clock.now)
        ]
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [codexProvider, claudeProvider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.handleTimerTick()
    await engine.handleTimerTick()

    #expect(await codexProvider.refreshCallCount == 1)
    #expect(await claudeProvider.refreshCallCount == 1)
    #expect(engine.nextAttemptDelay(for: .codex) == 60)
    #expect(engine.nextAttemptDelay(for: .claude) == 300)
}

@MainActor
@Test("Claude refresh attempts stay throttled even when backoff is bypassed")
func claudeRefreshAttemptsStayThrottledWhenBackoffIsBypassed() async {
    let clock = TestRefreshClock()
    let provider = ScriptedUsageProvider(
        provider: .claude,
        responses: [
            usage(provider: .claude, fiveHourPct: 10, weeklyPct: 20, updatedAt: clock.now),
            usage(provider: .claude, fiveHourPct: 11, weeklyPct: 21, updatedAt: clock.now)
        ]
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .claude, bypassingBackoff: true)
    clock.advance(by: 299)
    await engine.refresh(provider: .claude, bypassingBackoff: true)
    #expect(await provider.refreshCallCount == 1)

    clock.advance(by: 1)
    await engine.refresh(provider: .claude, bypassingBackoff: true)
    #expect(await provider.refreshCallCount == 2)
}

@MainActor
@Test("Failed refresh keeps the last known usage values")
func failedRefreshKeepsLastKnownUsageValues() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let previousUsage = usage(provider: .codex, fiveHourPct: 42, weeklyPct: 58, updatedAt: start)
    let appState = AppState(codex: previousUsage)
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [.unavailable(provider: .codex, updatedAt: start.addingTimeInterval(5))]
    )
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)

    #expect(appState.codex.fiveHourPct == 42)
    #expect(appState.codex.weeklyPct == 58)
    #expect(appState.codex.updatedAt == previousUsage.updatedAt)
    #expect(appState.codex.state == .ok)
}

@MainActor
@Test("Claude data remains fresh through a transient failure until its stale threshold")
func claudeDataRemainsFreshThroughTransientFailureUntilStaleThreshold() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let appState = AppState(
        claude: usage(provider: .claude, fiveHourPct: 14, weeklyPct: 28, updatedAt: start)
    )
    let provider = ScriptedUsageProvider(
        provider: .claude,
        responses: [.unavailable(provider: .claude)]
    )
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .claude, bypassingBackoff: true)
    #expect(appState.claude.state == .ok)

    clock.advance(by: 899)
    engine.evaluateStaleness()
    #expect(appState.claude.state == .ok)

    clock.advance(by: 1)
    engine.evaluateStaleness()
    #expect(appState.claude.state == .stale)
}

@MainActor
@Test("Staleness flips at the five-minute boundary and preserves values")
func stalenessFlipsAtFiveMinuteBoundaryAndPreservesValues() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let appState = AppState(
        codex: usage(provider: .codex, fiveHourPct: 61, weeklyPct: 74, updatedAt: start)
    )
    let provider = ScriptedUsageProvider(provider: .codex, responses: [])
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    clock.advance(by: 299)
    engine.evaluateStaleness()
    #expect(appState.codex.state == .ok)

    clock.advance(by: 1)
    engine.evaluateStaleness()
    #expect(appState.codex.state == .stale)
    #expect(appState.codex.fiveHourPct == 61)
    #expect(appState.codex.weeklyPct == 74)
}

@MainActor
@Test("Persistent 401 with prior data invokes one reauthenticate retry and becomes stale")
func persistentUnauthorizedWithPriorDataInvokesSingleReauthenticateRetryAndBecomesStale() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let appState = AppState(
        codex: usage(provider: .codex, fiveHourPct: 18, weeklyPct: 29, updatedAt: start)
    )
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [
            usage(provider: .codex, fiveHourPct: nil, weeklyPct: nil, updatedAt: start, state: .unauthorized),
            usage(provider: .codex, fiveHourPct: nil, weeklyPct: nil, updatedAt: start, state: .unauthorized),
            usage(provider: .codex, fiveHourPct: 99, weeklyPct: 99, updatedAt: start)
        ]
    )
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)

    #expect(await provider.refreshCallCount == 2)
    #expect(await provider.reauthenticateCallCount == 1)
    #expect(appState.codex.state == .stale)
    #expect(appState.codex.fiveHourPct == 18)
    #expect(appState.codex.weeklyPct == 29)
}

@MainActor
@Test("Persistent 401 with no prior data lands unauthorized")
func persistentUnauthorizedWithNoPriorDataLandsUnauthorized() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestRefreshClock(now: start)
    let appState = AppState()
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [
            usage(provider: .codex, fiveHourPct: nil, weeklyPct: nil, updatedAt: start, state: .unauthorized),
            usage(provider: .codex, fiveHourPct: nil, weeklyPct: nil, updatedAt: start, state: .unauthorized)
        ]
    )
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .codex, bypassingBackoff: true)

    #expect(await provider.refreshCallCount == 2)
    #expect(await provider.reauthenticateCallCount == 1)
    #expect(appState.codex.state == .unauthorized)
    #expect(appState.codex.fiveHourPct == nil)
    #expect(appState.codex.weeklyPct == nil)
}

@MainActor
@Test("Unchanged owner credential skips a pointless unauthorized retry")
func unchangedOwnerCredentialSkipsUnauthorizedRetry() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = ScriptedUsageProvider(
        provider: .claude,
        responses: [
            usage(
                provider: .claude,
                fiveHourPct: nil,
                weeklyPct: nil,
                updatedAt: start,
                state: .refreshRequired
            )
        ],
        reauthenticationResult: false
    )
    let appState = AppState()
    let engine = RefreshEngine(
        appState: appState,
        providers: [provider],
        clock: TestRefreshClock(now: start),
        configuration: testConfiguration()
    )

    await engine.refresh(provider: .claude, bypassingBackoff: true)

    #expect(await provider.refreshCallCount == 1)
    #expect(await provider.reauthenticateCallCount == 1)
    #expect(appState.claude.state == .refreshRequired)
}

@MainActor
@Test("Filesystem event bursts are coalesced into one refresh")
func fileSystemEventBurstsAreCoalescedIntoOneRefresh() async {
    let clock = TestRefreshClock()
    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: [
            usage(provider: .codex, fiveHourPct: 1, weeklyPct: 2, updatedAt: clock.now),
            usage(provider: .codex, fiveHourPct: 3, weeklyPct: 4, updatedAt: clock.now)
        ]
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [provider],
        clock: clock,
        configuration: testConfiguration()
    )

    engine.handleFileSystemEvent(for: .codex)
    engine.handleFileSystemEvent(for: .codex)
    engine.handleFileSystemEvent(for: .codex)
    await spinMainActor()

    clock.advance(by: 1.9)
    await spinMainActor()
    #expect(await provider.refreshCallCount == 0)

    clock.advance(by: 0.2)
    await spinMainActor()
    #expect(await provider.refreshCallCount == 1)

    engine.handleFileSystemEvent(for: .codex)
    await spinMainActor()
    clock.advance(by: 2)
    await spinMainActor()
    #expect(await provider.refreshCallCount == 2)
}

@MainActor
@Test("Missing watched directories are skipped without crashing")
func missingWatchedDirectoriesAreSkippedWithoutCrashing() {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [ScriptedUsageProvider(provider: .codex, responses: [])],
        clock: TestRefreshClock(),
        configuration: testConfiguration(watchedDirectories: [.codex: missingDirectory])
    )

    engine.startFileSystemWatches()

    #expect(engine.activeWatchCount == 0)
}

@MainActor
@Test("Filesystem watcher observes nested file changes")
func fileSystemWatcherObservesNestedFileChanges() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("InferenceMeterWatcherTests-\(UUID().uuidString)", isDirectory: true)
    let nestedDirectory = rootDirectory.appendingPathComponent("2026/07/02", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider = ScriptedUsageProvider(
        provider: .codex,
        responses: Array(
            repeating: usage(
                provider: .codex,
                fiveHourPct: 12,
                weeklyPct: 34,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            count: 3
        )
    )
    let engine = RefreshEngine(
        appState: AppState(),
        providers: [provider],
        clock: TestRefreshClock(),
        configuration: testConfiguration(
            fileSystemCoalescingWindow: 0.1,
            watchedDirectories: [.codex: rootDirectory]
        )
    )
    engine.startFileSystemWatches()
    defer { engine.stop() }

    try await Task.sleep(nanoseconds: 200_000_000)
    try Data("nested event".utf8).write(
        to: nestedDirectory.appendingPathComponent("rollout-test.jsonl", isDirectory: false),
        options: .atomic
    )

    let deadline = Date().addingTimeInterval(3)
    while await provider.refreshCallCount == 0 && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(await provider.refreshCallCount >= 1)
}

private actor ScriptedUsageProvider: UsageProvider {
    nonisolated let provider: Provider
    private var responses: [Usage]
    private let reauthenticationResult: Bool
    private(set) var refreshCallCount = 0
    private(set) var reauthenticateCallCount = 0

    init(provider: Provider, responses: [Usage], reauthenticationResult: Bool = true) {
        self.provider = provider
        self.responses = responses
        self.reauthenticationResult = reauthenticationResult
    }

    func refresh() async -> Usage {
        refreshCallCount += 1

        guard !responses.isEmpty else {
            return .unavailable(provider: provider)
        }

        return responses.removeFirst()
    }

    func reauthenticate() async -> Bool {
        reauthenticateCallCount += 1
        return reauthenticationResult
    }
}

@MainActor
private final class RecordingUsageThresholdNotifier: UsageThresholdNotifying {
    private(set) var codexFiveHourPercentages: [Double?] = []
    private(set) var codexStates: [UsageState] = []

    func evaluate(state: AppState) async {
        codexFiveHourPercentages.append(state.codex.fiveHourPct)
        codexStates.append(state.codex.state)
    }
}

@MainActor
private final class TestRefreshClock: RefreshClock {
    var now: Date
    private var sleepers: [Sleeper] = []

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func sleep(for interval: TimeInterval) async {
        guard interval > 0 else {
            return
        }

        let deadline = now.addingTimeInterval(interval)
        await withCheckedContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        resumeReadySleepers()
    }

    private func resumeReadySleepers() {
        var readySleepers: [Sleeper] = []
        var waitingSleepers: [Sleeper] = []

        for sleeper in sleepers {
            if sleeper.deadline <= now {
                readySleepers.append(sleeper)
            } else {
                waitingSleepers.append(sleeper)
            }
        }

        sleepers = waitingSleepers

        for sleeper in readySleepers {
            sleeper.continuation.resume()
        }
    }

    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Never>
    }
}

private func testConfiguration(
    fileSystemCoalescingWindow: TimeInterval = 2,
    watchedDirectories: [Provider: URL] = [:]
) -> RefreshEngineConfiguration {
    RefreshEngineConfiguration(
        pollInterval: 60,
        staleAfter: 300,
        fileSystemCoalescingWindow: fileSystemCoalescingWindow,
        watchedDirectories: watchedDirectories
    )
}

private func usage(
    provider: Provider,
    fiveHourPct: Double?,
    weeklyPct: Double?,
    updatedAt: Date,
    state: UsageState = .ok
) -> Usage {
    Usage(
        provider: provider,
        fiveHourPct: fiveHourPct,
        weeklyPct: weeklyPct,
        fiveHourResetsAt: nil,
        weeklyResetsAt: nil,
        updatedAt: updatedAt,
        source: .endpoint,
        state: state
    )
}

@MainActor
private func spinMainActor() async {
    for _ in 0..<3 {
        await Task.yield()
    }
}
