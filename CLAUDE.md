# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

InferenceMeter is a native macOS **menu bar** app (SwiftUI, `LSUIElement` — no Dock icon) that shows live usage percentages for the Claude Code and Codex CLIs. It does not have its own login: it reads the credentials those CLIs already store on the machine and calls their usage endpoints.

## Build & test

The Xcode project is **generated from `project.yml` by XcodeGen** — `InferenceMeter.xcodeproj` is disposable and must not be committed. Every `make` target runs `xcodegen generate` first, so you never edit the project in Xcode's UI.

Prerequisites: full Xcode selected as the active developer dir (not Command Line Tools), and `brew install xcodegen`.

```sh
make build            # xcodegen generate + xcodebuild build
make test             # xcodegen generate + xcodebuild test
make clean            # remove generated .xcodeproj, DerivedData, build/
./scripts/release.sh  # signed/notarized (or ad-hoc) release zip into dist/
```

Run a single test (tests use the **Swift Testing** framework — `@Test` / `#expect`, not XCTest):

```sh
xcodebuild -project InferenceMeter.xcodeproj -scheme InferenceMeter \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:InferenceMeterTests/claudeProviderReturnsEndpointUsage test
```

The `-only-testing:` path is `InferenceMeterTests/<free-function-name>`. Run `make generate` once if you want to invoke `xcodebuild` directly without rebuilding the project each time. Toolchain: Swift 6 (strict concurrency), macOS 15 deployment target.

## Architecture

The data flow is **provider → RefreshEngine → AppState → SwiftUI**, all converging on the `Usage` value type.

- **`Usage` (`Model/Usage.swift`)** is the single currency of the app: `fiveHourPct` / `weeklyPct` (both optional — a window can be absent), reset dates, a `UsageSource` (`.endpoint` | `.localFile`), and a `UsageState` (`.ok` | `.stale` | `.unauthorized` | `.unavailable`). Almost every layer produces or consumes a `Usage`.

- **`UsageProvider` protocol (`Providers/UsageProvider.swift`)** — `refresh() async -> Usage` plus `reauthenticate() async`. Two implementations: `ClaudeProvider` and `CodexProvider`. Both are `Sendable` structs whose external dependencies (URLSession, Keychain, file reader, token store, clock) are injected via `init` defaults, which is what makes them unit-testable with stubs.

- **`RefreshEngine` (`Core/RefreshEngine.swift`, `@MainActor`)** owns all scheduling and is the heart of the app:
  - 60s poll timer + a separate 300s staleness tick (marks a tile `.stale` when its data ages out).
  - **Recursive filesystem watches** via `FSEventStream` (file-level events + watch-root) on `~/.claude` and `~/.codex/sessions`, coalesced over a 2s window, so a nested write like `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` triggers an immediate refresh.
  - Per-provider exponential **backoff** (`ProviderRefreshState`, 60→120→300→900s) on failure, and a wake-from-sleep observer that force-refreshes.
  - On a `401`/`.unauthorized`, it calls `provider.reauthenticate()` (adopt-only — see below) and retries once. If the retry still fails **but a prior successful reading exists**, the tile degrades to `.stale` (keeping the last-known percentages) instead of showing "sign in required"; the sign-in prompt appears only when no usage was ever read.
  - Holds `AppState`, the observable model that the UI reads.

- **`AppState` (`@Observable @MainActor`, in `RefreshEngine.swift`)** stores the latest `Usage` per provider. `MenuBarLabel` and `DetailPopover` observe it via `.environment(appState)`.

- **`App.swift`** is the composition root: it constructs `AppState`, `Notifier`, the real providers (or `MockUsageProvider` under tests, detected via `XCTestConfigurationFilePath`), wires them into `RefreshEngine`, and renders `MenuBarExtra` with `.menuBarExtraStyle(.window)`.

- **`Notifier` (`Core/Notifier.swift`)** posts a system notification when a usage window crosses **80%** or **95%**. Its sent/observation state is **in-memory by design** — relaunches rebuild slot state rather than persisting notification history.

### Credential handling (the core hazard)

The app reads OAuth credentials that **belong to the CLIs**, so it is a strictly **read-only monitor: it never performs an OAuth token refresh.** The refresh token is shared with the CLI and is rotated on use, so refreshing it here would invalidate the CLI's on-disk copy and force the user to re-login. Providers only read the current access token and *adopt* a newer one the CLI itself has written. Preserve this invariant — do not reintroduce a `grant_type=refresh_token` exchange in either provider.

- **Claude:** reads the macOS Keychain generic password `Claude Code-credentials` (`Core/Keychain.swift` — read-only wrapper), extracts the OAuth access token, and calls `https://api.anthropic.com/api/oauth/usage`. A disabled-by-default fallback reads a statusLine JSON file (`scripts/inference-meter-statusline.sh` tees Claude Code's statusLine into `~/.claude/inference-meter-status.json`).
- **Codex:** reads `~/.codex/auth.json` for the access token; if an endpoint is configured it calls that, otherwise it falls back to parsing the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` file **backwards** for the last `"rate_limits"` event.
- **`TokenStore` (`Core/TokenStore.swift`, actor)** tracks the CLI's current access token and fingerprints the owner credential to detect when a CLI has rotated it on disk (`adoptOwnerTokenIfChanged`). It never refreshes, and never writes back to the Keychain or `auth.json`.
- **`UsageNormalizer` (`Model/UsageNormalizer.swift`)** converts each raw dialect (Claude endpoint JSON, Claude statusLine JSON, Codex `rate_limits`) into a `Usage`. The endpoint schemas are documented in `docs/spikes/claude-endpoint.md` and `docs/spikes/codex-endpoint.md` — consult these before changing parsing.

**Secret safety is an enforced invariant:** token, credential, and header values must never reach stdout/stderr. `InferenceMeterTests/SecretSafetyTestHelpers.swift` captures fd-level output and tests assert no secret leaks. When touching provider or logging code, keep those assertions green.

## Testing conventions

- Swift Testing throughout (`@Test("description") func …`, `#expect`, `#require`).
- Provider tests stub the network with a custom `URLProtocol` and inject a closure-backed `Keychain` / `FileReader`; realistic inputs live in `InferenceMeterTests/Fixtures/` (`.json` endpoint/statusline responses, `.jsonl` Codex rollouts). Add a fixture rather than inlining large payloads.
- The `Usage`-producing layers are deterministic because time is injected (`now:` / `RefreshClock`) — pass a fixed clock instead of reading `Date()` in tests.
