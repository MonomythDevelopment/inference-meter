# Apple distribution credentials and notarization

This guide records the one-time Apple setup and repeatable release process for distributing InferenceMeter outside the Mac App Store.

InferenceMeter can always be built locally with an ad-hoc signature. A public application archive must instead be signed with a **Developer ID Application** certificate and notarized by Apple. Never publish the ad-hoc archive produced when `CODESIGN_IDENTITY` is unset.

## Required credentials

A public binary release needs:

1. An active Apple Developer Program membership.
2. A Developer ID Application certificate and its private key installed in the release Mac's Keychain.
3. Apple notarization credentials stored in a `notarytool` Keychain profile.

InferenceMeter ships as a ZIP containing an app bundle, so it does not need a Developer ID Installer certificate. That certificate is for signed installer packages such as `.pkg` files.

## 1. Enroll in the Apple Developer Program

Sign in at [developer.apple.com/account](https://developer.apple.com/account/) and confirm that the account has an active paid membership.

Choose the membership type carefully:

- Enroll as an organization if Monomyth Development is a recognized legal entity that can enter contracts. Apple requires the organization's legal name, a D-U-N-S Number, an organization-domain email address, a public website, and an Account Holder with authority to bind the organization.
- Enroll as an individual if Monomyth Development is only a DBA, trade name, or sole-proprietor brand that Apple does not recognize as a separate legal entity. Apple will associate the membership and signing identity with the individual's legal name.

Apple's current requirements and pricing are on the [Apple Developer Program enrollment page](https://developer.apple.com/programs/enroll/).

## 2. Create a Developer ID Application certificate

The Apple Developer Program Account Holder can create the certificate through Xcode or the developer portal. The portal flow makes the certificate/private-key relationship explicit:

1. Open **Keychain Access** on the Mac that will sign releases.
2. Choose **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority**.
3. Enter the Apple Developer account email, select **Saved to disk**, and save the `.certSigningRequest` file.
4. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
5. Click the add button (`+`), select **Developer ID**, and then select **Developer ID Application**.
6. Upload the certificate signing request.
7. Download the resulting `.cer` file.
8. Double-click the `.cer` file to install it in Keychain Access.

In Keychain Access, open **My Certificates**. The Developer ID Application certificate must have a private key nested beneath it. The private key was created with the certificate signing request and never left that Mac; downloading the `.cer` alone on another Mac does not recreate the private key.

Verify the installed signing identity:

```sh
security find-identity -v -p codesigning
```

Expected output includes an identity similar to:

```text
Developer ID Application: Monomyth Development (ABCDE12345)
```

If the release must move to another Mac, export the certificate and private key from Keychain Access as a password-protected `.p12`. Keep that backup encrypted and outside the repository. Never commit or upload the `.p12` as an ordinary artifact.

Apple's complete certificate instructions are in [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

## 3. Create a notarization Keychain profile

The current local release script uses an Apple Account app-specific password stored by `notarytool` in Keychain.

### Generate an app-specific password

1. Confirm that two-factor authentication is enabled for the Apple Account.
2. Sign in at [account.apple.com](https://account.apple.com/).
3. Open **Sign-In and Security → App-Specific Passwords**.
4. Generate a password named `Inference Meter Notarization`.

Apple documents app-specific passwords in [Apple Support](https://support.apple.com/en-us/102654).

### Store the profile securely

Find the ten-character Apple Developer Team ID in the membership details, then run:

```sh
xcrun notarytool store-credentials "inference-meter-notary" \
  --apple-id "APPLE_ACCOUNT_EMAIL" \
  --team-id "APPLE_TEAM_ID"
```

Do not add `--password` to the command. With that option omitted, `notarytool` securely prompts for the app-specific password, validates it, and stores it in Keychain without putting the secret in shell history.

Confirm that the stored profile works:

```sh
xcrun notarytool history \
  --keychain-profile "inference-meter-notary"
```

Changing or resetting the primary Apple Account password revokes its app-specific passwords. Generate and store a new one if notarization later begins failing authentication.

Apple's supported command-line flow is documented in [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## 4. Build from the exact release source

A public binary must match the commit referenced by its Git tag. Do not build an asset from a newer `main` commit and attach it to an older release.

For the existing v0.1.4 source release, use a clean checkout or temporary worktree at that tag:

```sh
git fetch origin --tags
git worktree add ../inference-meter-v0.1.4 v0.1.4
cd ../inference-meter-v0.1.4
git status --short
```

For a future release, first update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, move the user-facing changelog entries into a dated release section, merge through CI, and create the Git tag. Substitute that tag everywhere below.

Run the complete test suite before signing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
```

## 5. Sign, notarize, staple, and package

Set the identity to the exact value printed by `security find-identity`:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Monomyth Development (APPLE_TEAM_ID)"
export NOTARYTOOL_KEYCHAIN_PROFILE="inference-meter-notary"
```

Run the release script:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/release.sh
```

With both environment variables set, the script:

1. Generates the Xcode project.
2. Builds the universal Release app.
3. Signs it with the Developer ID identity, Hardened Runtime, a secure timestamp, and the app's production bundle identifier.
4. Creates a temporary ZIP and submits it to Apple's notary service.
5. Waits for Apple's result.
6. Staples the notarization ticket to the app.
7. Verifies the signature and creates the final `dist/InferenceMeter-<version>.zip`.

If `CODESIGN_IDENTITY` is unset, the script intentionally falls back to an ad-hoc local build. That archive is for testing only and must not be uploaded to GitHub Releases.

Apple's current notarization requirements are documented in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 6. Verify the distributable artifact

Set the release version and app paths:

```sh
VERSION="0.1.4"
APP_PATH="DerivedData/Release/Build/Products/Release/InferenceMeter.app"
ZIP_PATH="dist/InferenceMeter-${VERSION}.zip"
```

Verify the signature, notarization ticket, and Gatekeeper assessment:

```sh
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
```

The detailed signature output should show:

- `Identifier=dev.monomyth.InferenceMeter`
- `Authority=Developer ID Application: ...`
- A non-empty `TeamIdentifier`
- Hardened Runtime flags

The Gatekeeper assessment should report the app as accepted and identify it as notarized Developer ID software.

Confirm that the bundle metadata and archive are the intended release:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP_PATH/Contents/Info.plist"
file "$APP_PATH/Contents/MacOS/InferenceMeter"
shasum -a 256 "$ZIP_PATH"
```

The executable should contain both `arm64` and `x86_64` architectures.

Finally, extract the ZIP on a clean macOS account or separate Mac and verify that:

- Gatekeeper opens the app without an unsigned-developer workaround.
- The app displays the expected version in **About Inference Meter**.
- Claude Keychain access is requested only when needed.
- Codex usage works without exposing or copying CLI credentials.
- Launch at Login can be enabled and survives a restart.

## 7. Attach the binary to GitHub Releases

Create a checksum file beside the final ZIP:

```sh
shasum -a 256 "$ZIP_PATH" | tee "${ZIP_PATH}.sha256"
```

Attach the signed ZIP and checksum to the matching existing release:

```sh
gh release upload "v${VERSION}" \
  "$ZIP_PATH" \
  "${ZIP_PATH}.sha256" \
  --clobber
```

Verify the public release and its asset names:

```sh
gh release view "v${VERSION}"
```

Do not move or recreate a published tag to make an asset fit. If source code changed after the tag, publish a new patch version and build from that new tag.

## GitHub Actions automation

Complete at least one local signed and notarized release before automating the process. That proves the Apple account, certificate, entitlements, script, and notarization path independently of CI.

A future GitHub Actions release workflow will need to:

1. Run only for an explicit version tag or manual release dispatch.
2. Import a password-protected Developer ID `.p12` into a temporary runner Keychain.
3. Create temporary notarization credentials from GitHub Actions secrets.
4. Run tests and the release script on a macOS runner.
5. Verify `codesign`, `stapler`, and `spctl` results.
6. Upload only the final signed/notarized ZIP and checksum to the matching GitHub release.
7. Delete the temporary Keychain and credential files even when the job fails.

Likely repository secrets include:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

An App Store Connect API key can replace Apple Account password authentication and is preferable for durable CI. Supporting that path will require extending `scripts/release.sh` or creating the expected temporary `notarytool` profile in the workflow.

Never print these secrets, include them in build artifacts, expose them to pull requests from forks, or pass them to an untrusted third-party action.

## Troubleshooting

### `0 valid identities found`

The Developer ID certificate, its private key, or both are missing from the active Keychain. A `.cer` installed without the private key cannot sign the app. Create the certificate request on this Mac or import the original password-protected `.p12`.

### `No Keychain password item found for profile`

The `NOTARYTOOL_KEYCHAIN_PROFILE` name does not match a stored profile. Run `notarytool store-credentials` again using the exact profile name.

### Notarization returns `Invalid`

Retrieve the submission log using the identifier printed by `notarytool`:

```sh
xcrun notarytool log "SUBMISSION_ID" \
  --keychain-profile "inference-meter-notary" \
  notarization-log.json
```

Review the log for unsigned nested code, missing timestamps, Hardened Runtime failures, invalid entitlements, or bundle metadata problems. Do not commit the log until it has been checked for machine-specific or account-specific information.

### `spctl` rejects an otherwise valid local build

Confirm that the signature authority is Developer ID rather than ad-hoc, the notarization request was accepted, and `stapler validate` succeeds. Repack the ZIP only after stapling the app.

## Official references

- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple Account app-specific passwords](https://support.apple.com/en-us/102654)
