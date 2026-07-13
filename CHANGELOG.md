# Changelog

All notable changes to InferenceMeter are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.4] - 2026-07-13

Codex quota-window restoration release after its five-hour limit proved to be temporarily absent rather than retired.

### Fixed

- Restore Codex five-hour usage in the menu-bar label, detail popover, and 80%/95% threshold notifications.
- Accept app-server responses that provide the Codex snapshot only in `rateLimitsByLimitId`.
- Keep an omitted five-hour window unavailable until Codex reports it again instead of showing an expired local value.

## [0.1.3] - 2026-07-13

Codex compatibility release following the upstream removal of its five-hour usage window.

### Added

- Add a native macOS About panel with Monomyth Development, project, and license details.

### Fixed

- Prefer Codex's live CLI rate-limit snapshot and ignore expired legacy windows left in rollout files after an upstream quota change.

### Changed

- Use the installed Codex CLI's read-only app-server interface before falling back to recent session data.
- Remove Codex's retired five-hour meter and threshold notifications while keeping Claude's five-hour window unchanged.

## [0.1.2] - 2026-07-12

First public source release. A signed and notarized app archive will be added when Monomyth Development's Apple distribution credentials are available.

### Added

- Native macOS menu bar usage monitoring for Claude Code and Codex.
- Five-hour and weekly usage windows with reset times.
- Claude Fable scoped usage when reported by the provider.
- Optional threshold notifications at 80% and 95%.
- Read-only adoption of CLI-owned authentication state.
- MIT licensing and Monomyth Development project identity.
- Public contribution, security, support, and conduct policies.
- GitHub issue forms, pull request guidance, and macOS CI.

### Fixed

- Preserve last-known usage during transient authorization and endpoint failures.
- Merge sparse Codex rate-limit windows across recent rollout files.
- Recognize current Claude and Codex CLI response shapes.

### Changed

- Adopt the Monomyth Development bundle identifier `dev.monomyth.InferenceMeter` for public releases. Users of pre-public builds must re-enable Launch at Login.

[Unreleased]: https://github.com/MonomythDevelopment/inference-meter/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/MonomythDevelopment/inference-meter/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/MonomythDevelopment/inference-meter/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/MonomythDevelopment/inference-meter/releases/tag/v0.1.2
