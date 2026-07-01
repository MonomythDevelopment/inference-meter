# InferenceMeter

Native macOS menu bar usage monitor for Claude Code and Codex.

## Build Prerequisites

Install Xcode and XcodeGen before building. `xcodebuild` requires the active developer directory
to be full Xcode, not Command Line Tools only.

```sh
brew install xcodegen
```

The Xcode project is generated from `project.yml`. Do not commit `InferenceMeter.xcodeproj`.

## Build And Test

```sh
make build
make test
```

## Claude Provider Runtime Note

The first live Claude refresh reads the Claude Code OAuth credential from the macOS Keychain. macOS
may show a one-time permission prompt for `Claude Code-credentials`; choose "Always Allow" to let
InferenceMeter read future usage snapshots without prompting again. Usage snapshots flow through the
refresh engine; token, credential, and header values are never printed.
