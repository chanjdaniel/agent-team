# spec-review

The `spec-review` skill, for a planner whose spec and tickets are about to go to the coordinator for approval.
A planner writes `spec.md` and the tickets with everything it learned in its head, so the first readers without that context are the builders, and a choice the spec left open stops a builder at the most expensive place to settle it.
The skill has two fresh readers, who get only paths, read the spec and tickets before anyone builds: one as a stranger who says in its own words what the spec changes and how the system works today, one as the builder who checks each ticket against the code.
Their findings go to `spec-review.md` in the task directory, where the spec's author sorts each one as fixed, contested with a line a reader could have read, or escalated to the coordinator.

## When the coordinator gives it

To a planner on the build path, `team-worker T<n> planner <worktree> --toolkit spec-review -- ...`, once T240's phase 3 makes the review a planner step; until then, a planner's brief does not name it.
To T240's phase 2 replay builder, `team-worker T240 builder <worktree> --toolkit spec-review -- ...`, which reviews archived specs it did not write, so the skill stops once the readers' part is written.
`team-worker` loads it from the code checkout `~/agent-team`, so a session can list it only once the PR that adds it is merged.
Before its first launch, the coordinator runs `team-load-check --toolkit spec-review` and `team-load-check --context --toolkit spec-review`.

## What loads

- The skill `skills/spec-review/SKILL.md`: its description in the session's starting context, its body only when the session invokes it as `/spec-review [<task dir>] [<code root>] [--model sonnet|opus]`.
  The task directory defaults to `.scratch/task` and the code root to the session's working directory, so a planner runs it with no arguments and a replay names an archived spec's copy and the project's tree at its base commit.
  It dispatches both readers in one message, retries a reader that fails once and records a second failure as `not run`, writes `spec-review.md` (the paraphrase verbatim, then a findings table and an `escalated:` last line), and, when the session wrote the spec, has it add the paraphrase's misreadings and sort every finding.
- The agent `agents/spec-paraphrase.md`, dispatched as `spec-review:spec-paraphrase`: it reads only `spec.md` and the tickets and returns "What this changes", "How the system works today, per this spec" and "Could not follow".
- The agent `agents/spec-readiness.md`, dispatched as `spec-review:spec-readiness`: it reads the code root's `CLAUDE.md` and `AGENTS.md`, `spec.md`, `scope.txt` and each ticket with the files it names, checks with Grep and Glob that each name the spec says exists does, and returns its findings (`open-decision`, `missing`, `contradiction` or `too-large`, each `blocking` or `note`, each on a line) and the files it read.
- Both agents have only Read, Grep and Glob, and `omitClaudeMd: true`, since the session's `CLAUDE.md` is the worktree's, which in a replay is not the archived project's: the readiness reader reads the code root's own instead.
  Both run on `model: inherit`, the session's model, unless the skill is given `--model`; T240's replay chooses the model they will name.
  Both are told never to read the task directory beyond their inputs: no plan, brief, interview, memory, handoff, build note or other review.
  The readiness reader keeps its searches out of the task directory when it lies under the code root.
- No MCP server, hook or script.

## What it costs

- The skill's description, about 60 tokens, in the starting context of every session that lists the toolkit, and the two agents' descriptions, about 60 tokens each, in its Agent tool's list.
- Per review: measured by T240's replay.

## Credits

Its method is adapted from google/elephant-goldfish-model (https://github.com/google/elephant-goldfish-model, commit e9e1f06), Apache License 2.0.
That repository's `LICENSE` at `e9e1f06` is the stock Apache 2.0 text with its copyright placeholder unfilled, and its files carry no copyright line (read 2026-11-09), so the attribution names no holder.
No file or text of it is vendored or installed: the skill's and the agents' prompts are the team's own, and only the method (a reader with no context, a paraphrase read against the author's intent, findings the author sorts with evidence a reader could check) comes from it.

## Tests

`tests/toolkits/spec-review.test.mjs` checks the plugin's layout (its manifest, two agents, one skill, `spec-review`, the only skill of that name in any toolkit or the coordinator's plugin, and no `.mcp.json`, `hooks/` or `scripts/`), both agents' frontmatter (`tools` exactly Read, Grep and Glob, `omitClaudeMd: true`, a `model`), the task files they are told never to read and their return shapes, the skill's description under 250 characters and its file under 8 kB, that its eight steps come in order, this README's sections, its "When the coordinator gives it" and its attribution line, and each eval case's graders.
`tests/team-worker.bats` holds that `--toolkit spec-review` adds the plugin directory and no MCP server.
`evals/` holds four cases, each a `case.yaml` whose `scaffold.sh` writes its fixture into the run's empty workspace: `review-a-spec` plants an open choice and a function the code does not have in a small spec, and passes when the skill fires, both readers are dispatched and the reply has both faults as `blocking` findings of the right kinds; `review-a-code-diff` asks for a review of a shell diff and passes when the skill does not fire.
`planner-notes-stay-out` puts a planner's `memory.md` and `plan.md` beside its spec in a git checkout's gitignored `.scratch/task/`, and passes when no reader's own message in the trace holds their paths or their text, since Glob lists gitignored files.
`replay-an-ignored-tree` reviews an archived spec against a project copied under that gitignored `.scratch/`, as T240's replay does, and passes when the readiness reader finds the function the copy has in a file no line names, and reports missing only the one it lacks.
Run them from the code checkout with `claude plugin eval toolkits/spec-review --no-publish --scaffold --ablation none --trust-plugin`, and check the plugin with `claude plugin validate --strict toolkits/spec-review`.
Results go to `evals/results/`, which is gitignored.
