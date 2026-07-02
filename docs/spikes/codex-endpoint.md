# Codex Usage Endpoint Spike

Captured: 2026-07-01T21:01:50Z

## Outcome

Working endpoint: none viable.

endpoint not viable — use JSONL fallback.

## Probe Matrix

| URL | Header mode | HTTP status |
|---|---|---|
| `https://chatgpt.com/backend-api/api/codex/usage` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/usage` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/codex/usage` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/codex/usage` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/accounts/send_add_credits_nudge_email` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/accounts/send_add_credits_nudge_email` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/config/bundle` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/config/bundle` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/environments` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/environments` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/environments/by-repo/github` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/environments/by-repo/github` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/profiles/me` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/profiles/me` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/rate-limit-reset-credits/consume` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/rate-limit-reset-credits/consume` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/tasks` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/tasks` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/tasks/list` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/tasks/list` | without-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/workspace-messages` | with-account-header | `403` |
| `https://chatgpt.com/backend-api/api/codex/workspace-messages` | without-account-header | `403` |

## Headers

Every candidate path was probed with `Authorization: Bearer <redacted>`, and also with the optional `chatgpt-account-id: <redacted>` header.

The script sends credential material only in process memory to `curl`. No committed artifact stores bearer material, per-account header values, raw auth file data, or raw session JSONL content.

## Endpoint Response Schema

- No endpoint response schema was captured because no candidate returned JSON with HTTP 200.

Percent fields should be treated as provider-owned values. If endpoint fields diverge from the local fallback dialect, normalize them at the provider boundary rather than inside app UI code.

## 401/Auth Behavior

Probe URL: `https://chatgpt.com/backend-api/api/codex/usage`

Header mode: `with-account-header`

HTTP status: `403`

Sanitized body:

```
Non-JSON body, first 300 sanitized characters: <html> <head> <meta name="viewport" content="width=device-width, initial-scale=1" /> <style global>body{font-family:Arial,Helvetica,sans-serif}.container{align-items:center;display:flex;flex-direction:column;gap:2rem;height:100%;justify-content:center;width:100%}@keyframes enlarge-appear{0%{opacity:
```

No literal 401 was observed during this run; invalid bearer probes returned the status above. IM-010 should treat this status/body combination as the observed auth failure signal for the endpoint path. If future probes return a different status for expired credentials, prefer matching both status code and response shape rather than relying on status code alone.

## Token Freshness Notes

- The auth file's refresh timestamp field was present during this run; its value was not copied into the repo.
- The script reads the auth file at startup and does not attempt refresh. IM-010 should first try re-reading the auth file after a live Codex CLI refresh, because the CLI owns refresh and rewrites this file.
- IM-010 inspected the official OpenAI Codex source (`codex-rs/login/src/auth/manager.rs`) to capture the refresh-token request. Codex refreshes against `https://auth.openai.com/oauth/token`, not the account-context API path. The request is JSON:

```text
POST https://auth.openai.com/oauth/token
Content-Type: application/json

client_id: app_EMoamEEZ73f0CkXaXp7hrann
grant_type: refresh_token
refresh_token: tokens.refresh_token from auth.json
```

The response includes `access_token` and may include a rotated `refresh_token`. Inference Meter uses
only the returned access token and keeps it in memory. It never writes `~/.codex/auth.json`, leaving
Codex's own `last_refresh` bookkeeping untouched.

Sanitized fixture captures for the request, success body, and failure body are committed under
`InferenceMeterTests/Fixtures/codex-token-refresh-*.json`. The fixture values are redacted and do
not contain live bearer material.

## JSONL Fallback Fixture

Fixture: `InferenceMeterTests/Fixtures/codex-rollout-rate-limits.jsonl`

- `primary.window_minutes`: `300`
- `secondary.window_minutes`: `10080`
- `plan_type`: `pro`

Mapping notes:

- Match the five-hour window by `window_minutes == 300`.
- Match the weekly window by `window_minutes == 10080`.
- Do not infer window meaning from object order or from `primary` / `secondary` position alone.
- Local-file values are only as fresh as the most recent Codex CLI activity; label the source separately from endpoint values in the normalized usage model.
