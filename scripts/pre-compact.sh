#!/usr/bin/env bash
# Recall pre-compact hook
# Saves a state marker memory before Claude Code compacts the context window.
# This allows session continuity to be reconstructed after compaction.
#
# Registered in settings.json under:
#   hooks.PreCompact[].hooks[].command
#   timeout: 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config — silently exit if something goes wrong
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh" || exit 0

# No API key — nothing to do
[[ -z "${RECALL_API_KEY}" ]] && exit 0

CONTENT="Session pre-compact state. CWD: ${RECALL_WORKSPACE}"

# Build JSON payload
if command -v jq &>/dev/null; then
  PAYLOAD="$(jq -n \
    --arg content "${CONTENT}" \
    '{content: $content, context_type: "information", importance: 5, tags: ["auto-hook", "pre-compact"], is_global: false}')"
else
  ESCAPED="${CONTENT//\"/\\\"}"
  PAYLOAD="{\"content\":\"${ESCAPED}\",\"context_type\":\"information\",\"importance\":5,\"tags\":[\"auto-hook\",\"pre-compact\"],\"is_global\":false}"
fi

curl \
  --silent \
  --max-time 5 \
  --fail \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${RECALL_API_KEY}" \
  --header "X-Recall-Workspace: ${RECALL_WORKSPACE}" \
  --header "X-Recall-Git-Remote: ${RECALL_GIT_REMOTE}" \
  --data "${PAYLOAD}" \
  "${RECALL_SERVER_URL}/api/memories" \
  2>/dev/null || true
