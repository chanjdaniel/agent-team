# prod-mongo

Verified backups of Conventioner's production database, and drills that prove they restore, for the `ops` role only.
The backups land in `~/conventioner-backups` on Daniel's machine, and every answer is counts, sizes and paths, never a document.

## What loads

The MCP tools, from the server's own `tools/list` (`evals/mocks/prod-mongo/_tools.json`), as an ops launch names them:

```text
mcp__prod-mongo__backup
mcp__prod-mongo__list-backups
mcp__prod-mongo__restore-drill
```

Nothing else: no tool writes to the database, restores to production, takes a path or a connection string, or reads a dump back.
The skill is `backing-up-production-data` (`skills/`), the only one this toolkit adds.
This list is the server's, not yet a live session's: the ops load check's inventory (`team-load-check --role ops --toolkit prod-mongo`), once it has run on Daniel's real credential, replaces it.
`docs/access.md` says what the toolkit can and cannot reach, and `docs/restoring.md`, for Daniel, where the dumps are, how to drill one by hand, and how to restore one to production or delete it.

## Its credential

The read user's connection string, the same as `prod-read`'s, lives only in 1Password, at `op://agent-team/conventioner-prod-read/uri` (vault `agent-team`, item `conventioner-prod-read`, field `uri`); this toolkit holds the reference, never the value.
Each launch raises one 1Password prompt, even for a session that only drills or lists.

## What it runs

- One stdio MCP server, `prod-mongo`, declared in `.mcp.json`: `node @TEAM_CODE@/toolkits/prod-mongo/scripts/start-server.mjs`, with a 90-minute `timeout`, which raises Claude Code's 30-minute idle limit for a long call.
  `team-worker` replaces `@TEAM_CODE@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher holds only the settings (`scripts/settings.mjs`: the name, the reference, the database `conventioner` and the folder `~/conventioner-backups`), and calls the body, `servers/prod-mongo/server.mjs`.
  Before it reads the secret, the body checks `mongodump` is on `PATH` (the lock's MongoDB Database Tools, which `team-doctor` names the install of), so no prompt is spent on a launch that cannot back up; it then reads the reference with `op read`, signs `op` out, and keeps the value in its own memory only.
- `backup` connects with the pinned MongoDB driver (`servers/package.json`), counts every collection before and after, and runs `mongodump --config=<fifo> --db conventioner --gzip`, the connection string written once to a FIFO inside the dump's own 0700 folder and unlinked at once, so it is never in an argument list, an environment, a file at rest or a log.
  It then counts the documents in each dumped file and reads its index names, and removes a dump that does not match.
- `list-backups` reads only the folder: no database, no child process.
- `restore-drill` runs `bin/team-heavy run --wait 20 --kind restore-drill -- node scripts/restore-drill.mjs <stamp>`, so a drill queues behind the machine's other heavy runs; the script starts the throwaway MongoDB with `docker` (`servers/prod-mongo/throwaway.mjs`), restores the dump into it with `mongorestore --config=<fifo>`, compares, records, and removes the throwaway.
  The script reads no credential and takes no connection string.
- Every child process gets an environment built from a short list (`childEnv`, `servers/prod-mongo/children.mjs`), never the server's own, and every child's error reaches an answer only scrubbed of connection strings, the secret and its hosts.
- Only an ops launch starts it: every other session's settings deny a shell command that runs a `start-server.mjs` (with `node`, `bun`, `deno` or `env`, or by its path, though no file here is executable), one that names the server's body (`servers/prod-mongo/server.mjs`, whose start a `node -e` import could call) or the launcher's settings (`scripts/settings.mjs`) after `node`, or behind `env`, `bun` or `deno`, and a `claude` given a production toolkit by `--plugin-dir` or `--mcp-config`; reading the files stays allowed, and the planner load check proves a shell is refused the body's import.
  These are speed bumps (`tests/repo.bats`): Daniel's rule of approving a 1Password prompt only right after an announced launch is what holds.
- An ops launch takes it alone, beside `prod-read`, or beside `prod-read` and `prod-write`, never beside `vercel-read` (`bin/team-worker`).
  The ops settings (`settings/ops.json`) allow its tools with no prompt, and deny the session's own file tools the backups folder (`Read(~/conventioner-backups/**)` and `Edit(~/conventioner-backups/**)`, which cover Grep, Glob and Write too).
  The ops-log hook (`bin/hooks/ops-log`) logs each call's requested, ran or failed line in the task's ops log, and blocks a call whose requested line it cannot write, as it does a write.

## What it leaves behind

- On disk, only under `~/conventioner-backups` (mode 0700): each dump's folder, `<stamp>/`, holding `manifest.json`, `dump/conventioner/` (each collection's `.bson.gz` and `.metadata.json.gz`) and `drills/<at>.json`, each drill's verdict, every directory 0700 and every file 0600.
  A dump that fails its check leaves nothing; a server killed mid-dump may leave a `.<stamp>.partial/`, which `list-backups` names as left unfinished.
  The toolkit never deletes a dump: `backup` and `list-backups` name those past the rule that keeps the 5 newest verified ones, for Daniel to delete by hand.
- In Docker, nothing once a drill ends: its throwaway (`prod-mongo-drill-<hex>`, labelled `owner=agent-team`, `kind=drill`, `toolkit=prod-mongo` and an `expires` an hour on) is removed on every path, on SIGINT, SIGTERM and SIGHUP too, and one whose drill was killed outright ends itself within the hour; the next drill removes any container, network or image of the toolkit past its `expires` (`sops/docker.md`).

## The scripts by hand

`scripts/restore-drill.mjs <stamp> [--text]` is the drill the tool runs, for Daniel or the coordinator, through the same lock:

```bash
~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text
```

`--text` prints the tool's answer; without it, one JSON object.
`docs/restoring.md` has the rest, and the restore to production, which only Daniel runs.

## Tests and evals

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed, a throwaway MongoDB 8.0 in Docker for production and another to restore into, the lock's Database Tools from the test's own `PATH` (CI's `toolkits` job installs them), and spies on `mongodump`, `mongorestore` and `docker` first on the server's `PATH` (`tests/toolkits/prod-mongo.test.mjs`).
It checks the tool set, each tool's answers and files with their modes, that the connection string never reaches an argument list, an environment, a file or an answer, the backups folder's rules, the drill's container and its removal on every path, and the script by hand.
`evals/` holds the skill's eval cases (`claude plugin eval`): each prompt is a rendered ops brief, and every `prod-mongo` call is answered by a fixed mock (`evals/mocks/prod-mongo/`, one case's own under `evals/<case>/mocks/`), never by the real server, which a run starts only with `--allow-real-servers` or `--mocks off`.
`evals/mocks/prod-mongo/_tools.json` is the server's own `tools/list`, which the toolkit test above keeps in step.
Run them against this directory, keeping the report local: `claude plugin eval toolkits/prod-mongo --no-publish`.
Results go to `evals/results/`, which is gitignored.
