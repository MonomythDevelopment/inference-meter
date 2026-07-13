# Open-source release checklist

Use this checklist before changing the repository from private to public.

## Source and community health

- [x] Add a detectable open-source license.
- [x] Attribute the project to Monomyth Development.
- [x] Document installation, privacy boundaries, limitations, and non-affiliation.
- [x] Add contribution, support, conduct, and security policies.
- [x] Add issue forms, a pull request template, and read-only CI permissions.
- [x] Verify the `Test and build` workflow passes on GitHub's macOS runner.
- [x] Replace the pre-public bundle identifier with `dev.monomyth.InferenceMeter`.
- [x] Scan the current tree and complete Git history with Gitleaks, narrowly documenting the historical public OAuth client metadata false positive.
- [x] Rewrite the complete public history to remove local environment metadata and deleted planning files. Publish into a fresh canonical repository so immutable pull-request refs remain private.

## GitHub settings

- [x] Enable private vulnerability reporting.
- [x] Add the repository description, homepage, and topics.
- [x] Protect `main` and require the `Test and build` CI check.
- [x] Confirm issue labels referenced by the forms exist (`bug` and `enhancement`).
- [x] Keep Discussions disabled for the initial release; use focused issue forms for support and proposals.
- [x] Publish the sanitized canonical repository while retaining legacy pull-request refs in a private archive.

## Source release

- [x] Confirm `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- [x] Run `make test` and `make build` from a clean checkout.
- [x] Build and verify a local ad-hoc universal archive to validate the release script.
- [x] Create the `v0.1.2` tag and GitHub source release.

## Signed binary distribution

> Blocked on distribution credentials: the release Mac has no Monomyth Development Developer ID Application identity or notarization keychain profile. Never publish the ad-hoc validation archive. Follow [Apple distribution credentials and notarization](APPLE_DISTRIBUTION.md) for the complete setup and validation process.

- [ ] Build with a Monomyth Development Developer ID Application certificate.
- [ ] Notarize the app, staple the ticket, and verify Gatekeeper acceptance.
- [ ] Confirm the app launches on a clean macOS user account and reads neither credential without user authorization.
- [ ] Upload the current version's signed ZIP and SHA-256 checksum.
- [ ] Verify the release instructions and download on a separate Mac or clean VM.

## After publication

- [x] Verify GitHub detects the MIT license and renders all community files.
- [x] Verify the CI badge and all public documentation links.
- [x] Announce the support and security boundaries with the release.
- [ ] Monitor the first public issues for accidental credential disclosure.
