## Summary

Describe the user-visible outcome and the reason for the change.

## Related issue

Closes #

## Verification

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build`
- [ ] `git diff --check`
- [ ] UI changes include a screenshot or an explanation of why one is unavailable

## Security and privacy

- [ ] The read-only OAuth model is preserved
- [ ] Fixtures and diagnostics are sanitized
- [ ] No tokens, credentials, authorization headers, prompts, or user session content are included
