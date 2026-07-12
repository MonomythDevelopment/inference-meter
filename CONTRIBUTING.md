# Contributing to InferenceMeter

Thank you for helping make InferenceMeter more reliable. Bug reports, sanitized provider-shape research, tests, documentation, and focused code changes are welcome.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you begin

- Search existing issues and pull requests before opening a duplicate.
- Never post access tokens, refresh tokens, Keychain exports, `~/.codex/auth.json`, raw authorization headers, or unsanitized rollout files.
- Use the issue forms. For a suspected vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening an issue.
- Keep changes focused. Discuss broad architecture or behavior changes in an issue before investing in an implementation.

## Development setup

You need macOS 15 or later, full Xcode, and XcodeGen:

```sh
brew install xcodegen
git clone https://github.com/MonomythDevelopment/inference-meter.git
cd inference-meter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
```

`InferenceMeter.xcodeproj` is generated from `project.yml`. Do not edit or commit the generated project.

## Code expectations

- Use idiomatic Swift 6 with four-space indentation and strict concurrency safety.
- Keep provider parsing and authentication behavior in `Providers/`, shared behavior in `Core/`, models in `Model/`, and SwiftUI in `UI/`.
- Preserve the read-only credential model. The app may adopt CLI-written access tokens, but it must never refresh or write OAuth credentials itself.
- Keep real network, Keychain, filesystem, process, and clock behavior injectable.
- Add focused Swift Testing coverage for parsing, state transitions, notifications, and formatting.
- Put realistic, fully sanitized payloads in `InferenceMeterTests/Fixtures/` instead of embedding large payloads in tests.
- Do not log credential payloads, tokens, authorization headers, or secret-derived values.

## Provider format changes

Claude Code and Codex formats can change without notice. A provider-compatibility pull request should include:

1. A minimal sanitized fixture that reproduces the new shape.
2. A failing test for that fixture before the parser change.
3. A backward-compatible parser change when the old and new shapes can coexist.
4. Updated schema notes in `docs/spikes/` without machine-specific or account-specific data.

Replace tokens and IDs with obvious sentinels, remove prompts and user content from rollout samples, and inspect the entire fixture before committing it.

## Pull requests

Before opening a pull request, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
git diff --check
```

Use a scoped, descriptive commit message such as `fix: parse sparse Codex rate limits`. Explain user-visible behavior, link the relevant issue, and list the verification commands you ran. Include a screenshot for UI changes when practical.

Contributions are accepted under the repository's [MIT License](LICENSE).
