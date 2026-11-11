# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner: a detailed spec and tickets.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).

## Read first

- The high-level plan: `{{plan}}`.
{{read}}{{ui}}

## Ask Daniel only what is theirs to decide

Choose what the plan and the code settle, and state it in the spec; facts are yours to look up in the code, the docs and the project's records, never to ask.
When choices that are Daniel's stay open, ask them in rounds: a round holds every open choice whose prerequisites are settled, at most 8, and a choice whose answer hangs on one still open waits for a later round.

1. Write the round to `{{worktree}}/{{task_dir}}/questions-<round>.md`: a first line saying how many choices it holds, since the ping to Daniel quotes it, then each choice as a line `**Q<n>** - **<title>**: <the choice>` with the options you see, then a line `Recommended: <the option and why>`, numbered on from the last round's.
2. Send `{{task}} QUESTION <that path>` to `coordinator`, one message for the whole round, and wait for the answer.
3. Ask the next round once the answers settle what it hangs on, or go on to the spec once no choice of Daniel's is open.

## Deliver, in `{{task_dir}}/`

1. `spec.md`, following `~/.claude/skills/to-spec/SKILL.md` (read and follow it; do not stop to check seams with the user: choose them and state them).
   Its Implementation Decisions name each choice a builder would otherwise make (a library, a file's place, a default, an error's handling, wording users see, which cases a test covers) and how it was made, and end with the line `Left to the builder: none`, or each choice left open and why.
   When the project keeps a glossary (`CONTEXT.md`) or ADRs (`docs/adr/`), it also lists the new glossary terms and the ADR candidates the builder should write.
2. `tickets/NN-<slug>.md`, following `~/.claude/skills/to-tickets/SKILL.md` the same way (skip its quiz), each with one `Blocked by:` line, written `Blocked by: None` or `Blocked by: 01, 03` (the two-digit numbers of this task's tickets, nothing else on the line), at most one `Waits for: <an outside condition>` line (a PR, another task) when it must wait on something outside the task, either label optionally bold, and a `- [ ]` acceptance list, and small enough for one fresh builder who reads only `spec.md`, that ticket and the files it names.
   With more than eight tickets, or when another open or queued task waits on files this one changes, group them into phases in `spec.md`: each phase ends in its own PR that leaves `{{base}}` working, and the phase that changes the files others wait on comes first; give each ticket of a phase after the first a `Phase: <n>` line, which `team-next` reads to hand a phase's last ticket on to that phase's deliverer.
3. `scope.txt`, every path the tickets change, one repository path per line: a file, or a directory ending in `/` that covers everything under it, with no leading `/`, no `.` or `..` and no glob; the coordinator puts it to Daniel with the plan, whose approval may let the PR merge with no second ask when it changes nothing outside it.
4. Run `{{team_bin}}/team-tickets {{task}} --check` and fix each line it names.
5. Send `{{task}} DONE {{task_dir}}/spec.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
