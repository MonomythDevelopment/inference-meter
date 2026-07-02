# Repository Guidelines

## Project Structure & Module Organization

Inference Meter is a Swift 6 macOS menu bar app generated with XcodeGen. Source lives under `InferenceMeter/`:

- `App.swift` wires the `MenuBarExtra`, providers, refresh engine, and notifier.
- `Core/` contains refresh, notification, keychain, token, and file-watching logic.
- `Providers/` contains Claude and Codex usage providers.
- `Model/` contains usage models and normalizers.
- `UI/` contains the menu bar label and popover views.

Tests live in `InferenceMeterTests/`, with fixtures in `InferenceMeterTests/Fixtures/`. Supporting scripts are in `scripts/`; spike notes and endpoint research are in `docs/spikes/`.

## Build, Test, and Development Commands

- `make generate` regenerates `InferenceMeter.xcodeproj` from `project.yml`.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build` builds the app.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` runs the Swift Testing suite.
- `make clean` removes generated project/build artifacts.
- `./scripts/release.sh` builds, signs, verifies, and packages `dist/InferenceMeter-<version>.zip`.

Use full Xcode, not Command Line Tools only. `xcodegen` is required (`brew install xcodegen`).

## Coding Style & Naming Conventions

Use idiomatic Swift with four-space indentation. Prefer small, focused types and clear names such as `RefreshEngine`, `CodexProvider`, and `UsageNormalizer`. Keep UI-specific code in `UI/`, provider-specific parsing/auth behavior in `Providers/`, and shared app behavior in `Core/`.

Avoid logging secrets or full auth payloads. Preserve the read-only OAuth model: the app may adopt CLI-refreshed tokens, but must not refresh/write OAuth credentials itself.

## Testing Guidelines

Tests use Swift Testing (`import Testing`) and `@Test("descriptive behavior")`. Add focused coverage for provider parsing, refresh-state transitions, notifier dedupe, and UI formatting. Keep real network, Keychain, and filesystem behavior injectable or fixture-backed. Run `make test` before opening a PR.

## Commit & Pull Request Guidelines

Recent history uses conventional prefixes with issue references, for example `fix: preserve stale usage on transient unauthorized (#30)` and `test: add provider secret safety fixtures (#26)`. Keep commits scoped and descriptive.

PRs should include a short summary, linked issue (`Closes #NN` when applicable), and verification commands. For UI or macOS behavior, include screenshots or explicit notes when Screen Recording/Accessibility permissions block visual verification.

## Security & Configuration Tips

Do not commit real tokens, Keychain exports, `~/.codex/auth.json`, or unsanitized endpoint captures. Release artifacts in `dist/` and generated build output are not source of truth; update `project.yml` for version changes.
