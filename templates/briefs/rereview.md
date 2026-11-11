# {{task}} brief (reviewer): re-review {{title}} at its new head

Path: {{path}}; you are the reviewer of a PR that was reviewed before.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, reviewed at `{{reviewed}}`, now at head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, and `review.md` with the last review's findings.

## Since the last review

{{since}}

## Instruction and settings files

{{instruction_files}}

## Check

1. First start the wait for the PR's GitHub checks with `{{team_bin}}/team-ci-wait {{pr}} {{head}}`, run with Bash `run_in_background`, so the run and your reading overlap (a pass delivers only once it has ended; a rereview that sends any finding back delivers as soon as `{{task_dir}}/rereview.md` is written, naming in its CI section the checks still running, and a wait that ends after it delivered needs nothing more), and run the project's local checks ({{local_checks}}) on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head; every one must pass, and `{{task_dir}}/review.md` says which local checks passed (they set no GitHub status).
   Act on how the wait ended: exit 0, every check passed or the head has none; exit 1, read each failure it names by its class: each `the PR's:` line is a `blocking` finding, a `roll-up:` line is never a finding, and an `infrastructure:` line (a stuck check's among them) is no finding but goes to `coordinator` as `{{task}} BLOCKED <the line>`; on a head other than `{{head}}`, read the runs of `{{head}}` itself with `gh run list --repo {{repo}} --commit {{head}}`, since the builder pushes its fix of a failed check at once: each failed run is a `blocking` finding, and only when none failed does the moved head, as an `infrastructure:` line does, go to `coordinator` as `{{task}} BLOCKED <its message>`; exit 75, run it again, or report as its message says.
   When a check failed as the PR's, the PR has usually moved past `{{head}}` by the time you deliver, and `team-review-status` refuses your head: post your comment as usual, set no status, and send your `DONE findings` with each `the PR's:` line counted as `blocking`, which the coordinator takes on a moved head; that move is no `BLOCKED`.
{{> rereview}}
3. Every finding in `{{task_dir}}/review.md` that went back to the builder (each `blocking`, `note: correctness`, `note: security` and `note: real-data`, and each plain `note` whose scope is `change`) is fixed at `{{head}}`, or the PR records Daniel's decision to keep it; a plain `note` whose scope is `before`, on code the PR did not change, is queued as a follow-up, not for this PR.
   A finding with a test plan is answered by the test it planned, passing at `{{head}}`, and a note in `{{task_dir}}/build-notes/` saying whether it failed before the fix or the suspicion was wrong.
{{> review-rules}}

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, its new findings numbered on from the last, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and one scope, `change` (a line the PR adds or changes) or `before` (code it did not change); then write the same result alone to `{{task_dir}}/rereview.md`.
  Mark a new finding `widening` when it sits in code or text the fix since `{{reviewed}}` added for an earlier finding, so reverting that fix would end it, and give their numbers in `rereview.md`'s counts as `widening=<numbers, comma-separated, or none>`.
  Give in it the count of each kind among the findings that stand at `{{head}}`, its new ones and any earlier one sent back and not fixed, the plain notes as `note-change` and `note-before` (0 for none), the numbers of its new `before` notes, and the guarded areas the change touches, of `ci`, `dependencies`, `migrations`, `settings`, `permissions`, `secrets` and `guardrails`, by the paths `{{team_code}}/bin/lib/guarded` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none.
  Post that as one PR comment with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/rereview.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `{{head}}`, the head you reviewed, and refuses when the PR has moved past it: then set nothing, and when a failed check of `{{head}}` explains the move, as step 1 says, send your `DONE findings` below as usual; otherwise tell the coordinator.
- Send `{{task}} DONE pass {{pr}} findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none> widening=<the widening findings' numbers, comma-separated, or none>` or `{{task}} DONE findings {{task_dir}}/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none> widening=<the widening findings' numbers, comma-separated, or none>` to `coordinator`, the counts, numbers and areas as `{{task_dir}}/rereview.md` gives them.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
