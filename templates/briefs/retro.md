# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner running the team's retro, and the report is the deliverable.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`, never pushed.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).
The high-level plan: `{{plan}}`.

## Read, in this order

1. First, the ledger's evidence for this retro's window, in both forms: `{{team_bin}}/team-retro digest {{task}}` and `{{team_bin}}/team-retro digest {{task}} --json`.
   It reads the team home's live ledger: the window, blocks and denials, questions, reviews, waits by whom, history rewrites, injections, and the tasks in the window with their record directories and sessions.
2. The previous retro, when the digest's window names one (`previous retro T<m>`): its report, `{{team_home}}/tasks/T<m>/scratch/report.md`, and Daniel's answer to it, T<m>'s `answered` event with `id` `retro` in `{{team_home}}/ledger.jsonl`.
3. What Daniel approved and the team has not built yet: `{{team_home}}/tasks/queued/` and the reports its plans point at.
   A problem one of them already answers goes under "Considered, not proposed", naming it.
4. The records of each task in the digest, under its record directory: `plan.md`, the briefs, and in `scratch/` the archived `review.md`, `rereview*.md` and `build-notes/`.
5. The team as it stands, in your worktree: `roles/`, `templates/`, `settings/`, `sops/` and `bin/`, against which you write exact changes.
6. A session's transcript (`claude logs <session>`, with the digest's session ids) only where the ledger and the records leave a cause unclear.
   Never quote a secret or anyone's personal details from it.

## Deliver, in `{{task_dir}}/`

1. `report.md`, in three parts:
   - **Proposals**: at most seven, ranked by what the problem cost (hours lost, times repeated), the costliest first.
     Each has a number, a title, its kind (a rule, a role line, a brief line, a settings change, an SOP entry to add, merge or drop, a script), its evidence (ledger events by time and task, file paths), the exact change (the exact text, or a diff against the file in your worktree; for a script, the behaviour and its test) and the expected effect.
   - **SOP review**: each entry of `sops/platform-gotchas.md`, with keep, merge (and with which) or drop, and why.
   - **Considered, not proposed**: one line each.
2. Send `{{task}} DONE {{task_dir}}/report.md` to `coordinator`.

## Daniel's bar for the SOP

An entry is a general rule, useful across projects and contexts, with its reason; never a story about one task, which belongs on the entry's `Seen:` line.
Prefer sharpening, merging or dropping entries to adding them, and keep the list short.

## Rules

Read `{{team_home}}/sops/platform-gotchas.md` before your first command.
Propose, and change nothing else: Daniel approves every proposal, and an approved one becomes its own task.
Never propose again what Daniel rejected at an earlier retro, or what is already approved and queued, unless there is new evidence, which you name.
Never read or print secrets (`.env` values, tokens).
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
