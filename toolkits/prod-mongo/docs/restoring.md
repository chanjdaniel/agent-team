# Restoring a prod-mongo backup

For Daniel: where the toolkit's dumps are, how to prove one restores, and how to put one back on production yourself.
No agent restores to production: the toolkit has no tool that writes there, and the commands below are yours to run in your own terminal.

## Where the dumps are

Every dump the `backup` tool takes is a folder of its own under `~/conventioner-backups/`, named for the UTC time it started (`2026-11-08T142305Z`).
The folder and everything in it are yours alone: every directory is mode 0700 and every file 0600.

```text
~/conventioner-backups/<stamp>/
  manifest.json                  the backup's counts before, after and in the dump, its sizes and index names
  dump/conventioner/             mongodump's output: <collection>.bson.gz and <collection>.metadata.json.gz
  drills/<at>.json               each restore drill's verdict (PASS or FAIL) and its counts, named for its own start
```

A folder holds a `manifest.json` with `verified: true` only when the dump passed its backup's check, each collection's count in the dump matching the database's or the collection changing during the dump; a dump that failed it was removed by the backup that took it.
Anything else in `~/conventioner-backups/` (a dump you made by hand, a `.<stamp>.partial/` a killed backup left) is listed by `list-backups` by name and size, as "not taken by this toolkit" or "left unfinished".

The dump is not one moment in time: Atlas Flex refuses `mongodump --oplog`, so a collection written during the dump may hold writes from its middle.
The manifest says which: a collection whose counts before and after differ is `changed`.

## Proving a dump restores

The `restore-drill` tool, or the same script by hand, restores a dump into a throwaway local MongoDB and compares each collection's document count and index names (and each view's being there) with the manifest.
The throwaway is the pinned `mongo:8.0` image, its data on tmpfs (never a Docker volume or the disk), on a random loopback port only, behind a password the drill makes up and never puts in an argument list.
It is removed at the drill's end, on an error and on Ctrl-C; one whose drill was killed outright ends itself within the hour.
The verdict is recorded as `drills/<at>.json` in the dump's folder, and `list-backups` shows each dump's newest.

By hand, through the machine's heavy-run lock, with Docker running and the lock's Database Tools on your `PATH` (`team-doctor` names their install):

```bash
~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text
```

`--text` prints the tool's answer; without it the script prints one JSON object.
It exits 0 on `PASS` and 1 on `FAIL` or a refusal; stopped by Ctrl-C, it removes its throwaway and records no verdict.
It takes only the stamp, never a path or a connection string, and never reaches production.
A dump of more than 512 MiB on disk is refused, since the throwaway's 2 GiB memory could not hold it.

## Restoring to production

Restoring overwrites production with the dump: every write since the dump in the collections it restores is lost.
Run it only with the release or the fix it rolls back understood, and from a terminal of your own.

The command takes the connection string of a user that may write (the read user the toolkit uses cannot), which you type or paste at the `read -rs` prompt.
`printf` is bash's own, and `<(...)` is a pipe, so the string is never in a process's argument list, where `ps` could read it, and never in a file:

```bash
read -rs PROD_URI
mongorestore --config=<(printf 'uri: %s\n' "$PROD_URI") --nsInclude 'conventioner.*' --drop --gzip --dir ~/conventioner-backups/<stamp>/dump
unset PROD_URI
```

To restore one collection only, name it in `--nsInclude`: `--nsInclude 'conventioner.<collection>'`.
To see what it would do first, add `--dryRun`, which reads the dump and restores nothing.

What `--drop` does and does not do:

- It drops each collection the dump holds (that `--nsInclude` matches) before restoring it, so that collection ends exactly as it was dumped, its indexes included.
- It does not drop a collection the dump does not hold: one created since the dump stays as it is.
- Without `--drop`, `mongorestore` only inserts: a document whose `_id` is already there is not overwritten, so a changed document keeps its change.
- A dump restores only into the same major version (MongoDB 8.0, as the manifest's `server` says).

## Deleting a dump

The toolkit never deletes a dump; you do, by hand:

```bash
rm -r ~/conventioner-backups/<stamp>
```

Everything derived from the dump lives in its folder, so this deletes its drills too.

## Retention

The toolkit keeps the 5 newest verified dumps.
`backup` and `list-backups` end with how many dumps the folder holds and name each one past that rule (an unverified one included), for you to delete as above.
