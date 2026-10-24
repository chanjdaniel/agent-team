# SOP: platform gotchas

Every worker reads this before its first command, as its brief says.
Each entry is a general rule about the tools the team runs on (Claude Code, git, the gate, Docker, the machine), with why it holds and where the team hit it.
The retro proposes adding, merging and dropping entries, and Daniel approves every change, which lands through a PR on the code repository, since this file is code.

## Put a flag that takes many values before the other options, or end the options with `--`

Why: a variadic flag such as `--mcp-config`, `--add-dir` or `--allowedTools` takes every argument after it as one of its values, so a positional argument right behind it, a prompt say, is swallowed.

Seen: `team-worker`'s launch, whose first prompt was swallowed so the session started idle (2026-10-21; the launch comment in `bin/team-worker`, and the coordinator's memory `~/.claude/projects/-home-danielc-agent-team/memory/agent-team-design-decisions.md`).

## Keep a background session's working files out of `.claude/` directories, except `.claude/worktrees/`

Why: Claude Code protects `.claude/` paths, so allow rules never pre-approve a write there and every write prompts, which a background session cannot answer.

Seen: T16 ticket 04's load check, whose sessions in `.claude/load-check/wt` blocked on their first write (ledger 2026-10-22T14:09:42Z; T16 build note 04, archived under `tasks/T16/` at its close).

## Never run a command that may call `sudo`

Why: with no terminal each `sudo` attempt counts as a failed login, enough of them lock Daniel's account, and installer flags and system package steps call it unasked.

Seen: T18, whose test script's Playwright `--with-deps` locked Daniel's account (ledger 2026-10-22T12:16:15Z, `tasks/T18/plan.md`).

## Create a bind mount's host directory before starting the container, and run containers as your own user

Why: Docker creates a missing source directory as root, and a container running as root writes root-owned files into the worktree, which no session can remove without `sudo`.

Seen: T3's `npm ci` EACCES on a root-owned `node_modules` mount (`tasks/T3/report.md`); T21's root-owned gate worktree (ledger 2026-10-23T06:14:20Z); T24's re-clone, stopped by two root-owned gate worktrees (ledger 2026-10-23T15:36:38Z).

## Once a PR is open and its checks are green, stop the gate run, and treat any commit that lands after the review as unreviewed

Why: the gate's CI step may push "apply CI fixes" commits on its own, after the reviewer has read the head.

Seen: T4 and T18, whose reviews found such commits (`tasks/T4/scratch/review.md`, `tasks/T18/scratch/review.md`); T5, where one set a `verified` date that had not come yet (`tasks/T5/brief-revert.md`); T24, whose brief stops the gate run (`tasks/T24/brief-build-01.md`).

## Wait for work with a command that blocks until it ends, never a sleep loop or a self-set timer

Why: auto mode refuses a timer as persistence, three refusals in a row leave a background session on a prompt nobody sees, and commands such as `gh pr checks --watch` and `docker compose up --wait` wait without one.

Seen: T17 ticket 08, whose builder stuck on that prompt and was relaunched (ledger 2026-10-22T14:40:56Z).

## When a tool rewrites the remote branch under you, start a fresh local branch from the remote one and carry your commits over

Why: a reset throws away local commits and auto mode refuses it, and a force-push throws away what the tool pushed.

Seen: T12 and T22 (twice), whose gate rebased and force-pushed their branches (ledger 2026-10-22T12:05:30Z, 2026-10-23T13:57:02Z; T22 builder `b782adf4` at 2026-10-23T23:27Z).

## After the machine's packages are upgraded, check that Docker answers before a gate run, and leave a daemon restart to Daniel

Why: daemons keep running their old binaries until restarted, a restart needs `sudo`, and `docker info` shows whether Docker still answers.

Seen: T5, T12 and T15, which waited on Daniel's restart (ledger 2026-10-22T00:09:49Z to 2026-10-22T11:08:03Z).

## In a permission rule, pin the command's fixed parts on both sides of each `*`

Why: `*` matches any text, spaces and other arguments included, so a rule matches more commands than it looks: an allow rule lets more through, and a deny rule refuses commands that only quote its words.

Seen: T20's review of the reviewer's allow rules (`tasks/T20/scratch/review.md`); T25, where a deny rule refused a quoted jq filter and a heredoc naming a script (ledger 2026-10-23T12:58:54Z, 2026-10-23T13:15:36Z); T34's `gh api*git/refs*` and T24's `git *config*core.hooksPath*`, which refused reads (ledger 2026-10-24T00:04:36Z, 2026-10-24T01:28:18Z).

## To know what a CI or deploy run built, read the commit its checkout fetched, never the run's branch and commit label

Why: GitHub labels a run started by another workflow (`workflow_run`) or a schedule with the default branch and that branch's tip when it started, whatever it checked out, so the label can name code that never ran; the checkout step's log (`HEAD is now at`) and `workflow_run.head_sha` say what did.

Seen: T24's force-push, where a Deploy labelled "dev 5694c2af" had deployed `main` at `0fa47646`, and production was nearly migrated for code it did not run (ledger 2026-10-23T15:13:26Z to 15:20:46Z; `tasks/T29/scratch/early-finding.md`).
