---
name: spec-review
description: Use to review a task's spec.md and tickets before the plan is approved - two fresh read-only readers read them as a stranger and as the builder, and their findings go to spec-review.md to sort. Not for code review or a diff.
argument-hint: "[<task dir>] [<code root>] [--model sonnet|opus]"
---

# Spec review

`/spec-review [<task dir>] [<code root>] [--model sonnet|opus]`

- `<task dir>`: the directory holding `spec.md` and `tickets/`; by default `.scratch/task`.
- `<code root>`: the code the spec changes; by default the session's working directory.
- `--model`: the alias passed as the Agent tool's `model` to both readers; without it, each runs on the `model` its own file names.

Turn both paths into absolute ones before step 1.

## 1. Check the inputs

When `<task dir>/spec.md` or `<task dir>/tickets/` does not exist, stop and say which is missing.

## 2. Dispatch both readers at once

Send both Agent calls in one message, so they run in parallel:

- `spec-review:spec-paraphrase`, its prompt only `Task directory: <task dir>`.
- `spec-review:spec-readiness`, its prompt only `Task directory: <task dir>` and, on the next line, `Code root: <code root>`.

Each prompt holds those absolute paths and nothing else: none of your reasoning, the plan, the brief or what you expect them to find, or they are no longer fresh.

## 3. Retry a failed reader once

A reader that errors, or returns none of its headed parts, is dispatched once more with the same prompt.
On a second failure, it is recorded `not run: <why>`, never as a clean review.

## 4. Write `spec-review.md`

Write `<task dir>/spec-review.md`, top to bottom:

```markdown
# <task> spec review

spec-paraphrase: ran on <model>
spec-readiness: ran on <model>

## Paraphrase

<the paraphrase reader's three parts, verbatim>

## Findings

| # | Reader | Severity | Kind | Where | Finding | Sort | Evidence |
| - | - | - | - | - | - | - | - |
| 1 | spec-readiness | blocking | open-decision | tickets/01-x.md:12 | <its text> | | |

escalated: none
```

- `<task>` is the task's id when you know it, else the task directory's name.
- A reader's line is `ran on <model>`, `ran on <model> on retry` or `not run: <why>`; `<model>` is the `--model` alias, else the session's model when the agent's `model` is `inherit`.
- Each item of the readiness reader's "Findings" is one row, its text verbatim.
- Each item of the paraphrase's "Could not follow" is one row too, reader `spec-paraphrase`, severity `note`, kind `could-not-follow`, so no passage a reader raised goes unsorted.
- Escape a `|` in a finding as `\|`.
- `Sort` and `Evidence` stay empty here, and the last line is `escalated: none` until step 8.

## 5. Stop here on a spec you did not write

When you did not write this spec (a replay of an archived one, say), stop here: sorting the findings is its author's work.

## 6. Compare the paraphrase with your plan

You wrote the spec, from a plan you were given.
Read the paraphrase's "What this changes" and "How the system works today, per this spec" against that plan.
Each place the reader misread your intent is a new row: reader `spec-paraphrase`, kind `misread`, severity `blocking`, where the line it misread, the finding what it took the line to mean.
A misreading is the spec's fault, never the reader's.

## 7. Sort every finding

Give each row one sort:

- `fix`: you change the spec or the ticket so the finding no longer holds, and the evidence is the line you changed.
- `contest`: the finding is wrong, and the evidence is a file and line under the code root, or a line of `spec.md`, that the reader could have read and that answers it.
- `escalate`: the answer rests on something no reader could read (the plan, Daniel's word, a conversation), so the coordinator decides; the evidence says what it rests on.

Rules for the sort:

- You may not contest with knowledge no reader could read: that is an `escalate`.
- Wanting to contest is not evidence: you wrote the spec, so your reading of it is the one that has not been checked.
- Never change a finding's severity or kind.
- Fix the spec for its builders; never add text only to satisfy a reader.
- One round only: the readers are not run again after your fixes.

## 8. Rewrite the table

Rewrite `## Findings` with each row's `Sort` and `Evidence` filled in, and the last line `escalated: none` or `escalated: <the escalated rows' numbers, comma-separated>`.
