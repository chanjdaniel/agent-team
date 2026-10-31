# {{task}} brief (reviewer): re-review {{title}} at its new head

Path: {{path}}; you are the reviewer of a PR that was reviewed before.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, reviewed at `{{reviewed}}`, now at head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, and `review.md` with the last review's findings.
Since the last review: {{since}}

## Check

1. Every finding in `{{task_dir}}/review.md` that went back to the builder (each `blocking`, `note: correctness`, `note: security` and `note: real-data`) is fixed at `{{head}}`, or the PR records Daniel's decision to keep it; a plain `note` is a follow-up, not for this PR.
   A finding with a test plan is answered by the test it planned, passing at `{{head}}`, and a note in `{{task_dir}}/build-notes/` saying whether it failed before the fix or the suspicion was wrong.
{{> rereview}}
3. Run the project's local checks ({{local_checks}}) on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head, and wait for the PR's GitHub checks with `{{team_bin}}/team-ci-wait {{pr}} {{head}}`, run with Bash `run_in_background`; every one must pass, and `{{task_dir}}/review.md` says which local checks passed (they set no GitHub status).
   Act on how the wait ended: exit 0, every check passed or the head has none; exit 1, each failed check it names is a `blocking` finding, while a stuck check or a head other than `{{head}}` goes to `coordinator` as `{{task}} BLOCKED <its message>`; exit 75, run it again, or report as its message says.

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, its new findings numbered on from the last, each with its file and line and one kind: `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`; then write the same result alone to `{{task_dir}}/rereview.md`.
  Give in it the count of each kind among the findings that stand at `{{head}}`, its new ones and any earlier one not fixed (0 for none), and the guarded areas the change touches, of `ci`, `dependencies`, `migrations`, `settings`, `permissions` and `secrets`, by the paths `{{team_code}}/bin/lib/guarded` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none.
  Post that as one PR comment with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/rereview.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `{{head}}`, the head you reviewed, and refuses when the PR has moved past it: then set nothing and tell the coordinator.
- Send `{{task}} DONE pass {{pr}} findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note:<n> guarded=<areas, comma-separated, or none>` or `{{task}} DONE findings {{task_dir}}/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note:<n> guarded=<areas, comma-separated, or none>` to `coordinator`, the counts and areas as `{{task_dir}}/rereview.md` gives them.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
