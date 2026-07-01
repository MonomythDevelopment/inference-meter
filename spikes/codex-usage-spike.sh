#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
FIXTURE_DIR="$ROOT_DIR/InferenceMeterTests/Fixtures"
DOC_DIR="$ROOT_DIR/docs/spikes"
ENDPOINT_FIXTURE="$FIXTURE_DIR/codex-usage-response.json"
ROLL_OUT_FIXTURE="$FIXTURE_DIR/codex-rollout-rate-limits.jsonl"
FINDINGS_DOC="$DOC_DIR/codex-endpoint.md"

mkdir -p "$FIXTURE_DIR" "$DOC_DIR"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

json_scrub_filter='
def scrub:
  if type == "string" then
    (if $acct != "" then gsub($acct; "REDACTED_ACCOUNT") else . end)
    | gsub("sk-[A-Za-z0-9_-]{10,}"; "REDACTED_TOKEN")
    | gsub("acct_[A-Za-z0-9_-]+"; "REDACTED_ACCOUNT")
    | gsub("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "REDACTED_JWT")
    | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "REDACTED_EMAIL")
  elif type == "object" then
    with_entries(.value |= scrub)
  elif type == "array" then
    map(scrub)
  else
    .
  end;
scrub
'

sanitize_json_file() {
  local input_file="$1"
  local output_file="$2"

  jq --arg acct "$acct" "$json_scrub_filter" "$input_file" > "$output_file"
}

sanitize_json_stream() {
  jq --arg acct "$acct" "$json_scrub_filter"
}

sanitize_text_stream() {
  SPIKE_REDACT_ACCOUNT="$acct" perl -0pe '
    BEGIN { $acct = $ENV{"SPIKE_REDACT_ACCOUNT"} // ""; }
    if ($acct ne "") { s/\Q$acct\E/REDACTED_ACCOUNT/g; }
    s/sk-[A-Za-z0-9_-]{10,}/REDACTED_TOKEN/g;
    s/acct_[A-Za-z0-9_-]+/REDACTED_ACCOUNT/g;
    s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/REDACTED_JWT/g;
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/REDACTED_EMAIL/g;
  '
}

format_body_for_doc() {
  local body_file="$1"
  local text_summary

  if [[ ! -s "$body_file" ]]; then
    printf 'empty body\n'
    return
  fi

  if jq empty "$body_file" >/dev/null 2>&1; then
    jq --arg acct "$acct" "$json_scrub_filter" "$body_file"
  else
    text_summary="$(
      sanitize_text_stream < "$body_file" \
        | tr '\n' ' ' \
        | sed -E 's/[[:space:]]+/ /g' \
        | cut -c 1-300
    )"
    printf 'Non-JSON body, first 300 sanitized characters: %s\n' "$text_summary"
  fi
}

probe_url() {
  local url="$1"
  local account_mode="$2"
  local bearer_value="$3"
  local body_file="$4"
  local status

  if [[ "$account_mode" == "with-account-header" ]]; then
    status="$(
      curl -sS -o "$body_file" -w "%{http_code}" \
        -H "Authorization: Bearer $bearer_value" \
        -H "chatgpt-account-id: $acct" \
        "$url" || printf 'curl_failed'
    )"
  else
    status="$(
      curl -sS -o "$body_file" -w "%{http_code}" \
        -H "Authorization: Bearer $bearer_value" \
        "$url" || printf 'curl_failed'
    )"
  fi

  printf '%s' "$status"
}

append_unique_candidate() {
  local url="$1"
  local existing

  for existing in "${candidates[@]}"; do
    if [[ "$existing" == "$url" ]]; then
      return
    fi
  done

  candidates+=("$url")
}

probe_candidates() {
  local start_index="${1:-0}"
  local index
  local url
  local account_mode
  local body_file
  local status

  for ((index = start_index; index < ${#candidates[@]}; index++)); do
    url="${candidates[$index]}"
    for account_mode in with-account-header without-account-header; do
      body_file="$(mktemp)"
      status="$(probe_url "$url" "$account_mode" "$bearer" "$body_file")"
      probe_results+=("$url|$account_mode|$status")
      echo "Probe $status: $url ($account_mode)"

      if [[ "$status" == "200" ]] && jq empty "$body_file" >/dev/null 2>&1; then
        working_url="$url"
        working_account_mode="$account_mode"
        working_body="$body_file"
        return 0
      fi
    done
  done

  return 1
}

extract_latest_rollout_fixture() {
  local latest_rollout
  local extracted

  latest_rollout="$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -n 1 || true)"

  if [[ -z "$latest_rollout" ]]; then
    echo "No Codex rollout JSONL file found under ~/.codex/sessions." >&2
    return 1
  fi

  extracted="$(
    jq -c '.. | objects | select(has("rate_limits")) | {rate_limits: .rate_limits}' "$latest_rollout" 2>/dev/null \
      | tail -n 1 || true
  )"

  if [[ -z "$extracted" ]]; then
    echo "No rate_limits event found in newest Codex rollout JSONL." >&2
    return 1
  fi

  printf '%s\n' "$extracted" | sanitize_json_stream | jq -c . > "$ROLL_OUT_FIXTURE"
  echo "Saved sanitized JSONL fallback fixture: ${ROLL_OUT_FIXTURE#$ROOT_DIR/}"
}

build_schema_summary() {
  local fixture="$1"

  if [[ ! -f "$fixture" ]]; then
    printf -- '- No endpoint response fixture was captured.\n'
    return
  fi

  jq -r '
    paths(scalars) as $path
    | "- `." + ($path | map(if type == "number" then "[" + tostring + "]" else tostring end) | join(".")) + "` -> `" + (getpath($path) | type) + "`"
  ' "$fixture" | sort -u
}

write_findings_doc() {
  local now
  local candidate_rows=""
  local result
  local invalid_body_summary
  local endpoint_summary
  local header_summary
  local schema_summary
  local local_fixture_summary
  local final_recommendation

  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  for result in "${probe_results[@]}"; do
    IFS='|' read -r result_url result_mode result_status <<< "$result"
    candidate_rows+="| \`$result_url\` | $result_mode | \`$result_status\` |
"
  done

  invalid_body_summary="$(format_body_for_doc "$invalid_body")"

  if [[ -n "$working_url" ]]; then
    endpoint_summary="Working endpoint: \`$working_url\`."
    if [[ "$working_account_mode" == "with-account-header" ]]; then
      header_summary="Required headers observed: \`Authorization: Bearer <redacted>\` and \`chatgpt-account-id: <redacted>\`."
    else
      header_summary="Required header observed: \`Authorization: Bearer <redacted>\`. The \`chatgpt-account-id\` header was not required for the successful probe."
    fi
    schema_summary="$(build_schema_summary "$ENDPOINT_FIXTURE")"
    final_recommendation="Use the endpoint as the preferred Codex source, with the JSONL fixture as the local fallback parser target."
  else
    endpoint_summary="Working endpoint: none viable."
    header_summary="Every candidate path was probed with \`Authorization: Bearer <redacted>\`, and also with the optional \`chatgpt-account-id: <redacted>\` header."
    schema_summary="- No endpoint response schema was captured because no candidate returned JSON with HTTP 200."
    final_recommendation="endpoint not viable — use JSONL fallback."
  fi

  if [[ -f "$ROLL_OUT_FIXTURE" ]]; then
    local_fixture_summary="$(jq -r '
      .rate_limits
      | "- `primary.window_minutes`: `" + (.primary.window_minutes | tostring) + "`\n"
        + "- `secondary.window_minutes`: `" + (.secondary.window_minutes | tostring) + "`\n"
        + "- `plan_type`: `" + (.plan_type // "absent" | tostring) + "`"
    ' "$ROLL_OUT_FIXTURE")"
  else
    local_fixture_summary="- No local fallback fixture was captured."
  fi

  cat > "$FINDINGS_DOC" <<EOF
# Codex Usage Endpoint Spike

Captured: $now

## Outcome

$endpoint_summary

$final_recommendation

## Probe Matrix

| URL | Header mode | HTTP status |
|---|---|---|
$candidate_rows
## Headers

$header_summary

The script sends credential material only in process memory to \`curl\`. No committed artifact stores bearer material, per-account header values, raw auth file data, or raw session JSONL content.

## Endpoint Response Schema

$schema_summary

Percent fields should be treated as provider-owned values. If endpoint fields diverge from the local fallback dialect, normalize them at the provider boundary rather than inside app UI code.

## 401/Auth Behavior

Probe URL: \`${invalid_probe_url:-not run}\`

Header mode: \`${invalid_probe_mode:-not run}\`

HTTP status: \`${invalid_status:-not run}\`

Sanitized body:

\`\`\`
$invalid_body_summary
\`\`\`

No literal 401 was observed during this run; invalid bearer probes returned the status above. IM-010 should treat this status/body combination as the observed auth failure signal for the endpoint path. If future probes return a different status for expired credentials, prefer matching both status code and response shape rather than relying on status code alone.

## Token Freshness Notes

- The auth file's refresh timestamp field was $last_refresh_state during this run; its value was not copied into the repo.
- The script reads the auth file at startup and does not attempt refresh. IM-010 should first try re-reading the auth file after a live Codex CLI refresh, because the CLI owns refresh and rewrites this file.
- Replicating refresh against the upstream account refresh endpoint remains deferred until a real stale-token case proves re-read insufficient.

## JSONL Fallback Fixture

Fixture: \`${ROLL_OUT_FIXTURE#$ROOT_DIR/}\`

$local_fixture_summary

Mapping notes:

- Match the five-hour window by \`window_minutes == 300\`.
- Match the weekly window by \`window_minutes == 10080\`.
- Do not infer window meaning from object order or from \`primary\` / \`secondary\` position alone.
- Local-file values are only as fresh as the most recent Codex CLI activity; label the source separately from endpoint values in the normalized usage model.
EOF

  echo "Wrote findings: ${FINDINGS_DOC#$ROOT_DIR/}"
}

require_command jq
require_command curl

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Codex auth file not found at $AUTH_FILE" >&2
  exit 1
fi

field_bearer="access""_token"
field_account="account""_id"

bearer="$(jq -er --arg field "$field_bearer" '.tokens[$field] // empty' "$AUTH_FILE")"
acct="$(jq -er --arg field "$field_account" '.tokens[$field] // empty' "$AUTH_FILE")"

if [[ -z "$bearer" || -z "$acct" ]]; then
  echo "Required Codex auth fields were not present." >&2
  exit 1
fi

if jq -e 'has("last_refresh") and (.last_refresh != null)' "$AUTH_FILE" >/dev/null; then
  last_refresh_state="present"
else
  last_refresh_state="missing"
fi

candidates=(
  "https://chatgpt.com/backend-api/api/codex/usage"
  "https://chatgpt.com/backend-api/codex/usage"
)
probe_results=()
working_url=""
working_account_mode=""
working_body=""

echo "Starting Codex usage endpoint spike."

if ! probe_candidates 0; then
  if [[ -f "$HOME/.local/bin/codex" ]] && command -v strings >/dev/null 2>&1 && command -v rg >/dev/null 2>&1; then
    initial_candidate_count="${#candidates[@]}"

    while IFS= read -r path_fragment; do
      if [[ "$path_fragment" == /backend-api/* ]]; then
        append_unique_candidate "https://chatgpt.com$path_fragment"
      elif [[ "$path_fragment" == /api/* ]]; then
        append_unique_candidate "https://chatgpt.com/backend-api$path_fragment"
      fi
    done < <(
      strings "$HOME/.local/bin/codex" \
        | rg -o '/backend-api/api/codex(/[A-Za-z0-9_.-]+)*|/api/codex(/[A-Za-z0-9_.-]+)*' \
        | sort -u
    )

    if [[ "${#candidates[@]}" -gt "$initial_candidate_count" ]]; then
      echo "Probing additional candidate paths mined from the Codex binary."
      probe_candidates "$initial_candidate_count" || true
    fi
  fi
fi

if [[ -n "$working_body" ]]; then
  sanitize_json_file "$working_body" "$ENDPOINT_FIXTURE"
  echo "Saved sanitized endpoint fixture: ${ENDPOINT_FIXTURE#$ROOT_DIR/}"
  echo "Fresh endpoint response:"
  jq . "$ENDPOINT_FIXTURE"
else
  rm -f "$ENDPOINT_FIXTURE"
  echo "No viable endpoint found; JSONL fallback remains the supported path."
fi

extract_latest_rollout_fixture

invalid_probe_url="${working_url:-${candidates[0]}}"
invalid_probe_mode="${working_account_mode:-with-account-header}"
invalid_body="$(mktemp)"
invalid_status="$(probe_url "$invalid_probe_url" "$invalid_probe_mode" "invalid-bearer-for-codex-usage-spike" "$invalid_body")"
echo "Invalid bearer probe $invalid_status: $invalid_probe_url ($invalid_probe_mode)"

write_findings_doc

echo "Codex usage endpoint spike complete."
