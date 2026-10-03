import { expect, mock, test } from 'claude-code/testing'

// A made-up key: the tests check it reaches the Authorization header and nowhere else.
const KEY = 'rk-test-' + 'not-a-real-key'
const CONFIG = JSON.stringify({ api_key: KEY, server_url: 'https://recall.test' })

type Sent = { url: string; headers: Record<string, string>; body: { content: string; importance: number; tags: string[] } }

/** Stubs for a session in /work with a config file, a repository whose remote carries a token, and Recall answering. */
function stubSession(on: any, opts: { config?: string; recallStatus?: number } = {}) {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/home/me' })
  on('fs.read', ($: any, e: any) => (e.path.endsWith('/.claude/recall/config.json') && opts.config !== '' ? { value: opts.config ?? CONFIG } : { deny: 'no such file' }))
  on('session.repo', () => ({ value: { root: '/work', remote: 'https://jose:ghp_x@github.com/joseairosa/app.git', internal: false, name: null } }))
  on('session.root', () => ({ value: '/work' }))
  const workspaceCalls: unknown[] = []
  on('mcp.call', ($: any, e: any) => {
    workspaceCalls.push(e)
    return { value: { content: [{ type: 'text', text: 'Workspace set' }], isError: false } }
  })
  const sent: Sent[] = []
  on('http.fetch', ($: any, e: any) => {
    sent.push({ url: e.url, headers: e.init.headers, body: JSON.parse(e.init.body) })
    const status = opts.recallStatus ?? 201
    return { value: { status, ok: status < 300, headers: {}, text: '{}' } }
  })
  const logs: string[] = []
  on('ui.log', ($: any, e: any) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', () => ({ cwd: '/work' }))
  return { clock, sent, logs, workspaceCalls }
}

const start = ($: any) => $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

test('observes a tool call off its path: the result returns at once, the observation is sent on the timer', async ($, on) => {
  const s = stubSession(on)
  on('tool.call', () => ({ result: 'file contents', text: 'file contents' }))
  await start($)

  const result = await $.tool.call({ tool: 'Read', file_path: '/work/src/a.ts' })
  // Claude gets the tool's own result, and nothing has been sent yet.
  expect(result).toMatchObject({ result: 'file contents' })
  expect(s.sent).toEqual([])

  await s.clock.advance(3000)
  expect(s.sent.length).toBe(1)
  expect(s.sent[0].url).toBe('https://recall.test/api/memories')
  expect(s.sent[0].body).toMatchObject({ content: '[Read] /work/src/a.ts', importance: 1, tags: ['auto-hook', 'read'] })
  expect(s.sent[0].headers.Authorization).toBe('Bearer ' + KEY)
  // The workspace is the repository's root, and the remote loses its user and token.
  expect(s.sent[0].headers['X-Recall-Workspace']).toBe('/work')
  expect(s.sent[0].headers['X-Recall-Git-Remote']).toBe('https://github.com/joseairosa/app.git')
})

test('sends what is still queued when the session ends before the timer runs', async ($, on) => {
  const s = stubSession(on)
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  // Claude Code's own answer to session.end names the session that ended.
  on('session.end', () => ({ sessionId: 's1' }))
  await start($)

  await $.tool.call({ tool: 'Glob', pattern: 'src/**/*.ts' })
  expect(s.sent).toEqual([])
  await $.session.end({ reason: 'other' })
  expect(s.sent.map((x) => x.body.content)).toEqual(['[Glob] src/**/*.ts'])
})

test('keeps observe.sh rules: routine commands are skipped, a failed test run is an error worth 6', async ($, on) => {
  const s = stubSession(on)
  on('tool.call', ($: any, e: any) => ({ result: 'out', text: e.command === 'npm test' ? 'Tests: 1 FAILED' : 'ok' }))
  await start($)

  await $.tool.call({ tool: 'Bash', command: 'ls -la' })
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  await $.tool.call({ tool: 'mcp__github__get_issue', number: 3 })
  await s.clock.advance(3000)

  expect(s.sent.map((x) => x.body.content)).toEqual(['[Bash] npm test'])
  expect(s.sent[0].body).toMatchObject({ importance: 6, tags: ['auto-hook', 'bash', 'error'] })
})

test('keeps what Recall did not take and sends it on the next round', async ($, on) => {
  const s = stubSession(on, { recallStatus: 503 })
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  await start($)

  await $.tool.call({ tool: 'Edit', file_path: '/work/a.ts', old_string: 'a', new_string: 'b' })
  await s.clock.advance(3000)
  await s.clock.advance(3000)
  // Tried each round, never dropped while the queue has room.
  expect(s.sent.map((x) => x.body.content)).toEqual(['[Edit] /work/a.ts', '[Edit] /work/a.ts'])
})

test('without a key it sends nothing and draws nothing of its own', async ($, on) => {
  const s = stubSession(on, { config: '' })
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by another mod'] }))
  await start($)

  await $.tool.call({ tool: 'Read', file_path: '/work/a.ts' })
  await s.clock.advance(3000)
  expect(s.sent).toEqual([])
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ type: 'Text', text: /Recall/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'drawn by another mod' })).toBeDefined()
})

test('a Recall call that lost its workspace confirms it and runs once more', async ($, on) => {
  const s = stubSession(on)
  let calls = 0
  on('tool.call', () => {
    calls += 1
    return calls === 1
      ? { result: { content: [{ type: 'text', text: 'Error: WORKSPACE_NOT_CONFIRMED' }], isError: true }, text: 'Error: WORKSPACE_NOT_CONFIRMED' }
      : { result: { content: [{ type: 'text', text: 'Stored' }], isError: false }, text: 'Stored' }
  })
  await start($)

  const out = await $.tool.call({ tool: 'mcp__recall-remote__store_memory', content: 'a decision' })
  expect(out).toMatchObject({ text: 'Stored' })
  expect(calls).toBe(2)
  // The retry confirmed the workspace with the repository's root and the cleaned remote.
  expect(s.workspaceCalls.length).toBe(1)
  expect(JSON.stringify(s.workspaceCalls[0])).toContain('/work')
  expect(JSON.stringify(s.workspaceCalls[0])).not.toContain('ghp_x')
  expect(s.logs).toEqual(['workspace confirmed again; the call was retried'])
})

test('never loops: a second failure is returned as it is, and set_workspace is never retried', async ($, on) => {
  stubSession(on)
  let calls = 0
  on('tool.call', () => {
    calls += 1
    return { result: { content: [], isError: true }, text: 'restored workspace: call set_workspace' }
  })
  await start($)

  const out = await $.tool.call({ tool: 'mcp__recall-remote__store_memory', content: 'x' })
  expect(out).toMatchObject({ text: 'restored workspace: call set_workspace' })
  expect(calls).toBe(2)

  calls = 0
  await $.tool.call({ tool: 'mcp__recall-remote__set_workspace', path: '/work' })
  expect(calls).toBe(1)
})

// What Claude Code passes to a ui.render hook for the band above the prompt.
const BAND = {
  plugin: 'recall-mod',
  component: 'AbovePrompt',
  requestId: 'AbovePrompt',
  surface: 'terminal',
  viewport: { columns: 120, rows: 40 },
  props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 116, scroll: { offset: 0, bodyRows: 6 }, view: {} },
} as const

test('shows one Recall line in the band, keeps other mods beside it, and never shows the key', async ($, on) => {
  const s = stubSession(on)
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by another mod'] }))
  await start($)
  await s.clock.settle()

  await $.tool.call({ tool: 'Write', file_path: '/work/notes.md', content: 'hello' })
  await s.clock.advance(3000)

  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ type: 'Text', text: /^🧠 Recall · 1 stored this session · last 0s ago · workspace confirmed$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'drawn by another mod' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: new RegExp(KEY) })).toBeUndefined()
  expect(s.logs.join('\n')).not.toContain(KEY)
})
