# {{task}} brief (reviewer): verify the notes fixed on {{title}}

Path: {{path}}; you are the reviewer of a fix round whose findings were all plain notes on lines the branch adds or changes, with no PR yet.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
No PR yet: reviewed at `{{reviewed}}`, now at the local head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `review.md` with the last review's findings.
Sent back: the notes numbered {{findings}} in `{{task_dir}}/review.md`, each a plain `note` whose scope is `change`.

## Check

1. Run the project's local checks ({{local_checks}}) on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head; every one must pass, and `{{task_dir}}/rereview.md` says which local checks passed (they set no GitHub status, and with no PR there are no GitHub checks to wait for).
{{> rereview}}
   Read nothing else: not the rest of the branch, the spec's or the story's acceptance list, or the knowledge graph; run the UI check only when that diff touches a UI file and your session lists `ui-check`, on the states it touched and their siblings.
3. Every note sent back ({{findings}}) is fixed at `{{head}}`, and the diff holds nothing but those fixes and their tests.
   When it changes more than the notes asked, this brief does not fit: send `{{task}} BLOCKED not a notes-only fix: <what else changed>` to `coordinator`.
   Raise a new finding only on a line this diff adds or changes, so each new one's scope is `change`.
{{> review-rules}}

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, its new findings numbered on from the last, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and its scope, `change`; then write the same result alone to `{{task_dir}}/rereview.md`.
  Give in it the count of each kind among the findings that stand at `{{head}}`, its new ones and any note sent back and not fixed, the plain notes as `note-change` and `note-before` (0 for none), and the guarded areas the change touches, of `ci`, `dependencies`, `migrations`, `settings`, `permissions` and `secrets`, by the paths `{{team_code}}/bin/lib/guarded` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none.
  Post nothing to GitHub: there is no PR yet, and the re-review of the PR, once the builder opens it, posts the comment and sets the status.
- Send `{{task}} DONE pass {{head}} findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` or `{{task}} DONE findings {{task_dir}}/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` to `coordinator`, the counts and areas as `{{task_dir}}/rereview.md` gives them.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
