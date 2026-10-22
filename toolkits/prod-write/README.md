# prod-write

Document writes and index changes in Conventioner's production database, for the ops role only, and only beside `prod-read` for a write request.

Status: the server and its tests exist; the skill, docs and evals come with T16's later tickets.

## What it runs

- One stdio MCP server, `prod-write`, declared in `.mcp.json`: `node @TEAM_HOME@/toolkits/prod-write/scripts/start-server.mjs`.
  `team-worker` replaces `@TEAM_HOME@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher reads `op://agent-team/conventioner-prod-write/uri` from 1Password, signs `op` out, and starts the pinned MongoDB MCP server (`servers/`, installed by `servers/install`) in the same process, so the connection string is never in a starting environment.
  The shared body is `servers/mongodb-mcp.mjs`.
- The server writes, with server-side JavaScript, telemetry and disk logs off, and its own confirmation list empty: it never asks the client to confirm a call.
- The Atlas user it connects as, `conventioner-ops-write`, holds the custom role `conventionerOpsWrite` (document writes and index changes on `conventioner`), so the database refuses dropping or renaming a collection and dropping the database.

## Tools

`create-index`, `delete-many`, `drop-index`, `insert-many`, `update-many`, named `mcp__prod-write__<tool>` in a session.
Nothing else: no reads (a write session reads through `prod-read`), no `connect`, `export`, `mongodb-logs` or `list-connections`, no create, drop or rename of a collection or database, and no Atlas, Atlas Local or assistant tools.

## The gate

Every tool is under an `ask` rule in `settings/ops.json` (`mcp__*prod-write*`, and each tool by name in both naming forms), so each call raises a permission prompt that reaches Daniel's phone, in auto mode too.
No allow rule matches a `prod-write` tool, and `team-worker` refuses `prod-write` for any role but `ops` and without `prod-read`.

## Tests

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed and a throwaway MongoDB 8.0 in Docker, and checks the tool set, that each tool changes the data as asked with no elicitation request, that `conventionerOpsWrite` is enough for every tool and refused a drop, and that the connection string never leaks (`tests/toolkits/prod-write.test.mjs`).
`tests/team-worker.bats` checks the generated settings and MCP config of a write launch.
