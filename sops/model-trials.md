# SOP: trialling a cheaper model on one role, or a setup change

Written on 2026-10-27 by T52, for the first trial: Sonnet 5.5 for reviewers.
A later trial, of builders say, follows the same method with its own role.
A trial starts only on Daniel's word, and only Daniel's word keeps or ends its model.
It covers setup trials too, since T247: a toolkit, hook or instruction that claims to save tokens is trialled by the same measures, as "Trialling a setup change" below says.

## How a role gets a model

- A project's `models` table in the registry names a model alias or name per worker role: `models = { reviewer = "sonnet" }` under `[<project>]` in the team home's `projects.toml` (`team-project --help` documents the key).
  With no table, every role runs on the user settings' model (Opus 5.5 today).
- `team-worker` passes the role's model to `claude --bg` as `--model` and logs it as `model` on the launch event, so the ledger tells a trial's sessions from the baseline's.
  A launch with no `model` ran on the default.
- `team-worker --model <alias>` launches one session on another model than the registry's, for a paired review below; the launch logs that model too.
- An ops session never takes a model: its production work stays on the default.
  T0 and tasks opened before `team-open` have no project, so they take none from the registry.

## Before the trial

1. Daniel says yes to the trial, its project, its role and its model, and to the size (20 trial reviews unless they pick another number).
2. The effort is the baseline's.
   The baseline reviewers run on Opus 5.5 at `high`, from the machine settings' `modelSettings` entry for `claude-opus-5-5`.
   Sonnet 5.5's own default is `medium`, and the machine settings' top-level `effortLevel: "high"` sits in the user settings, where the settings reference says it applies to "Opus 5, Fable 5.1, and earlier models" while "Opus 5.5 and models released after it ignore it"; it does not say whether Sonnet 5.5 is one of those, so count on `medium`.
   So the trial needs a `modelSettings` entry of its own, `"claude-sonnet-5-5": {"effortLevel": "high"}`, in the team home's `machine/claude/settings.json`, which `team-config apply` puts on each machine; that change is Daniel's to approve too.
3. The coordinator commits the registry line on `dev`, a records-only commit, after `team-project --check` passes, and notes the trial's start time, `<start>`.

## While it runs

- Every reviewer launch of the project runs on the trial model; the first trial review's transcript shows the effort it ran at, one count per value, no content: `jq -r 'select(.type == "assistant") | .effort' <transcript> | sort | uniq -c` must say `high`.
  If it does not, stop the trial and fix the setting before counting any review.
- **The paired reviews.** For each of the first five trial reviews, an Opus reviewer reviews the same head too.
  Once the trial reviewer has reported and its session has ended (the two share the session name `T<n>-reviewer`), the coordinator launches `team-worker T<n> reviewer <worktree> --model opus -- <brief>`.
  Its brief names the trial review's head commit and not the PR, so it reviews `origin/<base>...<head>` whatever the builder has pushed since and, as a review with no PR, writes nothing to GitHub; and it names the file to write in place of `review.md`, which holds the trial review: `.scratch/task/paired-review-<k>.md`.
  The paired review never reaches the builder, `team-close` archives it into the team home with the task's scratch, and the coordinator logs no `review` event for it.
  The coordinator then compares the two finding lists item by item: each finding is in both, in the trial review only or in the paired one only, and each one found by only one is judged real or not, with why.
- When something real turns up that a passing trial review missed, the coordinator tells Daniel at once; Daniel may end the trial early.

## The measures

Each measure is taken per review, for the trial's reviews and for the baseline's.

| Measure | Where it comes from |
| - | - |
| Blocking findings and notes sent back | The ledger's `review` events: the share with `verdict` `findings`, and the notes sent back per review, the length of `sent_back` |
| Re-review rounds per PR | `team-time --json`'s `reviews` (reviews and findings per PR, a review's PR the latest `pr` event before it), and `team-tokens --json`'s `rereviews` |
| Issues found after a passing review that it should have caught | By the gate after the pass (a later `gate-run` on the PR with a `cause` of `review`, `notes` or `gate-finding`), by a later review of the same PR, or by Daniel; the coordinator judges each and lists it with where it was found |
| $w per review | `team-tokens --json --task T<n>` for each of the project's tasks in the window: `outcomes.reviewer_models`, the trial model's row against `default`, whose `reply_models` must show the model each ran on |

The paired reviews' own launches log `opus`, so their $w is a row of their own in `reviewer_models`: the cost of the check, never part of the baseline.

## The baseline

- The baseline is the same project's Opus reviews before `<start>`: reviewer launches with no `model`, from the weeks before the trial, back to the first with usage in the team home's `usage/` (`team-tokens`'s `sources`).
- Reviews are matched by PR size, the lines a PR changes (`gh pr view <n> --repo <repo> --json additions,deletions`, added and deleted together), in four buckets: under 100, 100 to 499, 500 to 1,999, and 2,000 or more.
  Each baseline measure is weighed to the trial's mix of buckets, so a trial of small PRs is never compared with a baseline of large ones.
- A bucket with no baseline review is left out of both sides, and the note says so.

## The end

- After the trial's 20th review (or Daniel's number), the coordinator writes a short note to Daniel and keeps it in the team home as `projects/<project>/model-trials/<YYYY-MM-DD>-<role>-<model>.md`, the date `<start>`'s.
- The note gives each measure for the trial and the baseline, each with the count of reviews behind it and the bucket mix; the five paired comparisons, finding by finding; the effort each side ran at; and the $w the trial model saved per review and over the trial.
- Daniel decides: the registry line stays, as the project's new default, or goes, by a records change to `projects.toml` either way.
  The machine settings' `modelSettings` entry for the trial model stays or goes with it.

## Trialling a setup change

A toolkit, hook or instruction that claims to save tokens is kept only on a measured trial and Daniel's word, as a model is.
T239 (`tasks/T239/scratch/report.md`) is why: each token-saving method it judged claimed a saving on its own benchmark or surface, yet in the post's test of whole task runs two of them spent more tokens than the baseline (Context Mode 68% more, Mandarin 46%).
So a change's own numbers never keep it: only the team's own tasks with and without it, measured as below, and Daniel's decision on them.

### Before the setup trial

1. Daniel says yes to the change, its project, the roles it is for and the size.
2. The coordinator lists a toolkit in the project's `toolkits` in the team home's `projects.toml`, a records-only commit after `team-project --check` passes, since those are the toolkits a worker of the project may be given (`team-project --help`).
3. The coordinator notes the trial's start time, `<start>`.

### The arm

- A change that can be a toolkit is one: the coordinator gives `--toolkit <name>` to the first builder of every other task of the project opened after `<start>`, in the order they open, and not to the tasks between them.
- `team-next` launches a task's later builders with the toolkits of its latest builder launch, and its reviewers with those of its latest reviewer launch, else of its latest builder launch, so a task stays in its first builder's arm.
  A launch by hand (the next phase's first ticket, a resume, a replacement) gives the same `--toolkit`s as the task's latest launch of that role, else of its latest builder launch, so no task mixes arms.
- The ledger's launch events log each launch's `toolkits`, which tells the arms apart, and the measures below split by them.
- A change that cannot be a toolkit (a role prompt's wording or a setting, say) is trialled by alternating weeks from `<start>`: on in the first week, off in the second, and so on, each week's launches its arm, measured with `--since` and `--until` set to the week; the closing note says which form the trial took.

### The size

Daniel's number: 40 tickets done per arm for a builder-side change, and 40 reviews per arm for a reviewer-side one, unless they pick another.
At about 40 tickets per arm the trial detects a difference in builder $w per ticket of about 25% or more, assuming a spread of about the mean, which T239 could not measure; the note reports the spread it finds.

### The setup trial's measures

Each measure is taken for the trial arm and for the baseline: the project's rows whose `toolkits` hold the trial's toolkit, and its rows whose `toolkits` do not.
A project's other toolkits make rows of their own (`["browser"]` and `["browser", "codegraph"]`, say), each counted in its arm by whether it holds the trial's toolkit.

| Measure | Where it comes from |
| - | - |
| Builder $w per ticket done | `team-tokens --json --since <start>`: `outcomes.builder_toolkits`, the project's rows by `project` and `toolkits`, their `tickets_done`, `w` and `w_per_ticket` (a ticket done counted for the builder launch that delivered it) |
| Reviewer $w per review | The same report's `outcomes.reviewer_toolkits`: `reviews`, `w` and `w_per_review` (a review counted for the reviewer launch that wrote it) |
| Findings share and notes sent back per review | The ledger's `review` events, as the model trial's measures are taken: the share with `verdict` `findings` (which `outcomes.reviewer_toolkits`'s `findings` over `reviews` gives per arm), and the notes sent back per review, the length of `sent_back`, over each arm's tasks |
| Re-review rounds per PR | `team-time --json --task T<n>`'s `reviews` and `team-tokens --json --task T<n>`'s `rereviews`, for each of the arm's tasks |
| Wall time per worker | `team-time --json --since <start>`: `workers.stats.by_role_project_toolkits`, the project's rows of the trial's roles, their `workers`, `mean`, `median`, `p90` and `longest`, in minutes |

Both reports also take `--until`, which closes the window at the trial's end.

### The setup trial's baseline

- The baseline is the same project's launches without the toolkit in the same window: the tasks between the trial's, so both arms see the same weeks of the project's work.
- Each task is weighed by its PR's size in the model trial's four buckets (see "The baseline" above), each measure taken per task with `--task T<n>` for the weighing, and the baseline weighed to the trial arm's mix of buckets; a bucket with no baseline task is left out of both sides, and the note says so.

### The stop rule

The coordinator tells Daniel at once when the trial arm's findings share or its re-review rounds per PR rise above the baseline's, and Daniel may end the trial there.

### The end of a setup trial

- Once each arm reaches the size, the coordinator writes a short note to Daniel and keeps it in the team home as `projects/<project>/setup-trials/<YYYY-MM-DD>-<role>-<toolkit>.md`, the date `<start>`'s.
- The note gives each measure for both arms, each with the counts of launches, tickets done or reviews behind it and the bucket mix, the spread of builder $w per ticket, and the $w the change saved or cost per ticket or review and over the trial.
- Daniel decides: the toolkit stays in the project's `toolkits` and the coordinator gives it to the project's builders and reviewers by default, or it leaves the registry, by a records change to `projects.toml` either way.

### The first setup trial: CodeGraph on Conventioner

- The arm is `--toolkit codegraph` on Conventioner's builders and reviewers, which the coordinator gives only once it lists `codegraph` in the project's `toolkits`.
  The toolkit (`toolkits/codegraph/README.md`) builds or syncs the worktree's own CodeGraph index at session start and prints a banner to locate code with `codegraph explore` first.
- Both arms already carry the user CLAUDE.md's CodeGraph instruction, to reach for CodeGraph where a `.codegraph/` directory exists, and on 2026-11-09 every Conventioner slot had one holding only its tracked `.gitignore`, with no index.
  So the trial tests a built index plus the banner against today's uninitialised slots, never CodeGraph against no mention of it.
- It is a builder-side and reviewer-side change, so it runs to 40 tickets done and 40 reviews per arm unless Daniel picks another size, and its notes are `projects/conventioner/setup-trials/<YYYY-MM-DD>-builder-codegraph.md` and `-reviewer-codegraph.md`.
- It needs Daniel's word on its start and its size, as every setup trial does.
