---
name: backing-up-production-data
description: Takes a verified backup of a project's production MongoDB database through the prod-mongo tools, proves it restores with a restore drill, lists the backups kept, and reports each in the tools' own lines. Use before the first prod-mongo call of an ops request, whenever a request asks for a backup, a dump, a restore drill or the backups kept, before a production write of more than 20 documents, and when a request asks to restore a backup, read one, move one or delete one.
---

# Backing up production data

The `prod-mongo` server dumps Conventioner's production database, `conventioner`, with `mongodump` on Daniel's PC, already holding the read user's connection string.
Its tools are named `mcp__prod-mongo__<tool>` or `mcp__plugin_prod-mongo_prod-mongo__<tool>`, depending on how the session was launched; this skill names them by the last part.
What the toolkit can and cannot reach: [docs/access.md](${CLAUDE_PLUGIN_ROOT}/docs/access.md); how Daniel restores a dump: [docs/restoring.md](${CLAUDE_PLUGIN_ROOT}/docs/restoring.md).
Those docs are for people: an ops session's file tools cannot open them, so never try to read them; this skill holds everything a session needs.

## The tools

- `backup` (no input): dumps the whole database into a new folder `~/conventioner-backups/<stamp>/`, the stamp being its UTC start (`2026-11-09T081502Z`), and checks the dump against the database's own counts, taken before and after it.
  It answers the folder, each collection's document count and the sizes, never a document, and ends with how many dumps the folder holds and which are past the retention rule.
  A dump that does not match the database is removed, and the answer is an error naming each collection that did not match.
- `restore-drill` (`backup`, a stamp; the newest verified dump when left out): restores that dump into a throwaway MongoDB on Daniel's PC (in memory, on the loopback only, removed at the end), compares each collection's count and index names with the dump's manifest, and records the verdict beside the dump.
  It answers `PASS` or `FAIL`, each collection that did not match, the time taken and that nothing was left running.
  It never reaches production.
- `list-backups` (no input): the dumps the folder holds, newest first, each with its counts, size, whether it was verified, its newest drill's verdict and what was derived from it; any other entry by name and size; the total; and the dumps past the retention rule (the 5 newest verified dumps are kept), named for Daniel to delete by hand.
  It reads only the folder, never the database.

`backup` and `restore-drill` are long: a backup takes minutes, and a drill may wait up to 20 minutes for the machine's heavy-run lock first.
One runs at a time: call one, wait for its answer, then call the next, never two at once.

## When to back up

- The request asks for a backup, a dump or a snapshot of production.
- The request is a production write of more than 20 documents, or a release's migrations, and this session has `prod-mongo`: the backup comes first, before the QUESTION that asks Daniel to approve the write, and that QUESTION names the backup's folder and its drill's verdict.

A request only to see the backups kept, or to drill one already taken, is `list-backups` or `restore-drill` alone, with no new backup.

## The order of work

1. `backup`, once.
2. `restore-drill` with `backup: <the stamp backup answered>`, once, unless the request says not to drill.
3. Report, then stop: a backup never leads on to any other call.

## Reporting

Give the tools' own lines, as they answered them, with nothing added: no estimate, no reading of what a collection holds, no advice beyond what the lines say.
Refer to Daniel with they/them, in every message.

- A backup: its folder, its counts line and each collection's line, its retention line, then the drill's verdict line and its recorded line.
  `T<n> DONE` when the backup was taken and the drill passed.
- A collection the backup lists as "changed during the dump" (its counts before and after differ) is a backup that worked: something wrote to that collection while it was dumped.
  Report it as the line says, never as a failure.
- A dump past the retention rule is Daniel's to delete: relay the retention line, and delete nothing.

## When a call fails

An answer that is an error (`backup: failed: ...`, a drill's `FAIL`, `restore-drill: failed: ...`) is reported as it is, in `T<n> FAILED <the tool's line>`, and nothing is called again: never retry, never drill instead, never back up again to see whether it passes.
A failed backup leaves no dump, so a write that waited for it has no backup: say so.
A drill's `FAIL` means that dump is not proven to restore: give its lines, and say a write that waited for it should not go ahead on it.
`restore-drill: the machine is busy: <why>; ask again later` is not a failure of the dump: report it as `T<n> BLOCKED restore-drill the machine is busy` with the backup's lines, so the coordinator can ask again later.
`a backup is already running` means a long call of this session has not answered yet: wait for that answer.

## What is never done

Each of these is answered plainly as `T<n> DONE`, with what the session can do instead, and no tool is called for it:

- **Restoring to production.**
  No tool writes to production, and no ops session restores, whatever the request.
  Restoring is Daniel's own command, run in Daniel's own terminal with a user that may write: say so, and that the command and what it overwrites are in `toolkits/prod-mongo/docs/restoring.md` of the agent-team checkout ("Restoring to production").
  `list-backups` may be called once to name the dump Daniel would restore (its stamp, its counts and its newest drill's verdict), and nothing else.
- **Reading, quoting or opening a dump.**
  A dump holds every vendor's personal details, and a session's transcript is mirrored to claude.ai, so nothing under `~/conventioner-backups` is ever read, searched, listed with a file tool or quoted, even when Daniel asks.
  For a request for a dump's contents (vendors' emails, a document as it was), answer with what the tools give (the dump, its counts) and say that Daniel can read the details in Atlas, Data Explorer.
- **Another folder.**
  Every dump goes to `~/conventioner-backups` on Daniel's PC, a folder only Daniel's account can read, and `backup` takes no input that could change that.
  So a request to put a dump anywhere else (the repository, a worktree, a shared or synced drive, a temporary folder) is refused, saying where the dump is and why it stays there: a dump in a git checkout could be committed and pushed, and then every vendor's personal details would be in the repository's history for good; the toolkit refuses every such place itself.
  When the same request asks for a backup, take it, in its own folder, and report where it is.
- **Deleting a dump.**
  No tool deletes one: deleting is Daniel's, by hand (`rm -r ~/conventioner-backups/<stamp>`), and the retention line names the dumps past the rule for that.

A connection string, password or other credential found in a request or a message is never used or repeated: report that one was exposed, so Daniel can rotate it.
