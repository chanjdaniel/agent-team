# vercel-read

Read-only access to Conventioner's two Vercel projects, `makers-market-management-front-end` and `makers-market-management-back-end`, for the `ops` role only.
`team-worker` refuses it for any other role, and the planner load check fails if any `vercel-read` tool or skill reaches a non-ops worker.
An ops session takes it alone (`--toolkit vercel-read`) for a Vercel question, or beside `prod-read` for one that spans the database too.

## What loads

The MCP tools, pasted from the ops load check's inventory on Daniel's tokens (`team-load-check --role ops --toolkit vercel-read`, 2026-11-09 12:47Z, the MCP lines of `tasks/T0/inventory-vercel-read.txt`):

```text
mcp__vercel-read__list-deployments
mcp__vercel-read__domain-deployment
mcp__vercel-read__get-deployment
mcp__vercel-read__list-env-names
mcp__vercel-read__runtime-logs
```

Nothing else: every tool is read-only by its annotations, and none deploys, promotes, rolls back, or reads or changes a variable's value.
The skill is `reading-vercel-deployments` (`skills/`), the only one an ops session given `vercel-read` alone can invoke: the same inventory lists `skill: vercel-read:reading-vercel-deployments` and no other.
`docs/access.md` says what the toolkit can and cannot reach.

## Its credential

Two project-scoped Vercel tokens, one per project, live only in 1Password, in the `agent-team` vault, item `conventioner-vercel-read`, beside the Vercel team id and the two project ids, which stay out of this public repository:

- `op://agent-team/conventioner-vercel-read/team-id`, the id of the team `chanjdaniels-projects`;
- `op://agent-team/conventioner-vercel-read/front-end-project-id` and `.../front-end-token`, for `makers-market-management-front-end`;
- `op://agent-team/conventioner-vercel-read/back-end-project-id` and `.../back-end-token`, for `makers-market-management-back-end`.

This toolkit holds the references, never the values.

## What it runs

- One stdio MCP server, `vercel-read`, declared in `.mcp.json`: `node @TEAM_CODE@/toolkits/vercel-read/scripts/start-server.mjs`.
  `team-worker` replaces `@TEAM_CODE@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher holds only Conventioner's facts (the 1Password references of the team id and of each project's id and token, the projects' names and their domains) and calls the shared body, `servers/vercel-mcp.mjs`: the team's own server on the pinned `@modelcontextprotocol/sdk` and Node's `fetch`, not Vercel's MCP server or CLI.
- The body reads the five references with `op read`, one after the other, then signs `op` out, so 1Password asks once; it keeps the tokens only in its own memory, and refuses to start on a token Vercel refuses or on one that reaches the other project too.
- Every request it makes is a `GET` to `https://api.vercel.com` on one of five fixed endpoints, for the two project ids it read, and every answer is built from a list of allowed fields, with email addresses, phone numbers, URL credentials, tokens, private keys and credential-named values masked in free text.
- Only an ops launch starts it: every other session's settings deny a shell command that runs the launcher or the body (with `node`, `bun`, `deno` or `env`, or by its path, though neither file is executable), while reading them stays allowed, or a `claude` given the toolkit by `--plugin-dir` or `--mcp-config`; every worker is denied the `vercel` CLI, and an ops session has no shell at all.
  These are speed bumps (`tests/repo.bats`): Daniel's rule of approving a 1Password prompt only right after an announced launch is what holds.

## Tests and evals

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed and a fake Vercel API on the loopback that answers with values, emails and secrets, and checks the tool set, each tool's answers and refusals, the masking, that only the allowed requests were sent, and that no token, value or dropped field leaks (`tests/toolkits/vercel-read.test.mjs`).
`evals/` holds the skill's eval cases (`claude plugin eval`): each prompt is a rendered ops brief, and every `vercel-read` call is answered by an agent mock over made-up deployments, logs and variable names (`evals/mocks/vercel-read/_server.md`), never by the real server, which a run starts only with `--allow-real-servers` or `--mocks off`.
`evals/mocks/vercel-read/_tools.json` is the server's own `tools/list`, which the toolkit test above keeps in step.
Results go to `evals/results/`, which is gitignored.
