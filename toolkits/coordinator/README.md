# coordinator

The coordinator's MCP servers, and the one place a server is added for it.
`bin/claude-coordinator` loads it into the coordinator alone; no worker gets it (`team-worker` refuses `--toolkit coordinator`).

## What it holds

- `.mcp.json`: the coordinator's MCP servers, today none.
  `claude-coordinator` replaces `@TEAM_CODE@` in it with its checkout, writes it to `~/.local/state/agent-team/coordinator.mcp.json` and passes it with `--mcp-config`.
- No plugin manifest, skill or hook: the coordinator's skills are `plugins/coordinator-skills/`, and its hooks are in `coordinator.settings.json`.

## Why it holds nothing yet

From 2026-10-27, by Daniel's decision in T52, the coordinator stops loading Daniel's own MCP servers (user, local and project scope, and the servers of plugins Daniel enables) and every claude.ai connector, and gets only this toolkit's servers.
Before, it loaded about 450 tools from `vercel` and `resend` alone, with `playwright`, `codegraph`, the claude.ai Claude Docs connector and the `mongodb-atlas` plugin's server, and its manual names none of them.
Its one MCP server is the Discord plugin's, which is how Daniel reaches it and which it keeps.

## How the others stay out

`--strict-mcp-config`, which keeps a worker to its toolkits, connects no plugin server, so it would cut the Discord channel too.
`claude-coordinator` therefore leaves it off and, at each launch:

- runs `claude mcp list` in the coordinator's working directory and puts every server it names in the settings' `deniedMcpServers`, but for this toolkit's servers and those of a plugin `coordinator.settings.json` enables (Discord);
- keeps `disableClaudeAiConnectors: true` from `coordinator.settings.json`, so no claude.ai connector loads, a new one included.

A server Daniel adds later is denied at the coordinator's next launch, with no change here.

## Adding a server

A new server needs Daniel's yes, then one entry under `mcpServers` in `.mcp.json`, through a PR like any code change.
Give a stdio server's paths as `@TEAM_CODE@/...`, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
Say here why the coordinator needs it.
It takes effect at the coordinator's next launch, which a restart (`team-resume`, with Daniel's yes) gives.

A claude.ai connector cannot be added here: it signs in through claude.ai, not a config entry, and needs `disableClaudeAiConnectors` lifted in `coordinator.settings.json` instead.

## Tests

`tests/claude-coordinator.bats` checks that the launch passes this toolkit's servers with `--mcp-config` and no `--strict-mcp-config`, that the settings deny every server `claude mcp list` names but this toolkit's and the Discord plugin's, that the claude.ai connectors are off, and that the Discord plugin and its channel stay on.
