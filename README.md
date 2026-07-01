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
