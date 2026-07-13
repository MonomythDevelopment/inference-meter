# CLAUDE.md

This file provides guidance to Claude Code when working in this repository. Read `AGENTS.md` first; it contains the authoritative repository workflow and security constraints.

## Open source

This is the public Monomyth Development repository (`MonomythDevelopment/inference-meter`), MIT licensed, with a sanitized history. Everything committed here is public: never commit secrets, personal paths, machine-specific environment details, or unsanitized provider captures.

- Bundle identifier is `dev.monomyth.InferenceMeter`; version and build numbers live in `project.yml`, not the generated project.
- GitHub Actions CI (`.github/workflows/ci.yml`) runs `make test` and `make build` on macOS 15 for every push to `main` and every PR; `main` is protected, so keep it green.
- `CHANGELOG.md` follows Keep a Changelog / SemVer — add an `[Unreleased]` entry for user-facing changes.
- Community policy files (`CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, `CODE_OF_CONDUCT.md`) and GitHub issue/PR templates are in place; releases follow `docs/OPEN_SOURCE_RELEASE_CHECKLIST.md`.
- v0.1.2 shipped as a source-only release; attaching a signed, notarized binary is blocked on Monomyth Apple distribution credentials.

## Build and test

InferenceMeter is a Swift 6 / SwiftUI macOS 15 menu bar app. XcodeGen generates `InferenceMeter.xcodeproj` from `project.yml`, so the generated project is disposable and must not be committed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
make clean
./scripts/release.sh
```

Tests use Swift Testing (`@Test` and `#expect`), not XCTest test cases. Keep network, Keychain, filesystem, and time behavior injected and fixture-backed.

## Architecture

Data flows from a provider through `RefreshEngine` and `AppState` to SwiftUI.

- `Model/Usage.swift` defines the shared value: optional five-hour, weekly, and Fable percentages and reset dates; command-line, endpoint, or local-file source; and `ok`, `stale`, `refreshRequired`, `unauthorized`, or `unavailable` state.
- `Providers/UsageProvider.swift` defines `refresh() async -> Usage` and `reauthenticate() async -> Bool`.
- `Providers/ClaudeProvider.swift` reads Claude Code's Keychain credential and calls the Claude usage endpoint.
- `Providers/CodexProvider.swift` asks the installed Codex CLI app-server for current rate limits, then falls back to merging non-expired snapshots across recent rollout files. Direct endpoint support remains injectable but is not configured by the app.
- `Core/RefreshEngine.swift` handles polling, provider-specific minimum intervals, exponential backoff, staleness, wake events, and Codex filesystem events.
- `Core/Notifier.swift` emits deduplicated 80% and 95% notifications for available windows.
- `UI/` contains the menu bar label and detail popover.

The engine polls every 60 seconds. Claude endpoint attempts are limited to every five minutes and Claude readings become stale after fifteen minutes without success. Codex session writes are coalesced over two seconds and trigger a refresh.

## Credential safety

The CLIs own their OAuth credentials. InferenceMeter is strictly read-only: it must never perform a refresh-token exchange or write the Keychain credential or `~/.codex/auth.json`. Refresh tokens rotate, so using one independently can invalidate the CLI's copy and force a login.

Claude reauthentication may invoke `claude auth status --json` with all output discarded. This only asks the owner CLI to inspect or renew its own state; the provider then adopts a newer access token if the Keychain credential changed. Codex only adopts CLI-written state.

Never print tokens, credentials, authorization headers, or raw owner payloads. Secret-safety tests capture stdout and stderr at the file-descriptor level; keep them green. Fixtures and issue attachments must be sanitized.

Provider schemas are documented in `docs/spikes/claude-endpoint.md` and `docs/spikes/codex-endpoint.md`.
