#!/usr/bin/env bash
# Recall session-start hook
# Fetches formatted memory context from Recall and prints to stdout.
# Claude Code injects stdout from SessionStart hooks into the conversation context.
#
# Registered in settings.json under:
#   hooks.SessionStart[].hooks[].command
#   matcher: "startup|clear|compact"
#   timeout: 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config — silently exit if something goes wrong
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh" || exit 0

# No API key — nothing to do
[[ -z "${RECALL_API_KEY}" ]] && exit 0

# ─── Pure-bash semver comparison: returns 0 if $1 is strictly newer than $2 ──
_recall_version_newer() {
  local new_ver="$1" cur_ver="$2"
  [[ "${new_ver}" == "${cur_ver}" ]] && return 1
  local IFS='.'
  local -a na=($new_ver) ca=($cur_ver)
  for i in 0 1 2; do
    local n="${na[$i]:-0}" c="${ca[$i]:-0}"
    n="${n//[^0-9]/}"; n="${n:-0}"
    c="${c//[^0-9]/}"; c="${c:-0}"
    (( n > c )) && return 0
    (( n < c )) && return 1
  done
  return 1
}

# ─── Read installed version from config.json ──────────────────────────────────
CONFIG_FILE="${HOME}/.claude/recall/config.json"
INSTALLED_VERSION="1.0.0"
if [[ -f "${CONFIG_FILE}" ]]; then
  if command -v jq &>/dev/null; then
    INSTALLED_VERSION="$(jq -r '.version // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
  elif command -v python3 &>/dev/null; then
    INSTALLED_VERSION="$(python3 -c "import json; d=json.load(open('${CONFIG_FILE}')); print(d.get('version',''))" 2>/dev/null || true)"
  fi
fi
INSTALLED_VERSION="${INSTALLED_VERSION:-1.0.0}"

# ─── State file (shared with observe.sh) ─────────────────────────────────────
STATE_FILE="${HOME}/.claude/recall/state.json"

# ─── Daily update check (once per 24h, synchronous, 2s timeout) ──────────────
# Runs FIRST so a newly detected version can trigger auto-update in the same session.
LAST_CHECK=0
if [[ -f "${STATE_FILE}" ]]; then
  if command -v jq &>/dev/null; then
    LAST_CHECK="$(jq -r '.last_update_check // 0' "${STATE_FILE}" 2>/dev/null || echo 0)"
  elif command -v python3 &>/dev/null; then
    LAST_CHECK="$(python3 -c "import json; d=json.load(open('${STATE_FILE}')); print(d.get('last_update_check',0))" 2>/dev/null || echo 0)"
  fi
fi
LAST_CHECK="${LAST_CHECK:-0}"
NOW_EPOCH="$(date +%s 2>/dev/null || echo 0)"

REMOTE_VERSION=""
REMOTE_CHANGELOG=""
if (( NOW_EPOCH - LAST_CHECK > 86400 )); then
  REMOTE_JSON="$(curl --silent --max-time 2 --fail "${RECALL_SERVER_URL}/hooks/version?since=${INSTALLED_VERSION}" 2>/dev/null || true)"
  # Parse version and changelog only when we got a response
  if [[ -n "${REMOTE_JSON}" ]]; then
    if command -v python3 &>/dev/null; then
      REMOTE_VERSION="$(echo "${REMOTE_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('version',''))" 2>/dev/null || true)"
      REMOTE_CHANGELOG="$(echo "${REMOTE_JSON}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = d.get('data', {}).get('changelog', [])
print('\n'.join('  • ' + l for l in lines))
" 2>/dev/null || true)"
    elif command -v jq &>/dev/null; then
      REMOTE_VERSION="$(echo "${REMOTE_JSON}" | jq -r '.data.version // empty' 2>/dev/null || true)"
      REMOTE_CHANGELOG="$(echo "${REMOTE_JSON}" | jq -r '(.data.changelog // []) | map("  • " + .) | join("\n")' 2>/dev/null || true)"
    fi
  fi
  # Always write last_update_check (even on curl failure) so next session skips the 2s check.
  # Only touch available_version when REMOTE_VERSION is non-empty (curl succeeded).
  if command -v python3 &>/dev/null; then
    REMOTE_VERSION="${REMOTE_VERSION}" INSTALLED_VERSION="${INSTALLED_VERSION}" NOW_EPOCH="${NOW_EPOCH}" STATE_FILE="${STATE_FILE}" \
    python3 -c "
import json, os
sf = os.environ.get('STATE_FILE', os.path.expanduser('~/.claude/recall/state.json'))
try:
    d = json.load(open(sf))
except Exception:
    d = {}
d['last_update_check'] = int(os.environ['NOW_EPOCH'])
rv = os.environ.get('REMOTE_VERSION', '')
iv = os.environ.get('INSTALLED_VERSION', '1.0.0')
if rv:
    try:
        rv_parts = [int(x) for x in rv.split('.') if x]
        iv_parts = [int(x) for x in iv.split('.') if x]
        if rv_parts and rv_parts > iv_parts:
            d['available_version'] = rv
        elif 'available_version' in d:
            del d['available_version']
    except Exception:
        pass
json.dump(d, open(sf, 'w'))
" 2>/dev/null || true
  elif command -v jq &>/dev/null; then
    if [[ -f "${STATE_FILE}" ]]; then
      TMP="$(jq --argjson luc "${NOW_EPOCH}" --arg rv "${REMOTE_VERSION}" --arg iv "${INSTALLED_VERSION}" '
        . + {last_update_check: $luc} |
        if ($rv | length) > 0
        then (
          if (($rv | split(".") | map(tonumber)) > ($iv | split(".") | map(tonumber)))
          then . + {available_version: $rv}
          else del(.available_version)
          end
        )
        else .
        end
      ' "${STATE_FILE}" 2>/dev/null || true)"
    else
      TMP="{\"last_update_check\":${NOW_EPOCH}}"
    fi
    [[ -n "${TMP}" ]] && echo "${TMP}" > "${STATE_FILE}" || true
  fi
fi

# ─── Read auto_update preference from config.json (default: true) ────────────
AUTO_UPDATE="true"
if [[ -f "${CONFIG_FILE}" ]]; then
  if command -v jq &>/dev/null; then
    _au="$(jq -r '.auto_update // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    [[ "${_au}" == "false" ]] && AUTO_UPDATE="false"
  elif command -v python3 &>/dev/null; then
    _au="$(python3 -c "import json; d=json.load(open('${CONFIG_FILE}')); print(d.get('auto_update',''))" 2>/dev/null || true)"
    [[ "${_au}" == "False" || "${_au}" == "false" ]] && AUTO_UPDATE="false"
  fi
fi

# ─── Auto-update if a newer version was detected ─────────────────────────────
# REMOTE_VERSION is set above when the daily check ran and found a new version.
# AVAILABLE_VERSION is the fallback from a previous session's check.
AVAILABLE_VERSION="${REMOTE_VERSION}"
if [[ -z "${AVAILABLE_VERSION}" ]] && [[ -f "${STATE_FILE}" ]]; then
  if command -v jq &>/dev/null; then
    AVAILABLE_VERSION="$(jq -r '.available_version // empty' "${STATE_FILE}" 2>/dev/null || true)"
  elif command -v python3 &>/dev/null; then
    AVAILABLE_VERSION="$(python3 -c "import json; d=json.load(open('${STATE_FILE}')); print(d.get('available_version',''))" 2>/dev/null || true)"
  fi
fi
if [[ -n "${AVAILABLE_VERSION}" ]] && _recall_version_newer "${AVAILABLE_VERSION}" "${INSTALLED_VERSION}"; then
  echo ""
  echo "> 🔄 Recall update: ${INSTALLED_VERSION} → ${AVAILABLE_VERSION}"
  if [[ -n "${REMOTE_CHANGELOG}" ]]; then
    echo ">"
    echo "> What's new:"
    echo "${REMOTE_CHANGELOG}" | while IFS= read -r line; do echo ">$line"; done
  fi
  echo ">"
  if [[ "${AUTO_UPDATE}" == "false" ]]; then
    echo "> Auto-update is disabled. To update manually:"
    echo ">   curl -fsSL ${RECALL_SERVER_URL}/install-hooks | bash -s -- --api-key \${RECALL_API_KEY}"
  else
    # Auto-update hooks in the background so the hook completes within its timeout.
    # install.sh is idempotent and safe to re-run.
    UPDATE_LOG="${HOME}/.claude/recall/update.log"
    (
      curl -fsSL --max-time 30 "${RECALL_SERVER_URL}/install-hooks" \
        | bash -s -- --api-key "${RECALL_API_KEY}" --server-url "${RECALL_SERVER_URL}"
    ) > "${UPDATE_LOG}" 2>&1 &
    disown $! 2>/dev/null || true
    echo "> Updating in background — restart Claude Code once complete."
    echo "> To disable auto-update: set auto_update: false in ~/.claude/recall/config.json"
  fi
  echo ""
fi

# Reset session counter and generate a unique session name in state.json
# The session name (e.g. "happy-dog") identifies this Claude Code instance
# in the session registry so events can be routed to it specifically.
if command -v python3 &>/dev/null; then
  SESSION_NAME="$(python3 -c "
import json, os, random

ADJECTIVES = [
  'happy','lucky','brave','calm','eager','fancy','gentle','jolly',
  'kind','lively','merry','neat','proud','quiet','shiny','swift',
  'vivid','witty','zesty','bold','crisp','daring','electric','fuzzy',
  'golden','honest','icy','jazzy','keen','leafy','mighty','noble',
  'orange','peppy','quirky','rosy','savvy','tidy','ultra','vibrant',
  'warm','xenial','youthful','zealous','agile','bright','cosmic',
  'dazzling','earnest','fearless','graceful','humble','iconic',
]
ANIMALS = [
  'dog','cat','fox','owl','bear','deer','duck','frog','goat','hawk',
  'ibis','jay','kiwi','lamb','lynx','mole','newt','orca','pony',
  'quail','raven','seal','toad','vole','wren','yak','zebu','bison',
  'crane','dove','elk','finch','gnu','heron','iguana','jaguar',
  'koala','lemur','mink','narwhal','ocelot','panda','rabbit',
  'sloth','tapir','urial','viper','walrus','xerus','yapok',
]

adj = random.choice(ADJECTIVES)
animal = random.choice(ANIMALS)
print(f'{adj}-{animal}')
" 2>/dev/null || echo "recall-session")"
  python3 -c "
import json, os
sf = '${STATE_FILE}'
try:
    d = json.load(open(sf))
except Exception:
    d = {}
d['session_memories'] = 0
d['session_name'] = '${SESSION_NAME}'
json.dump(d, open(sf, 'w'))
" 2>/dev/null || true
elif command -v jq &>/dev/null; then
  SESSION_NAME="$(python3 -c "import random; a=['happy','lucky','brave','calm','eager']; n=['dog','cat','fox','owl','bear']; print(random.choice(a)+'-'+random.choice(n))" 2>/dev/null || echo "recall-session")"
  if [[ -f "${STATE_FILE}" ]]; then
    TMP="$(jq --arg sn "${SESSION_NAME}" '.session_memories = 0 | .session_name = $sn' "${STATE_FILE}" 2>/dev/null || true)"
  else
    TMP="{\"session_memories\":0,\"session_name\":\"${SESSION_NAME}\"}"
  fi
  [[ -n "${TMP}" ]] && echo "${TMP}" > "${STATE_FILE}" || true
fi

# ─── Register session with Recall server ─────────────────────────────────────
# Fire-and-forget: best-effort registration; if it fails the session still works.
if [[ -n "${SESSION_NAME:-}" && -n "${RECALL_API_KEY:-}" ]]; then
  SESSION_ID="$(python3 -c "import os; print(os.urandom(8).hex())" 2>/dev/null || echo "$$")"
  (curl --silent --max-time 3 --fail \
    --request POST \
    --header "Authorization: Bearer ${RECALL_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${SESSION_NAME}\",\"session_id\":\"${SESSION_ID}\",\"workspace_path\":\"${RECALL_WORKSPACE:-}\",\"git_remote\":\"${RECALL_GIT_REMOTE:-}\"}" \
    "${RECALL_SERVER_URL}/api/sessions" \
  ) > /dev/null 2>&1 &
  disown $! 2>/dev/null || true
fi

# ─── Fetch context and print activity indicator ────────────────────────────────
# Capture context first so we can show the banner even when context is empty.
CONTEXT="$(curl \
  --silent \
  --max-time 5 \
  --fail \
  --header "Authorization: Bearer ${RECALL_API_KEY}" \
  --header "X-Recall-Workspace: ${RECALL_WORKSPACE}" \
  --header "X-Recall-Git-Remote: ${RECALL_GIT_REMOTE}" \
  "${RECALL_SERVER_URL}/api/context?limit=20" \
  2>/dev/null || true)"

# Always print the activity indicator so users can confirm Recall is running.
echo "> 🧠 Recall ${INSTALLED_VERSION} active"

if [[ -n "${CONTEXT}" ]]; then
  echo ">"
  printf '%s\n' "${CONTEXT}"
fi
