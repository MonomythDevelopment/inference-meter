#!/usr/bin/env bash
set -euo pipefail

# Claude Code statusLine tee for the disabled IM-005 fallback path.
#
# Register this script as the Claude Code statusLine command, using an absolute path, to mirror
# incoming statusLine JSON into the file the provider can read when fallback is explicitly enabled:
#
#   "statusLine": {
#     "type": "command",
#     "command": "/absolute/path/to/scripts/inference-meter-statusline.sh"
#   }
#
# The script writes to ~/.claude/inference-meter-status.json by default. Override with
# INFERENCE_METER_STATUSLINE_PATH when testing. Input is passed back to stdout so an existing
# statusLine pipeline can continue rendering the same JSON.

output_path="${INFERENCE_METER_STATUSLINE_PATH:-$HOME/.claude/inference-meter-status.json}"
output_dir="$(dirname "$output_path")"
temp_path="$(mktemp "${TMPDIR:-/tmp}/inference-meter-statusline.XXXXXX")"

cleanup() {
  rm -f "$temp_path"
}

trap cleanup EXIT

mkdir -p "$output_dir"
chmod 700 "$output_dir"

cat > "$temp_path"
chmod 600 "$temp_path"
mv "$temp_path" "$output_path"
cat "$output_path"
