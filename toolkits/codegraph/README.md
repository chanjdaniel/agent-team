# codegraph

A session-start hook that builds or syncs a worktree's own CodeGraph index and tells the session to locate code with it.
CodeGraph (the `codegraph` CLI, already on the machine) answers "where is this and what calls it" in one call, printing the relevant symbols' source with line numbers and the call paths between them, which can stand in for a run of greps and whole-file reads.
A project that chose CodeGraph tracks a `.codegraph/` directory, but a fresh worktree's holds only the tracked `.gitignore`, so `codegraph` there says "Not initialized" until something builds the index; this toolkit does, for the sessions it is given to.

## When the coordinator gives it

To the builders and reviewers of a setup trial's arm: `team-worker T<n> builder <worktree> --toolkit codegraph -- ...`, and the same for the reviewer, which `team-next` carries forward from the task's first builder, so a whole task is in one arm.
How a trial gives it to alternate tasks of one project, what it measures and how it ends are in the "Trialling a setup change" section of `sops/model-trials.md`; the first such trial is CodeGraph on Conventioner.
The coordinator gives it on a project only once that project lists `codegraph` in its `toolkits` in `projects.toml`, though `team-worker` loads it wherever it is asked for.

## When it prints

The hook (`hooks/hooks.json`, one `SessionStart` hook with no matcher, so it runs on startup, resume, clear and compact, and a compacted session gets the banner back) runs `scripts/codegraph-banner`, whose header gives its steps.
It prints nothing, and runs no `codegraph`, unless the session's role (`AGENT_TEAM_ROLE`) is `builder` or `reviewer`, `codegraph` is on PATH, and the session's directory (the event's `cwd`) has a `.codegraph/` directory at its root.
Then it runs `codegraph init <dir>` when `codegraph status --json` reports the directory uninitialised, else `codegraph sync <dir>`, with their output kept out of the session's context, and prints a banner of five lines: the index is ready; start with `codegraph explore "<symbol names or a question>"` before grep, find or whole-file reads; `codegraph node <name>` for one symbol; `codegraph sync` after editing, since the index does not follow edits; and still read the exact lines edited or judged.
When a `codegraph` command fails, it prints one line naming the command and its exit status, saying to locate code as usual, and the session starts.
It always exits 0, within the hook's 30-second timeout: a fresh index of Conventioner (1,136 files) took 4.1 seconds on 2026-11-09, a sync 0.2 seconds.

## What it writes

In the worktree, only CodeGraph's own files in its `.codegraph/`, which the project's tracked `.codegraph/.gitignore` ignores: about 110 MB for a Conventioner worktree.
Its `codegraph` calls run with `CODEGRAPH_TELEMETRY=0` and `DO_NOT_TRACK=1`, so CodeGraph keeps no usage counts in `~/.codegraph/` and sends none, whatever the machine's telemetry setting.
It starts no daemon: the CLI's `init`, `sync` and `explore` leave none running.
It runs `init` without `--yes`, whose default would install git sync hooks where CodeGraph's file watching is off.
No MCP server (no `.mcp.json`) and no skill.

## What it is not

It is the trial's minimal form of the queued "CodeGraph in every worktree" task, which may later add CodeGraph's MCP server for workers, a registry key and indexing at `team-open`; the trial's result tells that task whether the wider rollout pays.

## Tests

`tests/toolkits/codegraph.test.mjs` checks the plugin's layout and runs the hook's command as Claude Code would, with `CLAUDE_PLUGIN_ROOT` set and a SessionStart event on stdin, on a stub `codegraph` that records its arguments and that telemetry is off: init then the banner, sync then the banner, each failing command's one line, and nothing for no `.codegraph/`, no `codegraph`, or a role other than builder and reviewer.
Where a real `codegraph` is on PATH it also runs the hook against it on a small project the test writes, and checks the banner names only subcommands the installed CLI has; on CI, which installs none, those cases skip.
`tests/team-worker.bats` checks that `--toolkit codegraph` adds the plugin directory and no MCP server.
