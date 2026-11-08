# effect

The `effect-v4` skill for a worker that writes, reviews or plans Effect code, and a post-edit hook that gives the session Effect's language service's findings on each TypeScript file it edits.
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
- The hook `hooks/hooks.json`: one `PostToolUse` hook on `Edit|Write|MultiEdit`, which runs `scripts/effect-diagnostics.mjs` with Node; the script's header is its full contract.
  For a `.ts`, `.tsx`, `.mts` or `.cts` file that is no declaration file, lies under the session's `cwd` and outside any `node_modules`, and has a `node_modules/.bin/effect-tsgo` in some directory from its own up to `cwd`, it runs the nearest one as `diagnostics --file <file> --format text`, with no version or tag argument, in a process group of its own.
  The file's findings, whatever the exit code, come back as the hook's additional context under one line naming the file, cut at 4,000 characters with a line saying how many were cut and naming the skill's check; a clean file, or one the project's tsconfig does not include, gives nothing.
  On its deadline it kills the process group and gives one line naming the file, the deadline and the check to run before delivering; a failure of the tool gives one line with the exit code and the first line of its stderr; it never blocks the edit.
  The findings are Effect's rules only (`outdatedApi` names a v3 API's v4 replacement, as "Renamed to forkChild"), never type errors, which the skill's check gives.
  A project below TypeScript 7, with `@effect/language-service` only, has no `effect-tsgo`, so it gets no hook findings, only the skill's check.
  For a planner or a reviewer, who edit only Markdown in the task directory, it gives nothing.
  It needs no network: on Linux, `tests/toolkits/effect.test.mjs` runs it inside `unshare -rn`, a namespace with no network, and gets the same findings as outside it; on macOS that test is skipped, so there it was not shown.
- No MCP server (no `.mcp.json`).

## What it costs

- The skill's description, about 50 tokens, in the starting context of every session that lists the toolkit.
- When invoked, its body (about 2k tokens) and `node_modules/effect/AGENTS.md` (19 kB in `effect` 4.1.2, about 5k tokens), plus the `ai-docs/` examples and `src/` files the session chooses to read.
- A migration lookup costs the one line `grep` prints, never the reference's 1.4 MB.
- The hook's findings, only on an edit of a file that has some, at most 4,000 characters (about 1k tokens); a clean file costs nothing.
  Its time, measured on 2026-11-09 on this machine (11 CPUs, a load of about 5) as Claude Code runs it, on Foldkit's own `packages/foldkit/src` at the tag `foldkit@0.170.0` (335 TypeScript files, 110,283 lines) in a scratch project whose `node_modules` was the `servers/` install: a cold first run of 0.82 s on its largest file (6,648 lines), and over 24 warm runs on files of 2 to 6,648 lines a median of 0.37 s and a worst of 0.68 s (a second round of 24: 0.33 s and 0.58 s).
  `effect` resolved there; `vitest`, `@effect/vitest`, `parse5` and `@effect/platform-browser` did not, since `servers/` has none of them, so a Foldkit project with all of its dependencies installed checks a larger program and may take longer.
  The hook's deadline is 3 s: the worst warm run times 3 is 2.04 s, below the 3 s floor (at most 15 s); its `timeout` in `hooks/hooks.json` is the deadline plus 5 s, 8 s.

## Credits

The skill's step 2, read `node_modules/effect/AGENTS.md` completely before writing Effect code and search `node_modules/effect/src` for what it does not cover, follows Effect's official `effect-ts` skill (https://github.com/Effect-TS/skills, commit `155c50c9`), MIT License, Copyright (c) 2023 Effectful Technologies Inc.
Its trap table and the still-type-checks list draw on Effect's migration guides at the tag `effect@4.1.2` (https://github.com/Effect-TS/effect/tree/effect@4.1.2/migration) and T236's report.

## Tests

`tests/toolkits/effect.test.mjs` checks the plugin's layout (its manifest, one `PostToolUse` hook with its matcher, command and timeout, no `.mcp.json`, one skill, `effect-v4`, the only skill of that name in any toolkit or the coordinator's plugin), this README's "When the coordinator gives it", the skill's description under 250 characters and its file under 8 kB, that its sections come in the order above, and that each eval case has the graders below.
It imports the `effect` that `servers/` pins (4.1.2, the newest on the 4.1 line Foldkit pins on 2026-11-09) and checks the trap table against it: every `Module.member` span and `effect/...` import path in the GA column exists, every one in the v3 and early-beta columns does not, and every row cites a source at Effect's or Foldkit's repository or site.
`tests/team-worker.bats` holds that `--toolkit effect` adds the plugin directory and no MCP server, and `tests/repo.bats` that the planner, builder and reviewer roles name `effect-v4` once each, for a session that lists it.
`evals/` holds the skill's eval cases (`claude plugin eval --no-publish ~/agent-team/toolkits/effect`): it fires on an Effect v4 service to add and on an Effect diff to review, and leaves a React `useEffect` question alone.
Results go to `evals/results/`, which is gitignored.

The same file runs the hook as Claude Code runs a plugin's (its command through a shell, `CLAUDE_PLUGIN_ROOT` set, the `PostToolUse` event on stdin) on a copy of `tests/toolkits/fixtures/effect-project/` whose `node_modules` links to `servers/node_modules`, against the `effect-tsgo` that `servers/` pins (`@effect/tsgo` 0.67.5, with `typescript` 7.0.2, which its `diagnostics` needs installed, and `effect` 4.1.2, the newest of each on its line on 2026-11-09).
It shows a finding naming `catch` for `Effect.catchAll` and one naming `forkChild` for `Effect.fork`, in the documented JSON shape and headed by the file's path; nothing for a clean v4 file, a `.md` file, a declaration file, a file outside `cwd`, a file under `node_modules`, a file the tsconfig does not include, or a worktree with no `effect-tsgo`; and the same findings inside `unshare -rn` on Linux.
Stub `effect-tsgo` binaries show that the hook never starts one for a file it skips, passes it the file and no version or tag, gives the one timeout line within its deadline and leaves no process of its group, keeps the 3 s deadline above with no seam set, cuts many findings at 4,000 characters with the cut-lines line, and gives the one failure line.
It runs the skill's check command, as the skill writes it, on the fixture and sees the v3 renames.
