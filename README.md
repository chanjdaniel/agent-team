# agent-team

A team of Claude Code sessions that plans, builds, reviews and ships software changes.
A coordinator session talks to its owner on Discord and turns each request into a task.
Each task gets one background session per role (planner, builder, reviewer, ops), each in its own git worktree, briefed by the coordinator and reporting back to it.
The ledger, an append-only file of every task's events, is the record of what happened and the state every command reads.

This repository holds the code: the `team-*` commands, the role prompts, the sessions' settings and hooks, the toolkits and the tests.
`CLAUDE.md` describes it in full.

## A reference, not a product

This is Daniel's own setup, published as a reference, without support.
It names Daniel's Discord server, 1Password vault and GitHub repositories, and it is not made to run for anyone else as it is.
Read it, borrow from it, fork it; issues and pull requests may go unanswered.

## Two repositories

The team runs from two checkouts on each machine:

- **The code**, this repository, checked out at `~/agent-team`, with the tasks' worktrees under it.
- **The team home**, a private repository of records, checked out beside it and named in `~/.config/agent-team/home`.

The scripts depend on the team home holding:

| Path | What it holds |
| - | - |
| `ledger.jsonl` | Every task's events, one JSON object per line, each checked against `bin/lib/ledger-contract.json` |
| `projects.toml` | The project registry: each project the team works on, its repository, checkout, base branch and delivery; `team-project`'s help documents every key |
| `tasks/` | Each task's plan, briefs and archived scratch |
| `projects/` | Each project's planning |
| `memory/` | The Claude Code auto memory each project shares across machines, and the coordinator's |
| `machine/` | What a machine needs beyond the code: the shared Claude user config (`machine/claude/`) and the list of secret files to restore from 1Password (`machine/secrets.json`) |
| `manual-steps.md` | The steps only the owner can take |

`CLAUDE.md`, "The team home", says how the scripts find it.

## Requirements

- Arch Linux or macOS.
- Bash 5, jq and Python 3.11 or later.
- Claude Code, and the other tools `bin/lib/tools.lock` pins (`team-doctor` checks each one and prints its install command).
- For the toolkit tests, Node.js and Docker.

## Tests

`tests/run` runs shellcheck on every shell script, the bats suite (bats-core is vendored) and the toolkit tests.
`tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each.
The suite runs the real scripts in a sandbox with a temporary home, stubs for every outside service and a team home of fixtures, so it needs no records and reaches no real service.

## License

Apache License 2.0; see `LICENSE`.
The vendored bats-core in `tests/vendor/bats-core/` keeps its own license.

## For Daniel

To set up a machine as a host, open `claude` in any folder on a machine with only Claude Code installed and send:

> Set up this machine as a host for my agent team. The repo is github.com/chanjdaniel/agent-team and it is private: install gh, sign me in to GitHub with it, clone the repo to ~/agent-team, then follow its SETUP.md.

From there `SETUP.md` drives the setup and asks for each step that is yours.
Say "set up as host" again in a later session to pick up where it stopped.
