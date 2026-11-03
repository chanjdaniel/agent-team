# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner running the team's retro, and the report is the deliverable.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`, never pushed.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).
The high-level plan: `{{plan}}`.

## Read, in this order

1. First, the ledger's evidence for this retro's window, in both forms: `{{team_bin}}/team-retro digest {{task}}` and `{{team_bin}}/team-retro digest {{task}} --json`.
   It reads the team home's live ledger: the window, blocks and denials, questions, reviews, waits by whom, history rewrites, injections, the tasks in the window with their record directories and sessions, and the changes.
   Its Changes are the earlier retros' changes that landed or closed unmerged in the window, or were still open at its end, which the report's first part judges.
   Then where the window's time went: `{{team_bin}}/team-time --since <the window's since> --until <its until>`, hours per task and per phase, gate runs, reviews and Daniel's answer latency.
   It is also each worker's lifetime: the averages by role, path, project and model, the longest, and where the workers' time went, with what the task was doing while a worker waited.
2. The previous retro, when the digest's window names one (`previous retro T<m>`): its report, `{{team_home}}/tasks/T<m>/scratch/report.md`, and Daniel's answer to it, T<m>'s `answered` event with `id` `retro` in `{{team_home}}/ledger.jsonl`.
   Its proposals' Judge by lines, where it has them, are the measures the report's first part counts.
3. What Daniel approved and the team has not built yet: `{{team_home}}/tasks/queued/` and the reports its plans point at.
   A problem one of them already answers goes under "Considered, not proposed", naming it.
4. The records of each task in the digest, under its record directory: `plan.md`, the briefs, and in `scratch/` the archived `review.md`, `rereview*.md` and `build-notes/`.
5. The team as it stands, in your worktree: `roles/`, `templates/`, `settings/`, `sops/` and `bin/`, against which you write exact changes.
6. A session's transcript (`claude logs <session>`, with the digest's session ids) only where the ledger and the records leave a cause unclear.
   Never quote a secret or anyone's personal details from it.

## Deliver, in `{{task_dir}}/`

1. `report.md`, in five parts, in this order:
   - **What the last changes did**: one row per change in the digest's Changes: the change (its retro, its proposals and its task), where it landed (its PRs, or the records), the events it was meant to reduce counted in two equal spans before and after it landed, each span named by its start and end, and a verdict of `helped`, `hurt`, `no observed effect` or `confounded`.
     Count the events the earlier report's Judge by line names for that proposal, when it gave one; else name the events you count and why.
     The verdict is `confounded` when another change landed in the same spans and touches the same events, or when the counts are too few to tell from chance, as a rule fewer than three on either side.
     A follow-up lands only once its task is closed, its landing time being its last merge, so a change is judged once, in the window its task closed in, even when it merged in an earlier one.
     A change open at the window's end, its PRs merged so far listed, gets a row with no verdict, at each retro until it lands or closes; one closed unmerged gets a row with no verdict once, in the window it closed in, the only one whose digest lists it.
     A `hurt` row becomes a proposal to revert or revise the change, ranked with the others.
   - **Worker time**: the lifetimes by role (median, 90th percentile, longest) against the previous retro's when its report has them; the five longest lifetimes, each with its top sinks and, from the task's records, why; and the top sinks across workers with the hours each cost.
   - **Proposals**: open them with the standing text's size: the bytes of `CLAUDE.md`, each `roles/*.md` and `sops/platform-gotchas.md` at this retro's base against the previous retro's, each base being its retro's `opened` event's `base_sha`.
     Then at most seven proposals, ranked by what the problem cost (hours lost, times repeated), the costliest first, a sink's hours from Worker time counting as cost.
     Each has a number, a title, and these, in this order:
     - **Lane**: `team` (roles, briefs, settings, hooks, scripts, SOPs) or `project <name>` (its `review-rules.md`, `CLAUDE.md` or memory); a change that still makes sense on another project is `team`, one that does not is its project's.
     - **Form**: the cheapest that holds, in this order of what it costs every session's context: a hook or a script (enforced, no standing text); an on-demand skill or toolkit; a line in one brief template; and last, standing text in a role, `CLAUDE.md` or `sops/platform-gotchas.md`.
       A hook rests on repeated evidence and names the test showing valid work still passes it.
       Give the bytes of standing text the change adds and cuts; one that adds names what it cuts to pay for it, or says why nothing can go.
     - **Cue**: the shape of situation it applies to, not one task's facts.
     - **Lesson**: the change itself in one sentence, naming the file.
     - **Evidence**: ledger events by time and task, file paths, and the sink it answers, when it answers one; and the earliest point the work went wrong, not only where it surfaced.
     - **Confidence**: high, medium or low, and why.
     - **Exact change**: the exact text, or a diff against the file in your worktree; for a script or a hook, the behaviour and its test.
     - **Expected effect**: what it changes for the team.
     - **Judge by**: the events, counted from the ledger, the next retro will compare before and after it lands.

     A problem seen once is not proposed unless its cost was high, which the proposal says.
     Before proposing a line, check the target files do not already say it: a rule already written and still broken is proposed in a stronger form, never as a second copy.
     "Keep as is" is a good outcome: a retro with fewer than seven proposals, or none, is a good retro when the evidence supports no more.
   - **SOP review**: each entry of `sops/platform-gotchas.md`, with keep, merge (and with which) or drop, and why; and whether its problem recurred in the window, with the events, since an entry whose problem recurred is prose that does not hold, a candidate for a stronger form.
   - **Considered, not proposed**: one line each.
2. Send `{{task}} DONE {{task_dir}}/report.md` to `coordinator`.

## Daniel's bar for the SOP

An entry is a general rule, useful across projects and contexts, with its reason; never a story about one task, which belongs on the entry's `Seen:` line.
Prefer sharpening, merging or dropping entries to adding them, and keep the list short.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Propose, and change nothing else: Daniel approves every proposal, and an approved one becomes its own task.
Never propose again what Daniel rejected at an earlier retro, or what is already approved and queued, unless there is new evidence, which you name.
Never read or print secrets (`.env` values, tokens).
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
