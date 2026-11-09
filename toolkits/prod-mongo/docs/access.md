# What prod-mongo reaches

## It can

- Read every collection of Conventioner's production database, `conventioner` on the Atlas cluster `conventioner-prod` (project `conventioner-prod`, Flex, MongoDB 8.0), as the read user `prod-read` connects as, to dump it and check the dump:
  - `backup` reads the server's version, `dbStats`, the collection list and each collection's exact count (`countDocuments`) before and after the dump, and runs `mongodump` on the whole database.
- Write only under the backups folder, `~/conventioner-backups` on Daniel's machine: each dump's own folder (`<stamp>/`, with its `manifest.json`, its `dump/` and its `drills/`), every directory mode 0700 and every file 0600, and the folder's own mode set to 0700 when it is looser.
- Run Docker on Daniel's machine, for the restore drill only: one throwaway `mongo:8.0` container per drill, its data on tmpfs, published on a random loopback port only, behind a password of its own, removed when the drill ends and ending itself within the hour; and, at each drill's start, removing any container, network or image labelled `toolkit=prod-mongo` whose expiry has passed.
- Run `mongorestore` into that throwaway, through the machine's heavy-run lock (`bin/team-heavy`).

## It cannot

- Write to the production database: no tool writes there, and its Atlas user has the built-in `read` role on `conventioner` only, as `prod-read`'s does.
- Restore a dump to production: the drill restores only into its own throwaway, whose connection string it builds itself, and takes no connection string; restoring to production is Daniel's own command (`restoring.md`).
- Choose a folder: no tool takes a path, and `restore-drill` takes a dump by its stamp only, directly under the backups folder.
  The server refuses a backups folder inside a git checkout or worktree, the team home, `~/.claude`, `~/.no-mistakes`, a shared temporary directory, a synced folder or a CI workspace, or the home itself, before it touches it.
- Read a dump back through MCP: every answer is counts, sizes, names, verdicts and paths, never a document.
- Delete a dump: dumps past the retention rule (the 5 newest verified ones are kept) are named for Daniel to delete by hand; a backup removes only the unfinished folder it made itself when its dump fails the check.
- Read another database or cluster: the read user is restricted to the cluster `conventioner-prod`, and `read@conventioner` grants nothing else.
- Give the connection string to any child but `mongodump`, which reads it from a FIFO named in `--config`, so it is never in an environment, an argument list, a file at rest or a log; every child gets an environment built from a short list, never the server's own.

## The Atlas user

`conventioner-ops-read`, the same user as `prod-read`'s: password authentication, privileges `read@conventioner`, restricted to `conventioner-prod`, not temporary.
`read@conventioner` grants `mongodump` and the counts everything they need.

## The credential

The connection string lives only in 1Password, in the `agent-team` vault: item `conventioner-prod-read`, field `uri`, the same as `prod-read`'s.
The toolkit holds only its reference, `op://agent-team/conventioner-prod-read/uri`, which is not secret.
`scripts/start-server.mjs` reads it with `op read` when the session starts its MCP server, which raises a 1Password approval prompt on the PC (one per launch, even for a session that only drills or lists), then signs `op` out and serves from the same process, so the value exists only in that process's memory.
Rotating or revoking it is Daniel's, in `manual-steps.md` (T16, the standing ops rules), and rotating it changes `prod-read`'s too.
