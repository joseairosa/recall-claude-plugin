# Recall — Persistent Memory for Claude Code

Give Claude Code a permanent memory store that survives every session restart and context compaction — automatically.

Install the plugin once and four hooks capture context and restore it on every session, with zero prompting required.

## Installation

### From the Official Marketplace

```
/plugin install recall@claude-plugins-official
```

### From Recall Marketplace

```
/plugin marketplace add joseairosa/recall-claude-plugin
/plugin install recall@recall-claude-plugin
```

## Configuration

Sign up at [recallmcp.com](https://recallmcp.com) and set your API key:

```bash
export RECALL_API_KEY="sk-your-api-key-here"
```

Optionally set a custom server URL (defaults to `https://recallmcp.com`):

```bash
export RECALL_SERVER_URL="https://your-instance.example.com"
```

## What's Included

### MCP Server (`.mcp.json`)

Connects to the Recall MCP server at recallmcp.com (or self-hosted). Provides 16+ tools:
- `set_workspace`, `get_workspace` — workspace management
- `store_memory`, `search_memories`, `recall_relevant_context` — memory CRUD
- `auto_session_start`, `summarize_session` — session lifecycle
- `workflow`, `rlm_process` — advanced workflows
- And more

### Lifecycle Hooks (`hooks/hooks.json`)

- **SessionStart** — injects relevant memory context at session start
- **PostToolUse** — observes file edits and tool usage for automatic memory capture
- **PreCompact** — saves state marker before context compaction
- **Stop** — deregisters session and polls for pending events

### RLM Agents (`agents/`)

- **context-loader** — loads large files into RLM for chunk-based processing
- **result-aggregator** — aggregates results from RLM processing chains
- **task-decomposer** — decomposes complex tasks into RLM-processable chunks

### Commands (`commands/`)

- `/decompose` — decompose a large file or task using RLM
- `/load-context` — load content into RLM memory for processing
- `/rlm-status` — check status of active RLM execution chains

### Status Line (`scripts/statusline.sh`)

Shows memory count, version info, and update availability. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "command": "bash \"~/.claude/plugins/recall/scripts/statusline.sh\"",
    "type": "command",
    "padding": 0
  }
}
```

## Pricing

- **Free** — 100 memories, 1 workspace
- **Pro** ($9/mo) — unlimited memories, workspaces, webhooks, priority support
- **Team** & **Enterprise** plans available

See [recallmcp.com/#pricing](https://recallmcp.com/#pricing) for details.

## Links

- [recallmcp.com](https://recallmcp.com) — Cloud hosted service
- [Documentation](https://recallmcp.com/dashboard/docs) — Full docs
- [Changelog](https://recallmcp.com/#changelog) — Release history
- [GitHub (open source)](https://github.com/joseairosa/recall) — Self-hosted server

## License

MIT
