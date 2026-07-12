# Security Policy

InferenceMeter reads authentication material owned by local CLI tools, so credential safety is a core project invariant.

## Supported versions

Security fixes are made on the latest released version and the `main` branch. Older releases may not receive patches.

## Report a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private **Report a vulnerability** flow from the repository's Security tab. If that option is unavailable, email `chris@monomyth.dev` with the subject `InferenceMeter security report`.

Include:

- A concise description and potential impact
- Reproduction steps or a proof of concept
- The affected commit or version
- Any suggested mitigation

Do not send live tokens, refresh tokens, Keychain exports, or an unredacted `auth.json`. Use unmistakable placeholder values and remove prompts or user content from session samples.

You should receive an acknowledgment within seven days. Please allow time for investigation and a coordinated fix before public disclosure.

## Security boundaries

InferenceMeter is designed to read current CLI-owned state. It must not:

- Perform an OAuth refresh-token exchange
- Write credentials to the Keychain or CLI files
- Log credential payloads or authorization headers
- Upload usage or credential data to Monomyth Development

Provider endpoint and file formats are undocumented and may change. A compatibility break without credential exposure is normally a bug rather than a security vulnerability.
