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
@Test("Per-provider backoff state is independent")
func perProviderBackoffStateIsIndependent() async {
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
    #expect(await claudeProvider.refreshCallCount == 2)
    #expect(engine.nextAttemptDelay(for: .codex) == 60)
    #expect(engine.nextAttemptDelay(for: .claude) == nil)
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
    #expect(appState.codex.state == .unavailable)
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
@Test("Persistent 401 invokes one reauthenticate retry and lands unauthorized")
func persistentUnauthorizedInvokesSingleReauthenticateRetry() async {
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
    #expect(appState.codex.state == .unauthorized)
    #expect(appState.codex.fiveHourPct == 18)
    #expect(appState.codex.weeklyPct == 29)
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

private actor ScriptedUsageProvider: UsageProvider {
    nonisolated let provider: Provider
    private var responses: [Usage]
    private(set) var refreshCallCount = 0
    private(set) var reauthenticateCallCount = 0

    init(provider: Provider, responses: [Usage]) {
        self.provider = provider
        self.responses = responses
    }

    func refresh() async -> Usage {
        refreshCallCount += 1

        guard !responses.isEmpty else {
            return .unavailable(provider: provider)
        }

        return responses.removeFirst()
    }

    func reauthenticate() async {
        reauthenticateCallCount += 1
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
    watchedDirectories: [Provider: URL] = [:]
) -> RefreshEngineConfiguration {
    RefreshEngineConfiguration(
        pollInterval: 60,
        staleAfter: 300,
        fileSystemCoalescingWindow: 2,
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
