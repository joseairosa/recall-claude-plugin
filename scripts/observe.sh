#!/usr/bin/env bash
# Recall observe hook (PostToolUse)
# Reads Claude Code tool event from stdin, selectively POSTs observations to Recall.
#
# Registered in settings.json under:
#   hooks.PostToolUse[].hooks[].command
#   matcher: "Write|Edit|MultiEdit|Task|Bash"
#   async: true  (non-blocking — Claude does not wait for this hook)
#   timeout: 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config — silently exit if something goes wrong
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh" || exit 0

# No API key — nothing to do
[[ -z "${RECALL_API_KEY}" ]] && exit 0

# Read JSON from stdin (Claude Code passes {"tool_name","tool_input","tool_output"})
STDIN_DATA="$(cat)"

# Extract tool_name
if command -v jq &>/dev/null; then
  TOOL_NAME="$(echo "${STDIN_DATA}" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  TOOL_INPUT="$(echo "${STDIN_DATA}" | jq -r '.tool_input // {}' 2>/dev/null || true)"
elif command -v python3 &>/dev/null; then
  TOOL_NAME="$(echo "${STDIN_DATA}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || true)"
  TOOL_INPUT="$(echo "${STDIN_DATA}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('tool_input',{})))" 2>/dev/null || true)"
else
  # Minimal grep fallback
  TOOL_NAME="$(echo "${STDIN_DATA}" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"
  TOOL_INPUT=""
fi

[[ -z "${TOOL_NAME}" ]] && exit 0

# Build observation content based on tool type
OBSERVATION_CONTENT=""

case "${TOOL_NAME}" in
  Write|Edit|MultiEdit)
    # Bare file paths carry no context — not worth storing.
    exit 0
    ;;

  Task)
    # Capture task description (truncated)
    if command -v jq &>/dev/null; then
      PROMPT="$(echo "${TOOL_INPUT}" | jq -r '.prompt // .description // empty' 2>/dev/null || true)"
    elif command -v python3 &>/dev/null; then
      PROMPT="$(echo "${TOOL_INPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('prompt') or d.get('description',''))" 2>/dev/null || true)"
    else
      PROMPT=""
    fi
    [[ -z "${PROMPT}" ]] && exit 0
    OBSERVATION_CONTENT="[Task] ${PROMPT:0:200}"
    ;;

  Bash)
    # Only capture meaningful commands — ignore trivial ones
    if command -v jq &>/dev/null; then
      COMMAND="$(echo "${TOOL_INPUT}" | jq -r '.command // empty' 2>/dev/null || true)"
    elif command -v python3 &>/dev/null; then
      COMMAND="$(echo "${TOOL_INPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null || true)"
    else
      COMMAND=""
    fi
    [[ -z "${COMMAND}" ]] && exit 0

    # Only capture high-signal commands — ignore routine git plumbing, installs, and branch ops
    if echo "${COMMAND}" | grep -qE '(git commit|npm run build|npx vitest|npm test|bun test|deploy|docker (build|run))'; then
      OBSERVATION_CONTENT="[Bash] ${COMMAND:0:200}"
    else
      exit 0
    fi
    ;;

  *)
    exit 0
    ;;
esac

[[ -z "${OBSERVATION_CONTENT}" ]] && exit 0

# Compute lowercase tool tag for per-tool filtering
TOOL_TAG="$(echo "${TOOL_NAME}" | tr '[:upper:]' '[:lower:]')"

# Build JSON payload
if command -v jq &>/dev/null; then
  PAYLOAD="$(jq -n \
    --arg content "${OBSERVATION_CONTENT}" \
    --arg workspace "${RECALL_WORKSPACE}" \
    --arg tool_tag "${TOOL_TAG}" \
    '{content: $content, context_type: "information", importance: 3, tags: ["auto-hook", $tool_tag], is_global: false}')"
elif command -v python3 &>/dev/null; then
  PAYLOAD="$(OBSERVATION_CONTENT="${OBSERVATION_CONTENT}" TOOL_TAG="${TOOL_TAG}" python3 -c "
import json, os
print(json.dumps({
  'content': os.environ['OBSERVATION_CONTENT'],
  'context_type': 'information',
  'importance': 3,
  'tags': ['auto-hook', os.environ['TOOL_TAG']],
  'is_global': False
}))")"
else
  # Minimal JSON construction — escape quotes in content
  ESCAPED="${OBSERVATION_CONTENT//\"/\\\"}"
  PAYLOAD="{\"content\":\"${ESCAPED}\",\"context_type\":\"information\",\"importance\":3,\"tags\":[\"auto-hook\",\"${TOOL_TAG}\"],\"is_global\":false}"
fi

# POST observation — fire-and-forget, ignore errors
# Capture HTTP status code to conditionally update local state
HTTP_STATUS="$(curl \
  --silent \
  --max-time 5 \
  --output /dev/null \
  --write-out "%{http_code}" \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${RECALL_API_KEY}" \
  --header "X-Recall-Workspace: ${RECALL_WORKSPACE}" \
  --header "X-Recall-Git-Remote: ${RECALL_GIT_REMOTE}" \
  --data "${PAYLOAD}" \
  "${RECALL_SERVER_URL}/api/memories" \
  2>/dev/null || echo "000")"

# On success (2xx), update local state file for statusline activity indicator
if [[ "${HTTP_STATUS}" =~ ^2 ]]; then
  STATE_FILE="${HOME}/.claude/recall/state.json"
  NOW="$(date +%s 2>/dev/null || echo 0)"
  COUNT=1
  if [[ -f "${STATE_FILE}" ]]; then
    if command -v jq &>/dev/null; then
      COUNT="$(jq -r '.session_memories // 0' "${STATE_FILE}" 2>/dev/null || echo 0)"
      COUNT=$(( COUNT + 1 ))
    elif command -v python3 &>/dev/null; then
      COUNT="$(python3 -c "import json; d=json.load(open('${STATE_FILE}')); print(d.get('session_memories',0)+1)" 2>/dev/null || echo 1)"
    fi
  fi
  if command -v python3 &>/dev/null; then
    NOW="${NOW}" COUNT="${COUNT}" STATE_FILE="${STATE_FILE}" python3 -c "
import json, os
sf = os.environ.get('STATE_FILE', os.path.expanduser('~/.claude/recall/state.json'))
try:
    d = json.load(open(sf))
except Exception:
    d = {}
d['last_stored'] = int(os.environ['NOW'])
d['session_memories'] = int(os.environ['COUNT'])
json.dump(d, open(sf, 'w'))
" 2>/dev/null || true
  elif command -v jq &>/dev/null; then
    if [[ -f "${STATE_FILE}" ]]; then
      TMP="$(jq --argjson ls "${NOW}" --argjson sm "${COUNT}" \
        '. + {last_stored: $ls, session_memories: $sm}' "${STATE_FILE}" 2>/dev/null || true)"
    else
      TMP="{\"last_stored\":${NOW},\"session_memories\":${COUNT}}"
    fi
    [[ -n "${TMP}" ]] && echo "${TMP}" > "${STATE_FILE}" || true
  fi
fi
