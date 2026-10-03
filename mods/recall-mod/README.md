# recall-mod (prototype)

Recall as a Claude Code mod. A mod is JavaScript that Claude Code runs in its own process, on events, from Claude Code 2.1.287. This folder is a separate plugin. It changes nothing in the installed Recall plugin.

Load it for one session only:

```bash
claude --plugin-dir ./mods/recall-mod
```

Run its tests (no session, no network):

```bash
cd mods/recall-mod && claude plugin test
```

## How a mod works

Each hook gets `($, e, next)`. `e` is the event. `$` is the mods API. `next(e)` hands the event to the next mod, and at the end of the chain to Claude Code itself. Where the hook calls `next` decides what it does:

- **Before**: code above `return next(e)`.
- **Instead**: return a result without calling `next`.
- **After**: `const r = await next(e)`, then your code, then `return r`.
- **Retry**: call `next(e)` a second time.

A hook that throws or runs past 10 seconds is skipped: it fails open. Time spent inside `next` or a `$` call does not count.

## What this prototype does

| Event | What it does | What it replaces |
|---|---|---|
| `session.start` | Reads the key from `~/.claude/recall/config.json`. Finds the workspace: the repository's main working tree, with the remote's user and token removed. Confirms the workspace with Recall's MCP server, off the start path. Starts a 3-second send timer. | The workspace step of `rules/recall.md` |
| `tool.call` after Write, Edit, MultiEdit, Task, Bash, Read, Grep, Glob | Waits for the tool, queues one observation by the same rules as `observe.sh`, and returns the tool's result unchanged. The timer sends the queue. | `scripts/observe.sh` |
| `tool.call` on `mcp__recall-remote__*` | A call that fails with "restored workspace" or `WORKSPACE_NOT_CONFIRMED` confirms the workspace and runs once more. `set_workspace` is never retried. | The retry rule in `rules/recall.md` |
| `session.end` | Sends what is still queued (Claude Code gives 1.5 s). | Nothing: a short session lost these before |
| `ui.render` on `AbovePrompt` | One line above the prompt: `🧠 Recall · 3 stored this session · last 12s ago · workspace confirmed`. Other mods' lines stay. | The Recall segment of `scripts/statusline.sh` |

It has no `tool.check` hook, so it never approves a tool call.

## What stays a settings hook for now

- `statusline.sh`: the fallback where mods do not draw (the VS Code chat panel, `claude -p`, Claude Code before 2.1.287, `--bare`, `--safe-mode`). Next step: skip its Recall segment when the mod is active.
- `session-start.sh` (context at start and after compact), `pre-compact.sh`, `stop-summarize.sh`, `stop.sh`. Next steps: `classic.SessionStart` returning `additionalContext`, `session.compact`, and `turn.complete`, each in process.
- Context per prompt from `recall_relevant_context` (`prompt.submit` with `context`) is left out on purpose: it adds a network round trip before every prompt. Worth it only for prompts that ask about past work.

## Cost, measured

On this Mac, with a scratch home, a fake key and a closed local port (no network wait), at load 46:

| Script | Per run | Programs started |
|---|---|---|
| `observe.sh`, once per matching tool call | about 290 ms | about 10 (bash, jq, git, curl, date, ...) |
| `statusline.sh`, once per status-line refresh | about 160 ms, plus the `/api/status` round trip | bash, jq, curl |

The mod starts no process. Each observation is one HTTPS request from Claude Code's own process, sent on the timer, not on the tool's path.

## Risk to keep in mind

`session-start.sh` (1.17.3) downloads new scripts from recallmcp.com and runs them from the next session on, with no checksum or signature. A mod is code inside Claude Code with the user's permissions, so a Recall mod must update only through the plugin marketplace, never download its own code. For the scripts, pinned hashes or signed releases would close the gap.

The installed 1.17.3 already files a worktree under its main checkout and removes `user:token@` from the remote (`lib/config.sh`). This repo's copy (1.16.2) predates that; the mod does the same as 1.17.3.

## Limits

- Mods are early access. The published types say the surface may change between releases.
- Not yet run in a live session: tested with `claude plugin test` and `claude plugin validate` only.
- The MCP server name is fixed to `recall-remote`, as `.mcp.json` names it.
