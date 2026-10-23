# prod-read

Read-only access to Conventioner's production database, for the `ops` role only.
`team-worker` refuses it for any other role, and the planner load check fails if any `prod-` tool or skill reaches a non-ops worker.

## What loads

The MCP tools, pasted from the ops load check's inventory (`team-load-check --role ops --toolkit prod-read`, 2026-10-23 13:10Z, the MCP lines of `tasks/T0/inventory-prod-read.txt`):

```text
mcp__prod-read__list-collections
mcp__prod-read__aggregate
mcp__prod-read__aggregate-db
mcp__prod-read__collection-indexes
mcp__prod-read__collection-schema
mcp__prod-read__collection-storage-size
mcp__prod-read__count
mcp__prod-read__db-stats
mcp__prod-read__explain
mcp__prod-read__find
mcp__prod-read__list-databases
```

Nothing else: no `connect`, `export`, `mongodb-logs` or `list-connections`, and no Atlas, Atlas Local or assistant tools.
The skill is `querying-production-data` (`skills/`), the only one an ops session can invoke: the load check's inventory of 2026-10-23 15:12Z lists `skill: prod-read:querying-production-data` and no other, since `settings/ops.json` turns off Claude Code's bundled skills and its built-in `plugin-authoring` plugin.
`docs/access.md` says what the toolkit can and cannot reach.

## Its credential

The read user's connection string lives only in 1Password, at `op://agent-team/conventioner-prod-read/uri` (vault `agent-team`, item `conventioner-prod-read`, field `uri`); this toolkit holds the reference, never the value.

## What it runs

- One stdio MCP server, `prod-read`, declared in `.mcp.json`: `node @TEAM_HOME@/toolkits/prod-read/scripts/start-server.mjs`.
  `team-worker` replaces `@TEAM_HOME@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher reads the reference with `op read` (a 1Password prompt on the PC), signs `op` out, and starts the pinned MongoDB MCP server (`servers/`, installed by `servers/install`) in the same process, so the connection string is never in a starting environment.
  The shared body is `servers/mongodb-mcp.mjs`.
- Only an ops launch starts it: every other session's settings deny a shell command naming the launcher or `servers/mongodb-mcp.mjs`, or a `claude` given a production toolkit by `--plugin-dir` or `--mcp-config`, and a worker is denied `team-worker`'s ops role and the ops load check.
  These are speed bumps (`tests/repo.bats`): Daniel's rule of approving a 1Password prompt only right after an announced launch is what holds.
- The server is read-only, with server-side JavaScript, telemetry and disk logs off.

## Tests and evals

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed and a throwaway MongoDB 8.0 in Docker, and checks the tool set, the read-only refusals and that the connection string never leaks (`tests/toolkits/prod-read.test.mjs`).
`evals/` holds the skill's eval cases (`claude plugin eval`): each prompt is a rendered ops brief, and every `prod-read` call is answered by an agent mock over a made-up dataset (`evals/mocks/prod-read/_server.md`), never by the real server, which a run starts only with `--allow-real-servers` or `--mocks off`.
`evals/mocks/prod-read/_tools.json` is the server's own `tools/list`, which the toolkit test above keeps in step.
Results go to `evals/results/`, which is gitignored.
