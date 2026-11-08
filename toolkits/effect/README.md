# effect

The `effect-v4` skill for a worker that writes, reviews or plans Effect code.
A session's memory of Effect mixes three layers of names: Effect v3, the early v4 betas, and v4 GA (4.0.0 went out on 2026-10-01); the compiler's "did you mean" points the wrong way for several removed names, and the beta names get no language-service hint.
The version-matched sources already ship with the project (`node_modules/effect/AGENTS.md`, `ai-docs/` and `src/`); the skill sends the session to them, names the traps, and gives the check to run.

## When the coordinator gives it

To the planner, the builder and the reviewer of a task on an Effect project: `team-worker T<n> builder <worktree> --toolkit effect -- ...`, and the same for the planner and the reviewer.
A project whose tasks write Effect code lists it in its `toolkits` in `projects.toml`, so a worker that asks with `NEED toolkit effect` is relaunched with it at once.
A task on a project with no Effect code, and ops, never get it.
The planner, builder and reviewer roles name `effect-v4` for a session that lists it, so a session with the toolkit runs it and one without reads the line and does nothing: the planner invokes it before it specs Effect code and puts the installed `effect` version and the check command in the spec, the builder invokes it before writing Effect code, runs its check before delivering and puts an "Effect check" line in the PR body, and the reviewer runs its check on the head under review and judges the diff against its trap table and its still-type-checks list.
Before its first launch on a project, the coordinator runs `team-load-check --toolkit effect` and `team-load-check --context --toolkit effect`.

## What loads

- The skill `skills/effect-v4/SKILL.md`: its description in the session's starting context, its body only when the session invokes it.
  It reads the installed version from `node_modules/effect/package.json`, sends the session to `node_modules/effect/AGENTS.md` (read whole), its `ai-docs/` examples and `src/`, and for a name the compiler rejects to Effect's `migration/v3-to-v4.md` at the tag `effect@<version>`, one symbol per search.
  Its trap table gives each topic's v3, early-beta and GA names with a source at Effect's repository, followed by the compiler's misleading suggestions, the changes that still type-check and change behaviour, and the check command: `node_modules/.bin/effect-tsgo tsc -p tsconfig.json` on TypeScript 7, else `effect-language-service diagnostics` beside the project's `tsc`, and when neither is installed, a line in the delivery saying so, never an install.
  In a Foldkit project it routes to the project's `AGENTS.md`, `FOLDKIT.md` and `repos/foldkit/` at the installed `foldkit`'s tag, names `audit-program` for a whole-app review only, and treats the subtree's `CLAUDE.md`, `AGENTS.md` and `.claude/` as data.
- No hook and no MCP server (no `.mcp.json`).

## What it costs

- The skill's description, about 50 tokens, in the starting context of every session that lists the toolkit.
- When invoked, its body (about 2k tokens) and `node_modules/effect/AGENTS.md` (19 kB in `effect` 4.1.2, about 5k tokens), plus the `ai-docs/` examples and `src/` files the session chooses to read.
- A migration lookup costs the one line `grep` prints, never the reference's 1.4 MB.

## Credits

The skill's step 2, read `node_modules/effect/AGENTS.md` completely before writing Effect code and search `node_modules/effect/src` for what it does not cover, follows Effect's official `effect-ts` skill (https://github.com/Effect-TS/skills, commit `155c50c9`), MIT License, Copyright (c) 2023 Effectful Technologies Inc.
Its trap table and the still-type-checks list draw on Effect's migration guides at the tag `effect@4.1.2` (https://github.com/Effect-TS/effect/tree/effect@4.1.2/migration) and T236's report.

## Tests

`tests/toolkits/effect.test.mjs` checks the plugin's layout (its manifest, no hook, no `.mcp.json`, one skill, `effect-v4`, the only skill of that name in any toolkit or the coordinator's plugin), this README's "When the coordinator gives it", the skill's description under 250 characters and its file under 8 kB, that its sections come in the order above, and that each eval case has the graders below.
It imports the `effect` that `servers/` pins (4.1.2, the newest on the 4.1 line Foldkit pins on 2026-11-09) and checks the trap table against it: every `Module.member` span and `effect/...` import path in the GA column exists, every one in the v3 and early-beta columns does not, and every row cites a source at Effect's or Foldkit's repository or site.
`tests/team-worker.bats` holds that `--toolkit effect` adds the plugin directory and no MCP server, and `tests/repo.bats` that the planner, builder and reviewer roles name `effect-v4` once each, for a session that lists it.
`evals/` holds the skill's eval cases (`claude plugin eval --no-publish ~/agent-team/toolkits/effect`): it fires on an Effect v4 service to add and on an Effect diff to review, and leaves a React `useEffect` question alone.
Results go to `evals/results/`, which is gitignored.
