# prod-write

Document writes and index changes in Conventioner's production database, for the `ops` role only, and only beside `prod-read` for a write request.
`team-worker` refuses it for any other role and without `prod-read`, and the planner load check fails if any `prod-` tool or skill reaches a non-ops worker.

## What loads

The MCP tools, pasted from the ops load check's inventory (`team-load-check --role ops --toolkit prod-read --toolkit prod-write`, 2026-10-23 13:35Z, the `prod-write` lines of `tasks/T0/inventory-prod-write.txt`):

```text
mcp__prod-write__create-index
mcp__prod-write__delete-many
mcp__prod-write__drop-index
mcp__prod-write__insert-many
mcp__prod-write__update-many
```

Nothing else: no reads (a write session reads through `prod-read`), no `connect`, `export`, `mongodb-logs` or `list-connections`, no create, drop or rename of a collection or database, and no Atlas, Atlas Local or assistant tools.
The skill is `changing-production-data` (`skills/`), and `docs/access.md` says what the toolkit can and cannot reach.
With `prod-read` beside it, the load check's inventory of 2026-10-23 15:33Z lists `skill: prod-read:querying-production-data` and `skill: prod-write:changing-production-data` and no other, since `settings/ops.json` turns off Claude Code's bundled skills and its built-in `plugin-authoring` plugin.

## Its credential

The write user's connection string lives only in 1Password, at `op://agent-team/conventioner-prod-write/uri` (vault `agent-team`, item `conventioner-prod-write`, field `uri`); this toolkit holds the reference, never the value.

## What it runs

- One stdio MCP server, `prod-write`, declared in `.mcp.json`: `node @TEAM_HOME@/toolkits/prod-write/scripts/start-server.mjs`.
  `team-worker` replaces `@TEAM_HOME@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher reads the reference with `op read` (its own 1Password prompt on the PC), signs `op` out, and starts the pinned MongoDB MCP server (`servers/`, installed by `servers/install`) in the same process, so the connection string is never in a starting environment.
  The shared body is `servers/mongodb-mcp.mjs`.
- Only an ops launch starts it: every other session's settings deny a shell command naming the launcher or `servers/mongodb-mcp.mjs`, or a `claude` given a production toolkit by `--plugin-dir` or `--mcp-config`, and a worker is denied `team-worker`'s ops role and the ops load check.
  These are speed bumps (`tests/repo.bats`): Daniel's rule of approving a 1Password prompt only right after an announced launch is what holds.
- The server writes, with server-side JavaScript, telemetry and disk logs off, and its own confirmation list empty: it never asks the client to confirm a call.
- The Atlas user it connects as, `conventioner-ops-write`, holds the custom role `conventionerOpsWrite` (document writes and index changes on `conventioner`), so the database refuses dropping or renaming a collection and dropping the database.

## The gate

Every tool is under an `ask` rule in `settings/ops.json` (`mcp__*prod-write*`, and each tool by name in both naming forms), so each call raises a permission prompt that reaches Daniel's phone, in auto mode too.
No allow rule matches a `prod-write` tool.

## Tests and evals

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed and a throwaway MongoDB 8.0 in Docker, and checks the tool set, that each tool changes the data as asked with no elicitation request, that `conventionerOpsWrite` is enough for every tool and refused a drop, and that the connection string never leaks (`tests/toolkits/prod-write.test.mjs`).
`tests/team-worker.bats` checks the generated settings and MCP config of a write launch.
`evals/` holds the skill's eval cases (`claude plugin eval`), which load `prod-read` beside this toolkit: each prompt is a rendered ops brief, `prod-read` calls are answered by an agent mock over a made-up dataset and `prod-write` calls by fixed mocks (`evals/mocks/`), never by the real servers, which a run starts only with `--allow-real-servers` or `--mocks off`.
Each `evals/mocks/<server>/_tools.json` is that server's own `tools/list`, which the toolkit tests keep in step.
A case may load only plugins under the directory the eval runs against, so these run against `toolkits/` with `--eval-dir prod-write/evals` (and `--ablation with-without`, which a plugin target would get by default), not against this toolkit's own directory.
Results go to `evals/results/`, which is gitignored.
