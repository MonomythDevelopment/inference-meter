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

- [ ] Enable private vulnerability reporting.
- [x] Add the repository description, homepage, and topics.
- [ ] Protect `main` and require the `Test and build` CI check.
- [x] Confirm issue labels referenced by the forms exist (`bug` and `enhancement`).
- [x] Keep Discussions disabled for the initial release; use focused issue forms for support and proposals.
- [ ] Change repository visibility to public only after every blocking item is complete.

## Source release

- [x] Confirm `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- [x] Run `make test` and `make build` from a clean checkout.
- [x] Build and verify a local ad-hoc universal archive to validate the release script.
- [ ] Create the `v0.1.2` tag and GitHub source release.

## Signed binary distribution

- [ ] Build with a Monomyth Development Developer ID Application certificate.
- [ ] Notarize the app, staple the ticket, and verify Gatekeeper acceptance.
- [ ] Confirm the app launches on a clean macOS user account and reads neither credential without user authorization.
- [ ] Upload `InferenceMeter-0.1.2.zip` and a SHA-256 checksum.
- [ ] Verify the release instructions and download on a separate Mac or clean VM.

## After publication

- [ ] Verify GitHub detects the MIT license and renders all community files.
- [ ] Verify the CI badge and public links in `README.md`.
- [ ] Announce the support and security boundaries with the release.
- [ ] Monitor the first public issues for accidental credential disclosure.
