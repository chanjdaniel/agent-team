# SOP: merging on Daniel's word

Built by T186 (2026-11-02), to Daniel's standing order of 2026-11-01, and rebuilt by T276 (2026-11-12) on the approved plan.
`team-merge --help` is the exact reference for what each word holds the PR to, and `team-log --help` for each event's fields; this SOP says what the words are, how they are given and withdrawn, and what the coordinator does under each.

## The two words

A PR merges only through `team-merge T<n>` (`--pr <url>` for each PR of a task in two repos), and only on one of two words, each a ledger event of the task.

| Word | Its event | Its fields | What it covers |
| - | - | - | - |
| Per head | `merge-approved` | `url`, `discord_message`, `head` | One PR at the head the coordinator asked on, and through a merge of the base whose `rereview` passed, a clean one (`team-catch-up`), or the two in turn |
| Default | `plan-approved`, withdrawn by `plan-approval-withdrawn` | `by` (`Daniel` or `coordinator`), Daniel's `ask` and `discord_message`, and `plan` and `scope`, which `team-log` records itself; the withdrawal's `discord_message` | The task's PRs, any head whose review passed, while the approval stands, the plan's files are unchanged and the default is not withdrawn for the task, its project or every project |

The per-head word is Daniel's word on one head; the default word is the task's approved plan, which needs no word at merge time.
`merge_authority` in `bin/lib/ledger.jq` derives both from the ledger, once, for `team-merge` and for every reader that says what `team-merge` would do: `team-next`, `team-state`, `team-sweep` and `team-inbox`.

## The order `team-merge` tries them

1. The per-head word, when a `merge-approved` names the PR's URL.
2. The default word, when none does, or when the per-head word does not hold for a reason of its own.

The first word that holds is the one merged on, and the `merged` event's `approval` says which: `head` or `default`.
A per-head word that holds never reads the default word, and one on an old head falls to the default word instead of hiding it.
A word that does not hold falls to the next only for its own reasons, never for the checks every merge gets: a red check refuses the merge whatever the word.

## What each word holds the PR to

Every merge, on either word, needs the checks every merge gets: the PR open, not a draft, not conflicting and on the project's base; every required check present and passed on the head, none failing or pending; `agent-review` success on the head; no agent attribution line in its commits; and the project's local checks passing on the head through `team-checks`.

The per-head word needs Daniel's message read back from Discord, in the task's thread or `#coordinator`, from an author in `allowFrom`, sent no earlier than the head was first logged, and the PR's head the approval's head, or one that adds only merges of the base since it, either with a passing review logged after the word, or made by `team-catch-up` from a head whose latest review is a pass logged after the word (git showing it adds only clean merges of the base to that head), or each clean (a merge of the base whose tree is `git merge-tree`'s of its parents, as `team-catch-up` makes it) with no review logged after the word that found something.

The default word, the unattended one, needs:

- the task's plan approval standing: its latest `plan-approved` or `plan-approval-withdrawn` an approval (`plan_approval` in `bin/lib/ledger.jq`);
- the default not withdrawn for the task, its project or every project, and a giving back that decides it read back from Discord (see "Withdrawing and giving back the default word");
- the plan's files hashing as the approval recorded them (`plan_files` in `bin/lib/team.sh`), each one that differs, is new or is gone named: "the plan changed since its approval at <ts> (<files>): approve it again";
- for an approval of Daniel's, their message sent no earlier than the ask it answers, read back from Discord in the task's thread or `#coordinator`, from an author in `allowFrom`;
- the PR from the task's own branch for the project;
- the latest review of the head passed and logged `guarded` naming none of the six areas, where a head `team-catch-up` made (its `caught-up` event) and no review names stands on the review of the head it was made from, once git shows it adds only clean merges of the base to it;
- no review of the task counted a security or real-data finding, fixed or not, or left out its finding counts;
- GitHub's paged list of the PR's files read in full, every changed path within the approval's `scope` when it has one, and no changed path (or a rename's old path) on the short list for the PR's project.

A legacy approval, a `plan-approved` logged before T276 with no `plan`, has no hash to compare and no scope, and reads as the coordinator's whatever its `by` says.

For agent-team, the team's own project (`own_project` in `bin/lib/team.sh`: by name, by its path being the code checkout, or by its repo being the code checkout's origin), the default word has one reason, "the team's own project merges unattended only behind the reviewer App's check, which is not set up", and `team-merge` reads nothing more for it, so its PRs merge on the per-head word alone.

## The plan approval

- Daniel approves a plan through the plan ask, which lists `scope.txt` and says the approval is the merge word, and the coordinator logs their yes with `team-log T<n> plan-approved by=Daniel ask=<id> discord_message=<id>`.
- The coordinator approves a small plan itself with `team-log T<n> plan-approved by=coordinator`; on a product project that is the merge word, and on agent-team it starts the build alone.
- `team-log` records what was approved itself, never from the command line: `plan`, each of `tasks/T<n>/plan.md` in the team home, and `spec.md` and `scope.txt` in the task directory of the worktree of the task's first project, that exists, to its sha256; and `scope`, `scope.txt`'s non-blank lines, each a clean repository path, a directory ending in `/`.
- `team-log` refuses a `by` but the two, Daniel's approval with no `ask` or `discord_message`, an ask the task never logged or a message sent before it, the coordinator's with either, a closed task, no `plan.md`, and a second approval whose `by` and `plan` equal the one standing.
- Once any of the files changes after the approval, the default word lapses, and `team-merge` names each file, until the plan is approved again, which on a product project the coordinator may do itself once it has read the change.
  A worktree that is not on this machine reads as a changed plan, so the merge runs on the machine that holds it.
- Daniel withdraws a task's plan approval with a message, logged `team-log T<n> plan-approval-withdrawn discord_message=<id>`, which `team-log` refuses when no approval stands: it stops the task's build, every hand-off of `team-next` refused naming it, and the default word with it, until the plan is approved again.
  It is a separate act from withdrawing the default word, which stops merges alone.

## The short list

- `bin/lib/guarded` holds what still comes back to Daniel for the per-head word when a PR would merge on the default word; `team-merge` reads it from its own checkout, so a PR cannot loosen its own check.
- Its six areas, in its order: `ci`, `migrations`, `deploy`, `permissions`, `secrets` and `guardrails` (`guarded_areas` in `bin/lib/ledger.jq`).
- A line's area may be followed by `@<project>`, the registry name of the one project it applies to (Conventioner's auth code is `permissions@conventioner`), or `@own`, the team's own project (every agent-team line is `guardrails@own`); a line with no `@` applies to every project.
- Each pattern is matched case-insensitively against the whole path, and again with its camelCase humps split off, each rename's old path too.
- Test configs, `scripts/`, dependencies, the agents' instruction files and names that merely hold an auth word are left off on purpose; the reviewer still names an area by what the code does, in a file of any name, and a review naming one of the six holds the PR back.
- A review logged before T276 that names the retired areas `dependencies` or `settings` holds nothing back.
- A project whose auth code moves to a file of another name has it added to the list by an agent-team PR.

## Withdrawing and giving back the default word

- Daniel withdraws the default word in one message, in `#coordinator` or a task's thread, for one task, one project or every project, and gives it back the same way.
- The coordinator logs the withdrawal, a `merge-default-withdrawn`, with `team-log T<n> merge-default-withdrawn scope=<task|project|all> discord_message=<id> discord_channel=<id>`, and the giving back, a `merge-default-restored`, with `team-log T<n> merge-default-restored scope=<task|project|all> discord_message=<id> discord_channel=<id>`.
- `scope=task` covers the PRs of the task it is logged under; a registered project's name, every task's PRs in that project; `all`, every project.
- `T<n>` is the task in whose thread Daniel said it, or, said in `#coordinator`, the task it came up in or any open task; `discord_channel` is where the message is.
- For a PR, the latest of the two kinds whose scope covers it decides, over the whole ledger, and the default stands unless that is a withdrawal.
  So a giving back of `all` gives back every task and project withdrawn by name before it, and a withdrawal of `all` withdraws every project, whatever was given back before; to give back all but one project, give back `all`, then withdraw that one.
- A withdrawal holds whatever message it names, since it only stops merges: `team-merge` never reads it back.
- A giving back holds only when Discord shows its message from an author in `allowFrom`, in `#coordinator` or the thread of the task it was logged under; while the latest event that covers a PR is a giving back that does not read back, the default word does not hold for it.
- `team-log` refuses a scope that is neither `task`, `all` nor a registered project, `task` on a closed task, a message or channel that is no Discord id, a channel that is neither `#coordinator`'s nor the task's latest thread, and a giving back when no PR it covers has a withdrawal as its latest covering event; a second withdrawal is logged, since it is harmless.
- `team-project --check` refuses a project named `task`, `all` or `own`.
- Nothing checks what Daniel's message says, so the coordinator logs only a message that withdraws or gives back the default word, and asks in one line when it leaves the scope unclear.

## What never merges on any word

- A release to `main`: it stays Daniel's own, outside `team-merge`.
- A PR with a required check missing or not passed, any check failing or pending, or any other check every merge gets unmet.
- On the default word, a PR of agent-team, the team's own project, until the reviewer App is set up: it merges on the per-head word.
- On the default word, a PR that touches the short list for its project, or whose reviewer named one of its six areas (CI, migrations, the deploy, permissions, secrets, or the team's own guardrails), or whose task ever counted a security or real-data finding, or that changes a path outside the approval's scope: these come back to Daniel for the per-head word.
- On the default word, a PR whose plan changed since its approval, until it is approved again.

## What the coordinator does

- On a reviewer's pass, `team-next` prints "merge on the default word: run team-merge T<n> for ..." when the default word holds on the ledger for the reviewed head, else the merge ask's facts, naming each of the six areas the review found and each review of the task that counted a security or real-data finding or logged no counts, with ", so the default word does not hold" while the plan stands approved on a project not the team's own.
- With the review passed and every check green, it queues each plain `before` note as a follow-up, then:
  - when `team-next` says to merge on the default word, or `team-state T<n>` says `default word covers it`, runs `team-merge T<n>` with no ask and tells Daniel where each note went;
  - otherwise asks Daniel in the task's thread to merge, with the full PR URL and where each note went, and on their "merge it" logs `team-log T<n> merge-approved url=<PR url> discord_message=<id> head=<the full sha it asked on>` and runs `team-merge T<n>`.
- `team-state`'s line, shown while the task awaits merge with its plan approved, says `default word covers it`, `default word withdrawn` or `default word does not cover it: <the first reason>`; it adds GitHub's branch and files to the ledger's reasons, but reads neither the plan's files nor Daniel's message nor the checks, so it is the cue to try, never the merge's guarantee.
- `team-sweep`'s `merge-due` finding wakes the coordinator for a task awaiting merge with no ask open, no pause and no wait, no merge-base round in flight (a builder launch or `resumed` naming a merge-base brief, with no review since and a worker on it live), and a PR not merged whose default word holds on the ledger at the latest head the task logged; it reads no GitHub, so a short-list path no reviewer named, a changed plan or a message that does not read back is `team-merge`'s to find.
- On a merge on the default word, `team-merge` posts it in the task's thread and in `#coordinator`, with the approval it merged on, "on the plan you approved, <link>" or "on the plan the coordinator approved at <ts>", the merge commit and how to revert it; the coordinator posts with `team-post` the text of any post it says failed.
  A per-head merge posts nothing.
- On a refusal, `team-merge` names every reason it cannot merge, each once, and merges nothing.
  When the default word does not hold, it lists the per-head word's reasons when a `merge-approved` names the PR (or the task logged no plan approval either), then the default word's, then the checks every merge gets, and ends with the ask: "(Daniel's default word does not hold: ask them for the per-head word on the head <short head> with team-ask, naming <url>)"; the coordinator asks Daniel for the per-head word with `team-ask`, its text naming the PR's URL, or approves a changed plan again, as "The plan approval" says.
  On a word that holds, only the checks every merge gets are listed, with no ask line: the coordinator fixes what they name.
  A refusal for attribution lines is fixed first: `team-clean-messages <worktree>` strips them, its push, which the coordinator's settings deny it by hand, is the one line of a script it puts to Daniel with `team-ask --script` and runs on their yes with `team-run-approved`, and the new head is reviewed again.
  On a branch the gate's mirror holds, it prints a second step after the push, `team-clean-messages <worktree> --clear-gate-lane`, which runs with the same OK once the push has landed, since the gate's next run would otherwise refuse the old commits.
  That step and the mirrors under `~/.no-mistakes/repos` are the coordinator's: `settings/worker.json` denies every worker the flag and any Bash call naming that path, and `coordinator.settings.json` denies neither.
- After logging a merge word, a plan approval, or a withdrawal or giving back of either, it runs `team-inbox`, so the team home's `waiting.md` is current, and the list `team-inbox --post` posts with it: it shows each withdrawal of the default word that stands ("-# Default merge word withdrawn for <T<n>, project <name> or every project> since <link>") and leaves out of "PRs ready to merge" a PR the default word covers on the ledger, whose refusal comes back as an ask.
- `team-snapshot` gives at session start one line per withdrawal of the default word that stands: "Default merge word withdrawn for <T<n>, project <name> or every project> since <ts> (Discord message <id>, <task>)".
- No reader offers the default word for agent-team: `merge_authority` gives it the one reason above, so `team-next` prints the merge ask for its PRs, the sweep raises no `merge-due` for them, and `waiting.md` lists them.

## The retired words

- T276 retired the plan-time word (`merge-preapproved`, withdrawn by `merge-preapproval-withdrawn`, for a project that opted in with the registry's `merge_with_plan`) and the standing word (`merge-standing`, withdrawn by `merge-standing-withdrawn`, for one project or all), and the default word stands in their place.
- `team-log` refuses a new line of any of the four kinds, naming the default word and its withdrawal; the contract keeps them, so `--check` still passes the lines logged before.
- Those lines are history: `team-merge` reads none of them and no reader takes one for a merge word; a `merge-preapproved` still settles the ask of its id (`settles` in `bin/lib/ledger.jq`, read wherever an ask's state is), and `team-time` still reads the plan-time word's two kinds.
- `team-project --check` refuses `merge_with_plan` as retired, naming T276.
- A `merged` event's `approval` of `plan` or `standing` names one of them.
