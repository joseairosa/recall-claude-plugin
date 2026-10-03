// Recall as a Claude Code mod (prototype, Claude Code 2.1.287+).
//
// What it replaces, from the settings-hook version of the plugin:
// - scripts/observe.sh, a bash process per tool call (jq, git, curl): a tool.call hook in Claude Code's own
//   process that queues one observation per call and sends the queue on a timer, off the tool's path.
// - the "restored workspace" rule in rules/recall.md (call set_workspace, then retry): a tool.call hook on
//   Recall's MCP tools that does exactly that, once, in code.
// - the Recall segment of scripts/statusline.sh: one line in the band above the prompt, beside other mods'.
//   statusline.sh stays for VS Code and claude -p, where mods do not draw.
//
// The API key is read from ~/.claude/recall/config.json (or RECALL_API_KEY) and only ever goes in the
// Authorization header. Nothing here logs it, shows it, or returns it to Claude.

/** Recall's MCP server, as the plugin's .mcp.json names it. */
const SERVER = 'recall-remote'
const DEFAULT_URL = 'https://recallmcp.com'
/** How often queued observations are sent. */
const FLUSH_MS = 3000
/** The most observations held while Recall cannot be reached; older ones are dropped first. */
const QUEUE_MAX = 200
/** The error Recall answers a write with once its session has lost the workspace. */
const WORKSPACE_LOST = /WORKSPACE_NOT_CONFIRMED|restored workspace/i
/** The commands worth remembering, as observe.sh picks them. */
const HIGH_SIGNAL = /(git commit|npm run build|npx vitest|npm test|bun test|deploy|docker (build|run))/
const FAILED = /(^error:|npm ERR!|FAILED|command not found|non-zero exit|exit code [1-9])/im

// Shared by the hooks below; a module reload starts them again.
let config
let workspace
let queue = []
let stored = 0
let lastStoredAt = 0
let lastError = ''
let confirmed = false

/** The API key and the server URL: config.json first, as scripts/lib/config.sh reads them. */
async function loadConfig($) {
  const home = await $.env.get('HOME')
  let file = {}
  try {
    file = JSON.parse(await $.fs.read(home + '/.claude/recall/config.json'))
  } catch {
    // No config file: the environment may still hold a key.
  }
  const apiKey = file.api_key || (await $.env.get('RECALL_API_KEY')) || ''
  const url = (await $.env.get('RECALL_MOD_SERVER_URL')) || file.server_url || (await $.env.get('RECALL_SERVER_URL')) || DEFAULT_URL
  return { apiKey, url: url.replace(/\/+$/, '') }
}

/** The git remote without any user:token@ in it. */
export function cleanRemote(remote) {
  if (!remote) return ''
  return remote.replace(/^([a-z][a-z0-9+.-]*:\/\/)[^@/]*@/i, '$1')
}

/**
 * The workspace Recall files this session under: the repository's main working tree (the main checkout for a
 * worktree, as rules/recall.md asks), or the session's root outside git.
 */
async function loadWorkspace($) {
  const repo = await $.session.repo().catch(() => null)
  if (repo) return { path: repo.root, git_remote: cleanRemote(repo.remote) }
  return { path: await $.session.root(), git_remote: '' }
}

/** One observation for a finished tool call, by observe.sh's rules, or nothing. */
export function observation(e, result) {
  const failed = Boolean(result && (result.isError || result.deny))
  switch (e.tool) {
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
      return e.file_path ? { content: '[' + e.tool + '] ' + e.file_path, importance: 2, tags: [e.tool.toLowerCase()] } : undefined
    case 'Task': {
      const prompt = e.prompt || e.description
      return prompt ? { content: '[Task] ' + String(prompt).slice(0, 200), importance: 3, tags: ['task'] } : undefined
    }
    case 'Bash': {
      if (!e.command || !HIGH_SIGNAL.test(e.command)) return undefined
      const error = failed || FAILED.test(String((result && result.text) || '').slice(0, 500))
      return { content: '[Bash] ' + e.command.slice(0, 200), importance: error ? 6 : 3, tags: error ? ['bash', 'error'] : ['bash'] }
    }
    case 'Read':
      return e.file_path ? { content: '[Read] ' + e.file_path, importance: 1, tags: ['read'] } : undefined
    case 'Grep':
      if (!e.pattern) return undefined
      return { content: '[Grep] ' + String(e.pattern).slice(0, 100) + (e.path ? ' in ' + e.path : ''), importance: 1, tags: ['grep'] }
    case 'Glob':
      return e.pattern ? { content: '[Glob] ' + String(e.pattern).slice(0, 100), importance: 1, tags: ['glob'] } : undefined
    default:
      return undefined
  }
}

/** Send what is queued, one request per observation, as observe.sh does. Runs on the timer, never on a tool's path. */
async function flush($) {
  if (!config || !config.apiKey || queue.length === 0) return
  const batch = queue
  queue = []
  for (const item of batch) {
    let ok = false
    try {
      const response = await $.http.fetch(config.url + '/api/memories', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer ' + config.apiKey,
          'X-Recall-Workspace': workspace ? workspace.path : '',
          'X-Recall-Git-Remote': workspace ? workspace.git_remote : '',
        },
        body: JSON.stringify({ content: item.content, context_type: 'information', importance: item.importance, tags: ['auto-hook', ...item.tags], is_global: false }),
      })
      ok = response.ok
      lastError = ok ? '' : 'Recall answered ' + response.status
    } catch {
      lastError = 'Recall unreachable'
    }
    if (ok) {
      stored += 1
      lastStoredAt = await $.clock.now()
    } else {
      // Keep it for the next round, behind what came since.
      queue = [...queue, item].slice(-QUEUE_MAX)
      break
    }
  }
  $.ui.invalidate('ui.render')
}

/** Confirm this session's workspace with Recall's MCP server. */
async function confirmWorkspace($) {
  if (!workspace) workspace = await loadWorkspace($)
  const r = await $.mcp.call(SERVER, 'set_workspace', workspace)
  confirmed = !r.isError
  $.ui.invalidate('ui.render')
  return confirmed
}

function ago(ms) {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? s + 's ago' : Math.round(s / 60) + 'm ago'
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    config = await loadConfig($)
    workspace = await loadWorkspace($)
    // Off the start path: the first prompt does not wait for Recall.
    $.clock.after(0, () => confirmWorkspace($).catch(() => undefined))
    $.clock.every(FLUSH_MS, () => flush($).catch(() => undefined))
    return next(e)
  })

  // A short session (claude -p) can end before the timer runs: send what is left, best effort. Claude Code
  // gives all session.end hooks 1.5 seconds together, so a slow Recall loses the rest, as observe.sh's would.
  on('session.end', async ($, e, next) => {
    await flush($).catch(() => undefined)
    return next(e)
  })

  // observe.sh, in process: after the tool has run, queue what is worth remembering. The tool's result goes
  // back to Claude at once and unchanged; sending happens on the timer.
  on('tool.call', { tool: ['Write', 'Edit', 'MultiEdit', 'Task', 'Bash', 'Read', 'Grep', 'Glob'] }, async ($, e, next) => {
    const result = await next(e)
    const item = observation(e, result)
    if (item && config && config.apiKey) queue = [...queue, item].slice(-QUEUE_MAX)
    return result
  })

  // The "restored workspace" rule as code: a Recall call that failed because the session lost its workspace
  // confirms the workspace and runs once more. set_workspace itself is never retried, and only once per call.
  // A literal, so claude plugin validate can show which tools the hook sees (SERVER is recall-remote).
  on('tool.call', { tool: /^mcp__recall-remote__/ }, async ($, e, next) => {
    const first = await next(e)
    if (e.tool === 'mcp__' + SERVER + '__set_workspace') {
      if (first && !first.deny && !first.isError) confirmed = true
      return first
    }
    if (!first || first.deny || !WORKSPACE_LOST.test(String(first.text || ''))) return first
    try {
      if (!(await confirmWorkspace($))) return first
    } catch {
      return first
    }
    $.ui.log('workspace confirmed again; the call was retried')
    return next(e)
  })

  // One line in the band above the prompt, kept beside what other mods draw there.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const theirs = await next(e)
    if (!config || !config.apiKey) return theirs
    const { Box, Text } = $.ui.resolve(e)
    const now = await $.clock.now()
    const parts = ['Recall', stored + ' stored this session']
    if (lastStoredAt) parts.push('last ' + ago(now - lastStoredAt))
    if (queue.length > 0) parts.push(queue.length + ' waiting')
    parts.push(confirmed ? 'workspace confirmed' : 'workspace not confirmed yet')
    const line = '🧠 ' + parts.join(' · ') + (lastError ? ' · ' + lastError : '')
    const mine = lastError ? Text({ color: 'yellow', children: [line] }) : Text({ dimColor: true, children: [line] })
    return Box({ flexDirection: 'column', children: theirs ? [mine, theirs] : [mine] })
  })
}
