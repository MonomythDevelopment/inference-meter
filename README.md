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

## Release Build And Install

Build a local release artifact with:

```sh
./scripts/release.sh
```

The script regenerates the Xcode project, builds the Release app, signs it, and writes a zip to
`dist/`. If `CODESIGN_IDENTITY` is set, the app is signed with that Developer ID Application
identity, submitted through `xcrun notarytool`, and stapled. Set `NOTARYTOOL_KEYCHAIN_PROFILE` to
the keychain profile name when notarization credentials are stored in the keychain.

Without `CODESIGN_IDENTITY`, the script uses ad-hoc signing so the app bundle is launchable but not
signed for public distribution. After unzipping the artifact, macOS Gatekeeper may block the first
launch. Use Finder to right-click `InferenceMeter.app` and choose **Open**, or clear quarantine:

```sh
xattr -dr com.apple.quarantine /path/to/InferenceMeter.app
```

Move `InferenceMeter.app` to `/Applications` or another local folder, then launch it. The app is a
menu bar item only, so it does not appear in the Dock.

## Credentials And Privacy

InferenceMeter is a strictly **read-only** monitor. It reads the credentials the Claude Code and
Codex CLIs already store on this machine — the `Claude Code-credentials` item in the macOS Keychain
and `~/.codex/auth.json` — and calls the providers' usage endpoints with the current access token.

It **never sends a refresh-token request and never writes credentials.** Each CLI's refresh token is
rotated on use, so refreshing it directly here would invalidate the CLI's own copy and force you to
log in again. When Claude's access token expires, InferenceMeter asks the installed Claude Code CLI
to inspect its own auth state, then adopts the newer Keychain token only if Claude Code renewed it.
Codex credentials remain entirely file-observed. Token, credential, and header values are never
printed.

Claude endpoint requests are limited to one attempt every five minutes and use exponential backoff
after failures. Transient endpoint failures keep the last successful values visible; Claude data is
marked stale only after fifteen minutes without a successful refresh. Codex continues to update from
session-file events and merges sparse rate-limit snapshots by their declared window duration.

The first live Claude refresh reads the Keychain credential, so macOS may show a one-time permission
prompt for `Claude Code-credentials`; choose "Always Allow" to let InferenceMeter read future usage
snapshots without prompting again.
