# SOP: merging on Daniel's word

Built by T186 (2026-11-02), to Daniel's standing order of 2026-11-01.
`team-merge --help` is the exact reference for what each word holds the PR to, and `team-log --help` for each event's fields; this SOP says what the words are, how they are given and withdrawn, and what the coordinator does under each.

## The three words

A PR merges only through `team-merge T<n>` (`--pr <url>` for each PR of a task in two repos), and only on one of Daniel's three words, each a ledger event that names Daniel's Discord message.

| Word | Its event | Its fields | What it covers |
| - | - | - | - |
| Per head | `merge-approved` | `url`, `discord_message`, `head` | One PR at the head the coordinator asked on, and through a merge of the base whose `rereview` passed |
| Plan time | `merge-preapproved`, withdrawn by `merge-preapproval-withdrawn` | `project`, `ask`, `discord_message`, `scope`; the withdrawal `project`, `discord_message` | The task's PR in that project, any head, within the plan's scope list, for a project that opts in (`merge_with_plan`) and is not agent-team |
| Standing | `merge-standing`, withdrawn by `merge-standing-withdrawn` | `project` (a registered project, or `all`), `discord_message`, `discord_channel`, the same for both | Any task's ready PR in that project, or in every project for `all`, agent-team included, any head, with no scope list and no opt-in |

The per-head and plan-time words are the task's own.
The standing word is team-wide: it is read across the whole ledger, and the task it is logged under only names the thread its message may be in.
For a project, the latest `merge-standing` or `merge-standing-withdrawn` whose `project` is that project or `all` decides, and the word stands when that event is a `merge-standing`.
So a word on `all` withdrawn for one project still stands for the others, a withdrawal of `all` ends every word, and a word given after a withdrawal stands again.

## The order `team-merge` tries them

1. The per-head word, when a `merge-approved` names the PR's URL.
2. The plan-time word, when none does and the task's latest `merge-preapproved` of the PR's project stands.
3. The standing word, when the ledger holds any `merge-standing`, and either neither word above is in play or the one tried does not hold for a reason of its own.

The first word that holds is the one merged on, and the `merged` event's `approval` says which: `head`, `plan` or `standing`.
A per-head or plan-time word that holds never reads the standing word.
With no `merge-standing` anywhere in the ledger, `team-merge` never reads it, and runs as it did before the standing word.
A word that does not hold falls back to the standing word only for its own reasons, never for the checks every merge gets: a red check refuses the merge whatever the word.

## What each word holds the PR to

Every merge, on any word, needs the checks every merge gets: the PR open, not a draft, not conflicting and on the project's base; every required check present and passed on the head, none failing or pending; `agent-review` success on the head; no agent attribution line in its commits; and the project's local checks passing on the head through `team-checks`.

The per-head word needs Daniel's message read back from Discord, in the task's thread or `#coordinator`, from an author in `allowFrom`, sent no earlier than the head was first logged, and the PR's head the approval's head, or one that adds only merges of the base since it with a passing review logged after the word.

The plan-time and standing words are the unattended words, and share one bar, so the two cannot drift:

- Daniel's message read back from Discord, from an author in `allowFrom`;
- the PR from the task's own branch for the project;
- the latest review of the head passed and logged `guarded` as an empty list;
- no review of the task counted a security or real-data finding, fixed or not, or left out its finding counts;
- GitHub's paged list of the PR's files read in full, no path holding a line break, and no changed path (or a rename's old path) matching a guarded pattern of `bin/lib/guarded`.

The plan-time word also needs its message sent no earlier than the ask it answers, the project to opt in and not be agent-team, and every changed path within its scope list.
The standing word also needs its `discord_channel` to be `#coordinator`'s channel or the thread of the task it was logged under, and reads Daniel's message there alone, whenever it was sent: it is on no head and answers no ask.

## What never merges on any word

- A release to `main`: it stays Daniel's own, outside `team-merge`.
- A PR with a required check missing or not passed, any check failing or pending, or any other check every merge gets unmet.
- On the unattended words, a PR that touches a guarded area (CI, dependencies, migrations, settings, permissions, secrets, or the team's own guardrails), by its paths or by its reviewer's `guarded` list, or whose task ever counted a security or real-data finding; these come back to Daniel for the per-head word.

## What the coordinator does

- With the review passed and every check green, it queues each plain `before` note as a follow-up, then:
  - when `team-state T<n>` says `merge pre-approved` or `standing word covers it`, runs `team-merge T<n>` with no ask and tells Daniel where each note went;
  - otherwise asks Daniel in the task's thread to merge, with the full PR URL and where each note went, and on their "merge it" logs `team-log T<n> merge-approved url=<PR url> discord_message=<id> head=<the full sha it asked on>` and runs `team-merge T<n>`.
- `team-state`'s `standing word covers it` reads neither Daniel's message nor the checks; `team-merge` reads both, so it is the cue to try, never the merge's guarantee.
- `team-sweep`'s `merge-due` finding wakes the coordinator for a task awaiting merge with no ask open, no pause and no wait, while a plan-time or standing word stands for one of the task's projects.
- On a merge on the plan-time or standing word, `team-merge` posts it in the task's thread and in `#coordinator`, with which word, the merge commit, the link to Daniel's message and how to revert it; the coordinator posts with `team-post` the text of any post it says failed.
  A per-head merge posts nothing.
- On a refusal, `team-merge` names every reason it cannot merge, each once, with each word's it tried when the last one does not hold, and merges nothing.
  Under the plan-time or standing word its last line is the ask: "(Daniel's standing word does not hold: ask them for the per-head word on the head <short head> with team-ask, naming <url>)", or the same with "plan-time"; the coordinator asks Daniel for the per-head word with `team-ask`, its text naming the PR's URL.
  A refusal for attribution lines is fixed first: `team-clean-messages <worktree>` strips them, its push runs only with Daniel's OK, and the new head is reviewed again.
- After logging any of the merge words or their withdrawals, it runs `team-inbox`, so the Waiting on you message is current: it shows each standing word ("Standing merge word on <projects> since <link>") and leaves out of "PRs ready to merge" a PR a plan-time or standing word stands for, whose refusal comes back as an ask.
- `team-snapshot` says at session start which projects a standing word stands for, and since which message.

## Giving and withdrawing the standing word

- Daniel gives it in one message, in `#coordinator` or a task's thread, such as "merge when ready", for one project or for every project, and withdraws it the same way.
- The coordinator logs the word with `team-log T<n> merge-standing project=<project or all> discord_message=<id> discord_channel=<id>`, and the withdrawal with `team-log T<n> merge-standing-withdrawn project=<project or all> discord_message=<id> discord_channel=<id>`.
- `T<n>` is the task in whose thread Daniel said it, or, said in `#coordinator`, the task it came up in or any open task; `discord_channel` is where the message is.
- `team-log` refuses a project the registry does not name (`all` aside), a `discord_message` that is no Discord id, a `discord_channel` that is neither `#coordinator`'s channel nor the task's thread, and a withdrawal when no standing word stands for its project.
- Nothing checks what Daniel's message says, only that it is theirs and where it was logged, so the coordinator logs only a message that gives or withdraws the word, and asks in one line when the message leaves the project unclear.
- The word stands until Daniel withdraws it; it needs no renewal, and survives any number of heads, fix rounds and tasks.
