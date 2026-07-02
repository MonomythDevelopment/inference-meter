# Claude Code usage endpoint spike

Date: 2026-07-01

This spike verifies the Claude Code OAuth usage endpoint for the future Claude provider. It does
not add app code or Swift parser code.

## Reproduction

Run:

```bash
spikes/claude-usage-spike.sh
```

The script reads the Claude Code OAuth credential from macOS Keychain, calls the usage endpoint,
prints only schema information plus the 5-hour and weekly percentages, writes raw HTTP bodies only
under `/private/tmp`, and emits a sanitized fixture candidate. It never prints the credential blob,
the access token, the refresh token, or a complete Authorization header value.

The script defaults to:

- Keychain service: `Claude Code-credentials`
- Keychain account: current macOS short username from `id -un`
- Claude binary: `~/.local/share/claude/versions/2.1.197`
- Endpoint: `https://api.anthropic.com/api/oauth/usage`

Each default can be overridden with `CLAUDE_KEYCHAIN_SERVICE`, `CLAUDE_KEYCHAIN_ACCOUNT`,
`CLAUDE_BIN`, or `CLAUDE_USAGE_URL`. By default the script makes the minimal request needed to
print live usage. Set `CLAUDE_USAGE_PROBE_ALL=1` to test every optional header combination and
`CLAUDE_USAGE_CHECK_401=1` to reproduce the documented invalid-token shape. These are opt-in
because repeated probes can trigger HTTP 429 rate limiting.

## Credential JSON structure

Observed Keychain generic-password value shape:

```text
claudeAiOauth.accessToken: string
claudeAiOauth.expiresAt: number
claudeAiOauth.rateLimitTier: string
claudeAiOauth.refreshToken: string
claudeAiOauth.scopes[]: string
claudeAiOauth.subscriptionType: string
```

Only key names and value types are documented here. No credential values are committed.

## Binary hints

Filtered strings from the Claude Code `2.1.197` binary include:

```text
/api/oauth/usage
anthropic-beta
anthropic-version
https://platform.claude.com/v1/oauth/token
oauth-2025-04-20
x-app
x-app-name
x-app-ver
```

The OAuth token endpoint is recorded for IM-010. The binary exposes the URL string and an
`oauth-refresh` hint, but this spike did not safely confirm the refresh request body.

## OAuth token refresh request shape

IM-010 inspected the installed Claude Code `2.1.198` binary without reading or printing credential
values. The minified OAuth refresh helper builds this JSON request:

```text
POST https://platform.claude.com/v1/oauth/token
Content-Type: application/json

grant_type: refresh_token
refresh_token: Keychain credential's claudeAiOauth.refreshToken
client_id: credential clientId when present, otherwise 9d1c250a-e61b-44d9-88ed-5944d1962f5e
scope: credential scopes when present, otherwise user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload
```

The response includes `access_token`, may include a rotated `refresh_token`, and includes
`expires_in` plus `scope`. Inference Meter uses only the returned access token and keeps it in
memory. It does not write the Claude Code Keychain item.

Sanitized fixture captures for the request, success body, and failure body are committed under
`InferenceMeterTests/Fixtures/claude-token-refresh-*.json`. The fixture values are redacted and do
not contain live bearer material.

## Request headers

Confirmed sufficient request:

```text
GET https://api.anthropic.com/api/oauth/usage
Authorization: OAuth bearer token from the Keychain credential
```

The following optional variants were also tested during the spike:

```text
Authorization + anthropic-beta: oauth-2025-04-20
Authorization + anthropic-version: 2023-06-01
Authorization + anthropic-beta: oauth-2025-04-20 + anthropic-version: 2023-06-01
```

Conclusion: the only required header observed on this machine is `Authorization`. The beta and
version headers are discoverable in the binary, but neither was required for
`GET /api/oauth/usage` on 2026-07-01. Rapid repeated probes can produce HTTP 429, so the committed
script defaults to the minimal sufficient request and only tries optional headers if needed.

## Successful response schema

The endpoint returned one JSON object.

Observed top-level keys:

```text
five_hour: object
seven_day: object
seven_day_oauth_apps: null
seven_day_opus: null
seven_day_sonnet: null
seven_day_cowork: null
seven_day_omelette: null
tangelo: null
iguana_necktie: null
omelette_promotional: null
nimbus_quill: null
cinder_cove: null
amber_ladder: null
extra_usage: object
limits: array
spend: object
member_dashboard_available: boolean
```

`five_hour` and `seven_day` each had:

```text
utilization: number
resets_at: string
limit_dollars: null
used_dollars: null
remaining_dollars: null
```

Important correction to the planning assumption: the observed `utilization` values were already
percentage-scale values, not 0-1 fractions. They matched the corresponding `limits[].percent`
values. The provider should still guard for a future 0-1 fraction by multiplying only values
`<= 1` by 100.

`resets_at` was an ISO 8601 timestamp string, not unix seconds.

Absent or null window objects must be treated as `unavailable`, never as `0%`.

`limits[]` entries had:

```text
kind: string
group: string
percent: number
severity: string
resets_at: string
scope: object or null
is_active: boolean
```

The observed scoped limit contained:

```text
scope.model.id: null
scope.model.display_name: string
scope.surface: null
```

`extra_usage` had:

```text
is_enabled: boolean
monthly_limit: number
used_credits: number
utilization: null
currency: string
decimal_places: number
disabled_reason: null
daily: null
weekly: null
```

`spend` had:

```text
used.amount_minor: number
used.currency: string
used.exponent: number
limit.amount_minor: number
limit.currency: string
limit.exponent: number
percent: number
severity: string
enabled: boolean
disabled_reason: null
cap.money: null
cap.credits.amount_minor: number
cap.credits.exponent: number
balance: null
auto_reload: null
disclaimer: string
can_purchase_credits: boolean
can_toggle: boolean
```

## Invalid-token behavior

A deliberately invalid bearer token produced HTTP 401 with this body shape:

```text
type: string
error.type: string
error.message: string
error.details.error_visibility: string
request_id: string
```

The observed `error.type` was `authentication_error`. The actual `request_id` value is not
committed and must be scrubbed from any fixture.

## Fixture

The sanitized success fixture is committed at:

```text
InferenceMeterTests/Fixtures/claude-usage-response.json
```

It preserves the observed response structure and realistic values while excluding tokens, cookies,
account identifiers, organization identifiers, request IDs, and Authorization values.

## Fallback statusLine path

The direct endpoint succeeded, so the statusLine fallback was not exercised for this issue. Later
Claude provider work should still keep the fallback boundary because the binary and plan indicate
statusLine can provide `five_hour` and `seven_day` values using `used_percentage` plus `resets_at`.
