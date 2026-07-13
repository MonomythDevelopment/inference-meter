# InferenceMeter

[![CI](https://github.com/MonomythDevelopment/inference-meter/actions/workflows/ci.yml/badge.svg)](https://github.com/MonomythDevelopment/inference-meter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black.svg)](https://www.apple.com/macos/)

A private, native macOS menu bar meter for Claude Code and Codex usage limits.

InferenceMeter keeps Claude's five-hour and weekly windows plus Codex's provider-reported weekly window visible without opening either CLI. Claude's scoped Fable limit is shown when available, and threshold notifications can warn at 80% and 95%.

> [!IMPORTANT]
> InferenceMeter relies on provider-owned, undocumented usage data. Claude Code or Codex updates can change those formats without notice. The project is maintained on a best-effort basis and is not affiliated with, endorsed by, or supported by Anthropic or OpenAI.

## Features

- Native SwiftUI menu bar app with no Dock icon
- Claude Code five-hour, weekly, and Fable usage
- Codex usage windows reported by the installed CLI, with recent-session fallback
- Reset times and stale-data indicators
- Optional 80% and 95% macOS notifications
- Wake-from-sleep and Codex session-file refreshes
- Read-only credential handling with no analytics or telemetry

## Requirements

- macOS 15 or later
- Claude Code and/or Codex installed and signed in
- Full Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build from source

## Install

Download the latest signed build from [GitHub Releases](https://github.com/MonomythDevelopment/inference-meter/releases) when one is available, unzip it, and move `InferenceMeter.app` to `/Applications`.

To build a local copy instead:

```sh
brew install xcodegen
git clone https://github.com/MonomythDevelopment/inference-meter.git
cd inference-meter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
open DerivedData/Build/Products/Debug/InferenceMeter.app
```

The app appears only in the menu bar. It does not create a Dock icon.

### Moving from a pre-public build

The open-source release uses the Monomyth Development bundle identifier `dev.monomyth.InferenceMeter`. If you installed an earlier private build, quit and remove that copy before installing the public build, then re-enable **Launch at Login** from the popover if desired.

## Credentials and privacy

InferenceMeter is a read-only monitor. It reads credentials already owned by the CLIs:

- Claude Code's `Claude Code-credentials` item in macOS Keychain
- The installed Codex CLI's read-only `account/rateLimits/read` app-server method
- Codex session data under `~/.codex/sessions`
- `~/.codex/auth.json` only when a Codex endpoint is explicitly configured in code

The app never sends a refresh-token request and never writes OAuth credentials. Refresh tokens can rotate when used; independently refreshing one would invalidate the CLI's stored copy and cause repeated login prompts. When Claude's access token expires, InferenceMeter asks the installed Claude Code CLI to inspect its own auth state and adopts a newer Keychain token only if the CLI writes one.

Tokens, credentials, and authorization headers are not logged. The app contains no analytics, advertising, or update tracker. Claude network requests go directly to its provider endpoint. Codex network requests are delegated to the installed CLI so Codex remains the sole owner of its authentication lifecycle.

The first Claude refresh may trigger a macOS Keychain permission prompt. Choose **Always Allow** if you want future usage refreshes to occur without another prompt.

## Data freshness and limitations

- Claude requests are limited to one attempt every five minutes. The last successful reading remains visible through transient failures and is marked stale after fifteen minutes.
- Codex asks the installed CLI for its current account rate limits. If that interface is unavailable, Inference Meter falls back to snapshots from up to 20 recent rollout files and ignores windows whose reset time had already passed when they were recorded.
- A missing window is displayed as unavailable rather than inferred from another window.
- Provider schema changes may temporarily make a meter unavailable until the parser is updated.

Sanitized schema research lives in [`docs/spikes`](docs/spikes). Never attach credentials, Keychain exports, `auth.json`, or unsanitized rollout files to a public issue.

## Development

The Xcode project is generated from `project.yml`; do not edit or commit `InferenceMeter.xcodeproj`.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
```

Create a local release archive with:

```sh
./scripts/release.sh
```

Without `CODESIGN_IDENTITY`, the release script uses ad-hoc signing for local testing. Public distribution requires a Developer ID Application certificate and notarization credentials. Follow the project-specific [Apple distribution and notarization guide](docs/APPLE_DISTRIBUTION.md) for credential setup, signing, verification, and future GitHub Actions automation.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

Copyright © 2026 Monomyth Development. Released under the [MIT License](LICENSE).
