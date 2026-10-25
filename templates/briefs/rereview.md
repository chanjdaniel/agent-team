# {{task}} brief (reviewer): re-review {{title}} at its new head

Path: {{path}}; you are the reviewer of a PR that was reviewed before.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, reviewed at `{{reviewed}}`, now at head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, and `review.md` with the last review's findings.
Since the last review: {{since}}

## Check

1. Every blocking finding in `{{task_dir}}/review.md` is fixed at `{{head}}`, or the PR records Daniel's decision to keep it.
{{> rereview}}
3. Run each of the project's local checks ({{local_checks}}) from the worktree's root on `{{head}}`, and if `gh pr checks {{pr}}` lists any GitHub checks, wait for them to finish (`--watch`); every one must pass, and `{{task_dir}}/review.md` says which local checks passed (they set no GitHub status).

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, write the same result alone to `{{task_dir}}/rereview.md`, and post that as one PR comment with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/rereview.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `{{head}}`, the head you reviewed, and refuses when the PR has moved past it: then set nothing and tell the coordinator.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
