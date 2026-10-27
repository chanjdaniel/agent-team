# SOP: rewriting the records repository's history

The cutover that takes the non-record bulk and the applicants' data out of the records repository's history (`chanjdaniel/agent-team-records`): T56's tier 2, which folds in T31 ticket 20's scrub.
T56's report (`tasks/T56/scratch/report.md` in the team home) is the why, the measurements and the alternatives; this is the how, in order.
Every step names its owner: **Daniel**, or the coordinator.
The force push and the Support request are Daniel's alone.

## What changes

- `dev` on GitHub gets a new history: every commit from `e9611631` (the PR #1 merge, 2026-10-21) on gets a new sha, since git filter-repo strips GitHub's merge signatures, and so do the imported lineage's `c7856695` and `70b4f532`.
- Dropped from every commit: the paths of `bin/lib/records-rewrite/drop.txt` (dependencies, bare repositories, a downloaded release, a built binary, copied project trees and build output; the plan-era review pages and screenshots).
  The S02 story keeps every version, with any address not at `example.com` replaced by `vendor@example.com`; one commit message's address becomes `[email removed]`.
- Every other file is byte-identical at every commit that had it, authors, committers, dates and parents are kept, and every message is the old one through the message expression and the commit map: `team-records-rewrite` checks all of it and refuses to go on otherwise.
- `lease`, every `wip/*` and `salvage/*` branch, and GitHub's read-only `refs/pull/*` keep their shas.
- The sha references in the records (about 4,200, most in T31's maps) are left as written; the commit map, committed beside them, translates each.
- A fresh clone of `dev` and `lease` goes from about 79 MiB to about 15 MiB (the 2026-10-27 rehearsal: 79.17 MiB to 14.79 MiB).

## Before the day

1. **Coordinator.** Check that what the cutover relies on has merged into the code checkout: T55's archive rule (`archive_left_out` in `bin/lib/team.sh` leaves out a bare repository and `node_modules`, so no checkpoint puts the bulk back) and the team home fetching only `dev` and `lease` (`team-doctor`'s `team home fetch` line passes on every machine; `~/agent-team/bin/team-bootstrap --stage machine` narrows a team home where it warns).
2. **Coordinator, the day before.** Rehearse on a fresh mirror: `~/agent-team/bin/team-records-rewrite ~/records-rewrite-rehearsal`.
   It must end with `verify: failures: 0`, `verify: drop-list paths left in the new history: 0`, `lease: unchanged`, and the `rehearsal:` line, since the team still holds the lease; `pack after:` should be within a few MiB of 14.7 MiB.
   A new kind of bulk added since shows in `pack after:`, and goes in `drop.txt` through a PR before the day.
3. **Coordinator, the day before.** Run T24's scans over the rehearsal's `~/records-rewrite-rehearsal/rewrite.git`, as T31's option A table did (T31 ticket 20's acceptance): `tasks/T24/keep/tools/scan.py` against the real exports T24 scanned, gitleaks 8.28.0 from its checksum-checked release with `--log-opts=--all`, and `ocr.py` only if Daniel asks for it.
   They must find no real export's address, no address in an image, and no gitleaks finding.
   Then remove `~/records-rewrite-rehearsal` by that literal path.
4. **Coordinator.** Tell Daniel the rehearsal's numbers and the day's steps below, and that the team pauses from step 5 to step 11, about an hour.

## The day

5. **Daniel says "hand off"; the coordinator runs it.** The coordinator's `handoff` skill stows every worker; `team-handoff` checkpoints, commits all records, pushes `dev`, disables the heartbeat and releases the lease; then `team-handoff --retire` stops the coordinator.
6. **Daniel.** Check the freeze: `~/agent-team/bin/team-lease status` says released, and `git -C ~/agent-team-records status --porcelain` prints nothing.
7. **Daniel.** `~/agent-team/bin/team-records-rewrite ~/records-rewrite`, under a minute.
   It mirrors GitHub into `~/records-rewrite/mirror.git` (its origin then removed, so no bare `git push` there can force every ref back), rewrites `dev` and `lease` in `~/records-rewrite/rewrite.git`, checks every commit, and prints the sizes and the commands of steps 8 and 9 with the old and new `dev` filled in; it pushes nothing.
   Go on only if it ends with the force push printed: any failed check stops it with exit 1 and no push command, and a `rehearsal:` line means the lease was not released.
8. **Daniel alone.** The force push it printed, from `rewrite.git` only, with its lease on the old `dev`: `git -C ~/records-rewrite/rewrite.git push --force-with-lease=refs/heads/dev:<old dev> https://github.com/chanjdaniel/agent-team-records.git refs/heads/dev:refs/heads/dev`.
   Never push from `~/agent-team-records` or `~/agent-team`, whose hooks and history are the old ones.
9. **Daniel.** `git ls-remote https://github.com/chanjdaniel/agent-team-records.git`: `dev` is the new sha, and `lease` and every other branch are as in `~/records-rewrite/refs-before.txt`.
10. **Daniel.** Re-clone the team home on this machine, keeping the old one aside, and carry over the files git ignores (local settings, task settings, UI captures):
    `mv ~/agent-team-records ~/agent-team-records.pre-rewrite`;
    `git clone --single-branch --branch dev https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records`;
    `git -C ~/agent-team-records remote set-branches --add origin lease`;
    `git -C ~/agent-team-records fetch origin`;
    `git -C ~/agent-team-records config core.hooksPath ~/agent-team/bin/hooks/records-git`, the records guard, which a clone never carries over and without which step 11's `team-resume` stops on the doctor's `records hooks` line;
    `git -C ~/agent-team-records.pre-rewrite ls-files -z --others --ignored --exclude-standard | rsync -a --from0 --files-from=- ~/agent-team-records.pre-rewrite/ ~/agent-team-records/`.
    Then `diff -rq --exclude=.git ~/agent-team-records.pre-rewrite ~/agent-team-records` lists only dropped paths (and empty folders, which git never holds).
11. **Daniel.** `~/agent-team/bin/team-resume` on this machine: it takes the lease, enables the heartbeat, re-homes every open worktree and starts the coordinator.
    The same machine resuming after its own handoff is what `tests/drill.bats` rehearses.
12. **Coordinator.** Record the rewrite in the team home, under the cutover task's `tasks/T<n>/`, as a records-only commit on `dev`: `filter-repo/commit-map` and `filter-repo/first-changed-commits` from `~/records-rewrite/rewrite.git`, and `summary.txt` and `verify.txt` from `~/records-rewrite`.
    Add a line to the records' `README.md`: the history was rewritten on that date (tier 2), every sha from `e9611631` on changed, the old and new `dev`, and where the map is.
    Log it: `team-log T<n> ticket-done ticket=<nn> commits='["<new dev>"]' repo=chanjdaniel/agent-team-records note="records history rewritten, dev <old dev> to <new dev>; commit map at tasks/T<n>/commit-map"`.
13. **Daniel, at the laptop, before it next takes the team.** The re-clone of step 10 there, its records guard included.
    Its `team-resume` refuses the old clone as diverged, which guards it, but a hand `git pull` would merge the old history back: never pull into an old clone, replace it.
14. **Daniel alone.** Ask GitHub Support to purge the old objects, as T31 ticket 20 planned and T24 did for Conventioner (`tasks/T24/keep/support-request.txt` is the precedent's wording): the repository `chanjdaniel/agent-team-records` (private), the number of affected pull requests (the rewrite's `verify: pull refs whose history holds a dropped path:` line; 15 in the rehearsal), the first changed commits (`first changed commits:`), and a request to dereference the PR refs and run garbage collection.
    The coordinator records the request's number, then Support's answer, in `manual-steps.md`.
    Once Support answers, an old sha such as `c7856695` answers 404 on GitHub.
15. **Daniel, a week later with nothing found missing.** Remove `~/agent-team-records.pre-rewrite` on each machine and `~/records-rewrite`.

## Rollback

Until step 15, from the mirror, which keeps every old object and has no remote, so every push from it names GitHub's URL and the one ref, as here: the rollback `team-records-rewrite` printed, `git -C ~/records-rewrite/mirror.git push --force-with-lease=refs/heads/dev:<new dev> https://github.com/chanjdaniel/agent-team-records.git <old dev>:refs/heads/dev`, then `mv` the old checkout back in place of the new clone on each machine that re-cloned.
