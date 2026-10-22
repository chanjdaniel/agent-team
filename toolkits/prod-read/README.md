# prod-read

Read-only access to Conventioner's production database, for the ops role only.

Status: the server and its tests exist; the skill, docs and evals come with T16's later tickets.

## What it runs

- One stdio MCP server, `prod-read`, declared in `.mcp.json`: `node @TEAM_HOME@/toolkits/prod-read/scripts/start-server.mjs`.
  `team-worker` replaces `@TEAM_HOME@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher reads `op://agent-team/conventioner-prod-read/uri` from 1Password, signs `op` out, and starts the pinned MongoDB MCP server (`servers/`, installed by `servers/install`) in the same process, so the connection string is never in a starting environment.
  The shared body is `servers/mongodb-mcp.mjs`.
- The server is read-only, with server-side JavaScript, telemetry and disk logs off.

## Tools

`aggregate`, `aggregate-db`, `collection-indexes`, `collection-schema`, `collection-storage-size`, `count`, `db-stats`, `explain`, `find`, `list-collections`, `list-databases`, named `mcp__prod-read__<tool>` in a session.
Nothing else: no `connect`, `export`, `mongodb-logs` or `list-connections`, and no Atlas, Atlas Local or assistant tools.

## Tests

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed and a throwaway MongoDB 8.0 in Docker, and checks the tool set, the read-only refusals and that the connection string never leaks (`tests/toolkits/prod-read.test.mjs`).
