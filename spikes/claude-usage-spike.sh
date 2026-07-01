#!/usr/bin/env bash
set -euo pipefail

CLAUDE_KEYCHAIN_SERVICE="${CLAUDE_KEYCHAIN_SERVICE:-Claude Code-credentials}"
CLAUDE_KEYCHAIN_ACCOUNT="${CLAUDE_KEYCHAIN_ACCOUNT:-$(id -un)}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/share/claude/versions/2.1.197}"
CLAUDE_USAGE_URL="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CLAUDE_USAGE_PROBE_ALL="${CLAUDE_USAGE_PROBE_ALL:-0}"
CLAUDE_USAGE_CHECK_401="${CLAUDE_USAGE_CHECK_401:-0}"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
}

print_json_leaf_types() {
  jq -r '
    paths as $path
    | select((getpath($path) | type) != "object" and (getpath($path) | type) != "array")
    | "  - " + ($path | map(tostring) | join(".")) + ": " + (getpath($path) | type)
  ' "$1" | sort
}

extract_access_token() {
  jq -r '
    [
      .claudeAiOauth.accessToken?,
      .accessToken?,
      (.. | objects | .accessToken?)
    ]
    | map(select(type == "string" and length > 0))
    | first // empty
  '
}

format_usage() {
  jq -r '
    def percent($value):
      if ($value | type) == "number" then
        if $value <= 1 then $value * 100 else $value end
      else
        null
      end;

    def display($value):
      if $value == null then
        "unavailable"
      else
        (((($value * 10) | round) / 10) | tostring) + "%"
      end;

    "Claude 5-hour: " + display(percent(.five_hour.utilization?)) + " (resets_at: " + (.five_hour.resets_at? // "unavailable") + ")",
    "Claude weekly: " + display(percent(.seven_day.utilization?)) + " (resets_at: " + (.seven_day.resets_at? // "unavailable") + ")"
  ' "$1"
}

sanitize_response() {
  jq '
    def scrub:
      if type == "object" then
        with_entries(
          if (.key | test("(?i)(token|secret|authorization|cookie|request_id|account_id|org_id|organization_id|(^|_)(account|org|organization)(_|$))")) then
            .value = "[SCRUBBED]"
          elif ((.key | ascii_downcase) == "id" and .value != null) then
            .value = "[SCRUBBED_ID]"
          else
            .value |= scrub
          end
        )
      elif type == "array" then
        map(scrub)
      else
        .
      end;

    scrub
  ' "$1"
}

request_usage() {
  local name="$1"
  shift

  local body_path="$SCRATCH_DIR/${name}.json"
  local header_path="$SCRATCH_DIR/${name}.headers"
  local http_status

  http_status="$(curl -sS -w '%{http_code}' -D "$header_path" -o "$body_path" "$@" "$CLAUDE_USAGE_URL")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$http_status" "$body_path" "$header_path"
}

require_command curl
require_command jq
require_command security
require_command strings
require_command sort

SCRATCH_DIR="$(mktemp -d /private/tmp/claude-usage-spike.XXXXXX)"
chmod 700 "$SCRATCH_DIR"

printf 'Scratch directory: %s\n' "$SCRATCH_DIR"
printf 'Reading Claude Code credential from macOS Keychain without printing the credential blob.\n'

CREDENTIAL_JSON="$(security find-generic-password -s "$CLAUDE_KEYCHAIN_SERVICE" -a "$CLAUDE_KEYCHAIN_ACCOUNT" -w)"
CREDENTIAL_STRUCTURE_PATH="$SCRATCH_DIR/credential-structure.json"
printf '%s' "$CREDENTIAL_JSON" | jq '
  paths as $path
  | select((getpath($path) | type) != "object" and (getpath($path) | type) != "array")
  | {path: ($path | map(tostring) | join(".")), type: (getpath($path) | type)}
' | jq -s . > "$CREDENTIAL_STRUCTURE_PATH"

printf '\nCredential JSON structure:\n'
jq -r '.[] | "  - " + .path + ": " + .type' "$CREDENTIAL_STRUCTURE_PATH" | sort

ACCESS_TOKEN="$(printf '%s' "$CREDENTIAL_JSON" | extract_access_token)"
unset CREDENTIAL_JSON

if [ -z "$ACCESS_TOKEN" ]; then
  printf 'Could not find an access token string in the Keychain credential JSON.\n' >&2
  exit 1
fi

printf '\nClaude binary hints:\n'
if [ -f "$CLAUDE_BIN" ]; then
  BINARY_HINTS="$(strings "$CLAUDE_BIN" \
    | grep -Eo 'oauth-[0-9]{4}-[0-9]{2}-[0-9]{2}|https://platform\.claude\.com/v1/oauth/token|/api/oauth/usage|anthropic-version|anthropic-beta|x-app-name|x-app-ver|x-app' \
    | sort -u || true)"
  if [ -n "$BINARY_HINTS" ]; then
    printf '%s\n' "$BINARY_HINTS" | sed 's/^/  - /'
  else
    printf '  - no matching hints found\n'
  fi
else
  printf '  - Claude binary not found at %s\n' "$CLAUDE_BIN"
fi

printf '\nEndpoint probes:\n'
SUCCESS_BODY=""
SUCCESS_VARIANT=""
RATE_LIMITED=""
RATE_LIMIT_RETRY_AFTER=""
INVALID_TOKEN="invalid-token"

handle_probe_result() {
  local result="$1"
  local variant
  local http_status
  local body_path
  local header_path

  variant="$(printf '%s' "$result" | cut -f1)"
  http_status="$(printf '%s' "$result" | cut -f2)"
  body_path="$(printf '%s' "$result" | cut -f3)"
  header_path="$(printf '%s' "$result" | cut -f4)"

  printf '  - %s: HTTP %s\n' "$variant" "$http_status"

  if [ "$http_status" = "429" ]; then
    RATE_LIMITED="1"
    RATE_LIMIT_RETRY_AFTER="$(grep -Ei '^retry-after:' "$header_path" | awk '{print $2}' | tr -d '\r' | tail -n 1 || true)"
  fi

  if [ "$http_status" = "200" ] && jq -e '.five_hour.utilization? and .seven_day.utilization?' "$body_path" >/dev/null 2>&1; then
    if [ -z "$SUCCESS_BODY" ]; then
      SUCCESS_BODY="$body_path"
      SUCCESS_VARIANT="$variant"
    fi
  fi
}

handle_probe_result "$(request_usage "authorization-only" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"

if { [ -z "$SUCCESS_BODY" ] && [ -z "$RATE_LIMITED" ]; } || [ "$CLAUDE_USAGE_PROBE_ALL" = "1" ]; then
  handle_probe_result "$(request_usage "authorization-plus-beta" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "anthropic-beta: oauth-2025-04-20")"
fi

if { [ -z "$SUCCESS_BODY" ] && [ -z "$RATE_LIMITED" ]; } || [ "$CLAUDE_USAGE_PROBE_ALL" = "1" ]; then
  handle_probe_result "$(request_usage "authorization-plus-version" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "anthropic-version: 2023-06-01")"
fi

if { [ -z "$SUCCESS_BODY" ] && [ -z "$RATE_LIMITED" ]; } || [ "$CLAUDE_USAGE_PROBE_ALL" = "1" ]; then
  handle_probe_result "$(request_usage "authorization-plus-beta-version" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01")"
fi

BAD_TOKEN_STATUS=""
BAD_TOKEN_BODY=""

if [ "$CLAUDE_USAGE_CHECK_401" = "1" ]; then
  BAD_TOKEN_RESULT="$(request_usage "invalid-token" \
    -H "Authorization: Bearer ${INVALID_TOKEN}" \
    -H "anthropic-beta: oauth-2025-04-20")"
  BAD_TOKEN_STATUS="$(printf '%s' "$BAD_TOKEN_RESULT" | cut -f2)"
  BAD_TOKEN_BODY="$(printf '%s' "$BAD_TOKEN_RESULT" | cut -f3)"
fi

unset ACCESS_TOKEN
unset INVALID_TOKEN

if [ -z "$SUCCESS_BODY" ]; then
  if [ -n "$RATE_LIMITED" ]; then
    printf '\nEndpoint returned HTTP 429.'
    if [ -n "$RATE_LIMIT_RETRY_AFTER" ]; then
      printf ' Retry after %s seconds.' "$RATE_LIMIT_RETRY_AFTER"
    fi
    printf '\n'
  fi

  printf '\nNo direct endpoint probe returned a usable 200 response. Verify the statusLine fallback manually.\n' >&2
  exit 1
fi

SANITIZED_PATH="$SCRATCH_DIR/claude-usage-response.sanitized.json"
sanitize_response "$SUCCESS_BODY" > "$SANITIZED_PATH"

printf '\nSelected request variant: %s\n' "$SUCCESS_VARIANT"
format_usage "$SUCCESS_BODY"

printf '\nSuccessful response schema:\n'
print_json_leaf_types "$SUCCESS_BODY"

if [ "$CLAUDE_USAGE_CHECK_401" = "1" ]; then
  printf '\nInvalid-token response: HTTP %s\n' "$BAD_TOKEN_STATUS"
  if jq -e . "$BAD_TOKEN_BODY" >/dev/null 2>&1; then
    print_json_leaf_types "$BAD_TOKEN_BODY"
  else
    printf '  - response body was not JSON\n'
  fi
else
  printf '\nInvalid-token probe skipped. Set CLAUDE_USAGE_CHECK_401=1 to reproduce the documented 401 shape.\n'
fi

printf '\nSanitized fixture candidate: %s\n' "$SANITIZED_PATH"
printf 'Raw endpoint bodies remain only in the scratch directory and were not written to the repo.\n'
