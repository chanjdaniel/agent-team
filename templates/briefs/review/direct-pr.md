- Write your findings to `{{task_dir}}/review.md`, numbered, each with its file and line and one kind: `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`.
  The comment on PR {{pr}} is that file, posted with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/review.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `{{head}}`, the head you reviewed, and refuses when the PR has moved past it: then set nothing and tell the coordinator.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.
