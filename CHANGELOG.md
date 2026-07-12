# Changelog

All notable changes to InferenceMeter are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-07-12

First public release candidate.

### Added

- Native macOS menu bar usage monitoring for Claude Code and Codex.
- Five-hour and weekly usage windows with reset times.
- Claude Fable scoped usage when reported by the provider.
- Optional threshold notifications at 80% and 95%.
- Read-only adoption of CLI-owned authentication state.

### Fixed

- Preserve last-known usage during transient authorization and endpoint failures.
- Merge sparse Codex rate-limit windows across recent rollout files.
- Recognize current Claude and Codex CLI response shapes.

### Changed

- Adopt the Monomyth Development bundle identifier `dev.monomyth.InferenceMeter` for public releases. Users of pre-public builds must re-enable Launch at Login.

[Unreleased]: https://github.com/MonomythDevelopment/inference-meter/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/MonomythDevelopment/inference-meter/releases/tag/v0.1.2
