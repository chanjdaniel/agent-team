# coordinator

The coordinator's MCP servers, and the one place a server is added for it.
`bin/claude-coordinator` loads it into the coordinator alone; no worker gets it (`team-worker` refuses `--toolkit coordinator`).

## What it holds

- `.mcp.json`: the coordinator's MCP servers, today none.
  `claude-coordinator` replaces `@TEAM_CODE@` in it with its checkout, writes it to `~/.local/state/agent-team/coordinator.mcp.json` and passes it with `--mcp-config`.
- `connectors.json`: the claude.ai connectors it keeps, by the exact name `claude mcp list` prints, today `claude.ai Claude Docs`.
  A connector signs in through claude.ai, not a config entry, so it cannot be in `.mcp.json`; Claude Code loads Daniel's connectors itself, and the launch denies every one not named here.
- No plugin manifest, skill or hook: the coordinator's skills are `plugins/coordinator-skills/`, and its hooks are in `coordinator.settings.json`.

## Why it holds so little

From 2026-10-27, by Daniel's decision in T52, the coordinator stops loading Daniel's own MCP servers (user, local and project scope, and the servers of plugins Daniel enables) and the claude.ai connectors, and gets only this toolkit's.
Before, it loaded about 450 tools from `vercel` and `resend` alone, with `playwright`, `codegraph`, the claude.ai Claude Docs connector and the `mongodb-atlas` plugin's server, and its manual names none of them.
It keeps the Discord plugin's server, which is how Daniel reaches it, and, by Daniel's choice, the Claude Docs connector, with which it kept documents for Daniel (2026-10-20 to 10-23).

## How the others stay out

`--strict-mcp-config`, which keeps a worker to its toolkits, connects no plugin server, so it would cut the Discord channel too.
`claude-coordinator` therefore leaves it off and, at each launch, runs `claude mcp list` in the coordinator's working directory and puts every server it names in the settings' `deniedMcpServers`, but for this toolkit's servers, its kept connectors and the servers of a plugin `coordinator.settings.json` enables (Discord).

A server or connector Daniel adds later is denied at the coordinator's next launch, with no change here.

## Adding a server

A new server needs Daniel's yes, then one entry under `mcpServers` in `.mcp.json`, through a PR like any code change.
Give a stdio server's paths as `@TEAM_CODE@/...`, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
Say here why the coordinator needs it.
It takes effect at the coordinator's next launch, which a restart (`team-resume`, with Daniel's yes) gives.

A claude.ai connector is kept the same way, by Daniel's yes and its exact name added to `connectors.json`, once Daniel has connected it on claude.ai.

## Tests

`tests/claude-coordinator.bats` checks that the launch passes this toolkit's servers with `--mcp-config` and no `--strict-mcp-config`, that the settings deny every server and connector `claude mcp list` names but this toolkit's, its kept connectors (by exact name) and the Discord plugin's, and that the Discord plugin and its channel stay on.
