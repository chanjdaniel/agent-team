# SOP: a project's knowledge graph

Refined on 2026-10-22 by T4 (building Conventioner's graph) and T5 (moving Conventioner's planning out), from T1's draft of 2026-10-21.
Conventioner is the worked example throughout; the method is for any project.
The coordinator refines it again whenever a project's migration teaches something new.

## What it is for

A project's durable knowledge - what its words mean, what it promises, the rules it keeps, why its code is shaped as it is, how to run it - lives in the repo, as linked Markdown files that an agent, a human on GitHub, and Obsidian all read the same way.
Plans live with the team (`~/agent-team/projects/<project>/`).
Working notes live in a transient, ignored `.scratch/` and die with the task.

Three tests sort anything written down:

- **Durable**: still true, and still needed, after the work that produced it has merged.
- **Plan**: about work not yet done, or the order and scope of work.
- **Working note**: only useful while the task is in flight.

A decision is durable even when it was written inside a plan; move it before the plan leaves.

## The shape

### Nodes

A node is a Markdown file with this frontmatter:

```yaml
---
layer: business | implementation
kind: <one of the kinds below>
describes: [path/to/file, path/to/hub.py#symbol, path/to/owned-dir/]
verified: YYYY-MM-DD
sources: [<plan ids or paths, as strings>]
status: proposed | accepted | superseded by NNNN    # ADRs only
---
```

| Layer | Kind | Holds |
| --- | --- | --- |
| business | `concept` | a hub for one glossary term; the definition stays in the glossary |
| business | `flow` | what a person does and sees, step by step |
| business | `rule` | one product rule: what the product does or refuses, who may, why |
| business | `intent` | an enduring outcome the product commits to, at epic altitude |
| implementation | `module` | how one module works, and its sharp edges |
| implementation | `data` | one stored shape: keys, indexes, migrations |
| implementation | `convention` | a code rule no single module owns |
| implementation | `adr` | a decision that is hard to reverse, surprising, and a real trade-off |
| implementation | `runbook` | how to do an operational task |
| implementation | `testing` | how a part is tested, and test-only sharp edges |
| implementation | `record` | a dated report, frozen when written; never drift-checked |

Required keys: `layer`, `kind`, and `verified` (except on `record`).
`describes` is required on `module`, `data`, `convention`, `testing`; optional on `rule`, `flow`, `adr`; forbidden on `concept`, `intent`, `record`.
Add a kind only when a real node fits none of these; say why in the project's graph hub.

`verified` is the author's own calendar day, the day the node was read against the code.
Never backdate it to suit the time zone CI runs in; the checker allows for that (see "The checks").

### Rules for the content

- **A node holds current truth.** History is git's and the plan's.
- **One fact, one node.** Link instead of restating.
- **The glossary is the project's `CONTEXT.md`** (the `domain-modeling` skill's format), free of implementation; concept nodes link it and are linked from it.
- **ADRs live in `docs/adr/NNNN-slug.md`**, and only for decisions passing the three-part bar.
- **A reversed decision leaves one live node**, with a "Superseded" line naming what it replaced and its source.

### Links

- Plain relative Markdown links only: `[text](../rules/x.md#heading)`. No wikilinks.
- Kebab-case file names, no spaces.
- A node links every file in its `describes`.
- **The bridge is reciprocal**: a link from a business node to an implementation node is answered by a link back, and the reverse.
- **Every node is reachable** from the graph hub (`docs/README.md`), through one `README.md` per kind folder, or from the glossary.
- **Provenance is a string, never a link** (`sources`, or an id in a code comment), so plans can leave the repo without breaking anything.
  That holds outside the graph too: a record or a code comment that cites a plan spells its id or source string (`E01/F02/S03`, `wayfinding/<map>/<NN>`), never its path in the planning folder.
- **No tracked file links into the planning folder**, graph or not; the link breaks the moment the folder is untracked.
- **A path that code cites never moves.** Check with `git grep` before moving any doc.

### Layout

```
AGENTS.md            the always-loaded core, the graph contract, a one-line index to sharp-edge nodes
CONTEXT.md           the glossary
docs/README.md       the graph hub
docs/adr/            ADRs
docs/business/{concepts,flows,rules,intents}/
docs/implementation/{modules,data,conventions,testing}/
docs/records/        frozen reports
docs/*.md            existing runbooks, left where code and people already find them
docs/agents/issue-tracker.md   the tracker contract the skills read
```

### What `AGENTS.md` keeps

Only what nearly every session would get wrong without, before it knows which area it is in:
what the project is; the stack; the branch and release rules; irreversible-safety rules; how to run the suites; the graph's contract; one index line per sharp-edge area ("Before changing X, read [node]"); where plans live.
Everything else is a node.
Aim for under 200 lines.

## The checks

One script in the repo, standard library of a language CI already has, two CI jobs:

| Check | Rule |
| --- | --- |
| schema | frontmatter keys and values; `describes` entries exist; folder agrees with layer; `verified` is a real day, not in the future |
| links | every relative link resolves to a tracked file, every fragment to a heading or an explicit anchor |
| orphans | every node is linked from another tracked Markdown file |
| back-links | every cross-layer link is answered |
| drift (PRs only, its own job) | a node whose `describes` matches a changed file is itself in the diff |
| stale (report) | described files changed many times since `verified` |
| ids (report) | plan ids cited in code that no node's `sources` names |

The checks are **opt-in per node by frontmatter**, so the graph is green at every step of a migration.
External URLs are not checked in CI.

- **A `verified` day is in the future only once no time zone has reached it.**
  Compare against today in UTC+14, never the runner's today.
  CI runs in UTC, so an author east of UTC who verifies a node in their morning would otherwise fail `check` until UTC caught up.
  Conventioner first backdated 125 nodes to please CI, then reverted that and fixed the checker.
- **A missing described symbol counts as a drift hit.**
  A `file#symbol` absent at the PR's head is treated as changed, so removing a described symbol warns; `check` already proves every described symbol exists at the head, so in CI the hit is real.
- **The checker's tests and `check` are one job, and required.**
  **Drift is a second job, not required at first**: it needs the full history, and it shows red without blocking for a set number of PRs (Conventioner: 10), after which it is re-judged against the replay.
- **Drift's cost falls on large feature PRs.**
  Replayed over Conventioner's last 40 merges with all 137 nodes, 23 PRs warned, and eleven of them would each have had 19 or more nodes to re-read and bump (the largest, 58).
  Weigh that per-PR work, not only the share of PRs warned, before making drift required.
- **The local gate installs into a virtual environment of its own.**
  A uv- or distro-managed Python refuses `pip install` (PEP 668), so a gate script that installs the checker's test dependencies fails on such a machine.
  Make a venv from the chosen Python, install there, and delete it on exit, so a run leaves nothing installed behind.

Keeping drift quiet:

- Describe hub files by `#symbol`, never whole.
- A directory prefix only for a node that owns the directory.
- The escape is the act the check wants: touch the node, at least by bumping `verified` after reading it against the change.
- Before turning drift on, replay it over the last 40 merges and tune `describes` until the warnings are ones a reviewer would want.
  A replay of old merges against today's nodes must leave out symbols present at neither side of a merge; otherwise every symbol written later counts as a hit (Conventioner: 520 node warnings as the checker reports them, 362 honest ones).

## Obsidian

- Open the repo root as the vault; commit nothing but `.obsidian/` in `.gitignore`.
- Settings: Markdown links on (Wikilinks off), new links as relative paths; exclude the code folders and generated files; graph view "Existing files only", colour groups by `path:docs/business` and `path:docs/implementation`.
- Obsidian recognises only Markdown, canvas, bases, images, audio, video and PDF, so links to code show as unresolved and are hidden by "Existing files only".
- Write the settings in the graph hub, since they are not committed.
- Exclude `.scratch/` too: once plans have left, it still exists locally and may hold real data.

## Working with the graph

- **Builder**: a PR that changes behaviour updates the node that states it, in the same PR; a new durable fact gets a node, linked from its hub and across the bridge.
  Before changing a file, find its nodes with `git grep -l '<path>' docs`.
- **Reviewer**: drift warnings answered by a real edit or a deliberate `verified` bump; new nodes reachable; nothing durable left only in a PR description or a plan.
- **Planner**: reads the graph before planning; tickets name nodes, not files, for rules; decisions reached while planning are written to nodes when the work merges, not left in the ticket.
- **Coordinator**: moves a work item's status in the team home when its PR merges, at the task's close; task tickets are not work items and are never copied there.
- **Task docs** (`/to-spec`, `/to-tickets`, `/code-review`) live in `.scratch/` for the life of the task.

## Bringing an existing project onto a graph

1. **Inventory** every tracked doc and every planning file; measure links, anchors, orphans and references into planning folders from code.
   Run the `ids` report now: it is the baseline the close-out is measured against.
2. **Classify** each as durable (name its node), plan, or working note; group by pattern, name every exception; list where each kind of decision lands.
3. **Build** the checker first, green on an empty graph; then the hub and Obsidian check; then existing docs; then the always-loaded file split into nodes; then decisions from planning; then flows and intents; then shrink `AGENTS.md`.
   Nothing is deleted from the planning folders in this stage.
   - **Keep a ledger with one row per tracked planning file**: its verdict (plan, plan plus residue, working note) and the nodes whose `sources` cite it.
     Check it by script against `git ls-files`: no path twice, none missing, every residue row names a node, every named node exists.
     The check finds what reading misses (Conventioner: 20 holders lacking the exact story id in `sources`, and one decision no node held).
   - **Close out with the `ids` report again**, beside the baseline: every uncovered id is either added to the `sources` of the node that holds its decision or listed with why it stays uncovered (Conventioner: 294 uncovered ids before, 39 after, each of the top 20 handled by name).
   - Replay drift (see "Keeping drift quiet") and record the per-PR cost for the decision on making it required.
4. **Move plans out** with history, through two PRs: the team home's import, then the project's removal.
   - **Merge the additive repo first.**
     The team-home PR only adds; until the project's PR merges, the project still holds its own copy, so a failed review loses nothing.
     While the move is open, no other task edits the planning folder; a status change they need is made in the team home at their close.
   - **Take the source sha late**, the project's latest default-branch commit when both PRs are near review.
   - **The planning folder by `git subtree split`**: `git subtree split --prefix=<dir> <source-sha>`, then in a team-home worktree `git subtree add --prefix=projects/<project> <split-sha>`.
     Run the split in a throwaway `--no-local` clone, so no branch is left in the project's repo; the split is deterministic, so the sha is the same, and a later split is a superset of an earlier one.
   - **Files outside the folder by `git filter-repo`** (`uvx git-filter-repo` when it is not installed): in a throwaway clone, keep only the paths that move, `--path-rename` them into place, and `git subtree add` the result.
     `git subtree split` takes a whole prefix, so it cannot leave behind a file in the same folder that stays.
   - **Images travel with the pages that use them.**
     List every relative `src` and `href` of each moved page and move those files too; a page without its images renders empty (Conventioner: four review pages carried 121 screenshots the plan had not named).
   - **Keep the folder's inner layout** in the team home, so relative links between plan files keep resolving; check the new paths with `git check-ignore` there.
   - **Prove the import in three parts**, on the team-home commit right after the subtree adds:
     trees (each imported folder has the same git tree hash as at the source sha);
     blobs (each file filter-repo moved is the same blob);
     history (every file's `git log --follow --format='%ad %s'` is the same in both repos, the team home's own commits left out).
     Add spot checks to the PR description: `--follow` on a few files, `git blame` on one.
     Prior art: `tasks/T5/scratch/tools/verify_import.sh`.
   - **A README in the team-home folder** records the source sha and the split heads (split commits keep author, date and subject but not the sha, so a reader matches a commit by date and subject), how each id form resolves there, and the project's removal PR.
   - **Fix links after the import, each fix its own commit**, so history shows them as team-home changes.
     List every link that is broken or leaves the planning tree (prior art: `tasks/T5/scratch/tools/plan_links.py`).
     **Outbound links become permalinks** at the source sha (`https://github.com/<owner>/<repo>/blob/<source-sha>/<path>`): a relative link out of a plan file breaks on the move, and a permalink keeps pointing at the text it meant, even after that file is deleted.
     Name each target's path at the source sha; an earlier migration may already have moved it.
   - **A doc being deleted that lists open work** becomes `proposed` items in the team-home backlog, each re-read against today's code first; an item since fixed is recorded as fixed, by which epic, and not carried.
   - **Untrack and ignore**: `git rm -r --cached <dir>`, and one ignore line for the whole folder, which also covers any local data subfolder; `git rm` the files filter-repo moved.
     A file that stays and linked a moved one names it as plain text: a public repo cannot usefully link a private team home.
     Run the link check right after the untrack, before committing: a durable doc that linked into the folder is found broken only then.
   - **Rewrite the tracker contract** the skills read (`docs/agents/issue-tracker.md`): the backlog and maps in the team home, `.scratch/` transient and task-local, where each skill writes, and how every provenance form resolves.
     Give team-home paths in backticks, not as links, when the team home is private.
   - **Fix every other reference**: records and code comments spell the id, not the plan's path; a comment that pointed at a plan file for a decision names the node holding it, and that node is read against the change and gets its `verified` bumped.
   - **Write the grep acceptance with its exceptions named.**
     A literal "`git grep '.scratch'` finds nothing" cannot hold: the ignore line, the tracker contract, the rules about a local data folder (Conventioner's `.scratch/examples/`, real applicants' data), the Obsidian exclusion, and the checker's own rule that a node never links into the folder must all stay.
     Grep for the moved subfolders (nothing), and compare the rest against the named list.
   - **Gate the removal on "no planning change since the import"**: `git log --oneline <source-sha>..origin/<default> -- <dir> <moved files>` is empty.
     If it is not, top up: split again from the new head, `git subtree merge --prefix=projects/<project>` brings only the new commits, update the README's source sha, and rebase the removal branch so its untrack covers the new files.
   - **Prove the skills** in a fresh, detached worktree at the removal branch's head, after the team-home PR has merged: `/to-spec` and `/to-tickets` write into `.scratch/` and `git status --porcelain` stays empty; `/code-review` on a commit citing a work-item id reads that item at its team-home path.
5. **Refine this SOP** with what the migration taught.

## Pitfalls seen so far

- Moving a doc that code or a test cites by path (Conventioner: `docs/RELEASING.md` is asserted in a test).
- A doc with no inbound link is invisible: Conventioner's glossary and only ADR were both orphans.
- Docs nobody had to touch rot silently: Conventioner's object-relationship doc described a data model removed a month earlier.
- Treating a monolithic always-loaded file as one node hides drift: the same history warns on 7 of 40 PRs as one node and on 24 of 40 when split by section.
- Backdating `verified` to suit CI's time zone: it makes every node lie about when it was read; fix the checker instead.
- Judging drift by the share of PRs it warns: the cost is the nodes per warned PR, and it grows with the graph.
- A gate script that installs into the system Python passes on CI and fails on a managed Python at the first `pip install`.
- A ledger checked only by reading: Conventioner's script check found 20 holders missing the exact id in `sources`, and one decision no node held.
- Moving pages without their images: they render empty in the team home.
- Splitting in the project's own repo leaves a throwaway branch there, and an agent may not be allowed to delete branches.
- A durable doc that linked into the planning folder: the link only breaks when the folder is untracked (Conventioner: a known-gaps doc linked an epic).
- Outbound links from plan files were already broken before the move, because the graph migration had moved their targets (Conventioner: five of six); a permalink at the source sha names the current path.
- An acceptance written as "grep finds nothing": the local data folder, the tracker contract and the checker's own rule still name the folder, and must.
- Removing the planning before the team home's import has merged, or without checking the default branch for planning changes since the source sha: either leaves plan changes with no live home.
