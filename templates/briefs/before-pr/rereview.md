# {{task}} brief (reviewer): re-review {{title}} at its new local head

Path: {{path}}; you are the reviewer of a branch that was reviewed before, with no PR yet.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
No PR yet: reviewed at `{{reviewed}}`, now at the local head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, and `review.md` with the last review's findings.

## Since the last review

{{since}}

## Instruction and settings files

{{instruction_files}}

## Check

1. Every finding in `{{task_dir}}/review.md` that went back to the builder (each `blocking`, `note: correctness`, `note: security` and `note: real-data`, and each plain `note` whose scope is `change`) is fixed at `{{head}}`, or the task records Daniel's decision to keep it; a plain `note` whose scope is `before`, on code the branch did not change, is queued as a follow-up, not for this task.
   A finding with a test plan is answered by the test it planned, passing at `{{head}}`, and a note in `{{task_dir}}/build-notes/` saying whether it failed before the fix or the suspicion was wrong.
{{> rereview}}
3. Run the project's local checks ({{local_checks}}) on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head; every one must pass, and `{{task_dir}}/review.md` says which local checks passed (they set no GitHub status, and with no PR there are no GitHub checks to wait for).
{{> review-rules}}

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, its new findings numbered on from the last, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and one scope, `change` (a line the branch adds or changes) or `before` (code it did not change); then write the same result alone to `{{task_dir}}/rereview.md`.
  Mark a new finding `widening` when it sits in code or text the fix since `{{reviewed}}` added for an earlier finding, so reverting that fix would end it, and give their numbers in `rereview.md`'s counts as `widening=<numbers, comma-separated, or none>`.
  Give in it the count of each kind among the findings that stand at `{{head}}`, its new ones and any earlier one sent back and not fixed, the plain notes as `note-change` and `note-before` (0 for none), the numbers of its new `before` notes, and the guarded areas the change touches, of `ci`, `migrations`, `deploy`, `permissions`, `secrets` and `guardrails`, by the paths `{{team_code}}/bin/lib/guarded` lists for the project or by what the code does in a file of any name (CI or the checks a PR must pass, a migration of production data, the deploy, auth or permission checks, secrets handling and, on agent-team, the team's guards), or none.
  Post nothing to GitHub: there is no PR yet, and the re-review of the PR, once the builder opens it, posts the comment and sets the status.
- Send `{{task}} DONE pass {{head}} findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none> widening=<the widening findings' numbers, comma-separated, or none>` or `{{task}} DONE findings {{task_dir}}/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none> widening=<the widening findings' numbers, comma-separated, or none>` to `coordinator`, the counts, numbers and areas as `{{task_dir}}/rereview.md` gives them.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
