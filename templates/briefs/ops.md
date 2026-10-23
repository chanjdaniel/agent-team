# {{task}} brief (ops): {{title}}

Path: {{path}}; you are the ops agent, on the one production request below.
Project: {{project}} (`{{repo}}`).
Worktree: `{{worktree}}`, branch `{{branch}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git), for an answer too long for one message.

## The request

Daniel asked, in {{request_link}}:

> {{request}}

Personal details asked for: {{personal}}.

## Read first

{{data_docs}}

## Report

Write the answer to `.scratch/answer.md`, then send `{{task}} DONE <answer>` to `coordinator`.
