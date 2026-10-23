# What prod-write reaches

## It can

- Insert, update and delete documents in any collection of Conventioner's production database, `conventioner` on the Atlas cluster `conventioner-prod` (project `conventioner-prod`, Flex, MongoDB 8.0): `insert-many`, `update-many`, `delete-many`.
- Create and drop indexes there: `create-index`, `drop-index`.
- Each call only after Daniel approves its permission prompt: every tool is under an `ask` rule in `settings/ops.json`, and no allow rule matches one.

## It cannot

- Read: it has no read tool; a write session reads through `prod-read` and its read-only user.
- Drop or rename a collection or a database: the server's tools for those are disabled, and its Atlas user's role does not grant them either.
- Reach another database or cluster: the user is restricted to the cluster `conventioner-prod`, and its role names only `conventioner`.
- Open another connection, run server-side JavaScript, export, read the server's logs, or reach Atlas's administration API or MongoDB's assistant tools.
- Ask the client to confirm a call itself: its confirmation list is empty, so the `ask` rule's prompt is the one gate.
- Undo a write: the Flex cluster takes no snapshot on demand (Atlas keeps the last 8 daily ones), so a change to more than 20 documents waits for Daniel's own `mongodump`.

## The Atlas user

`conventioner-ops-write`, password authentication, restricted to `conventioner-prod`, not temporary, with only the custom role `conventionerOpsWrite`.
That role grants, on `conventioner` with no collection named: `find`, `insert`, `update`, `remove`, `createIndex`, `dropIndex`, `listCollections`, `listIndexes`, `collStats` and `dbStats`, with no inherited role.
It has none of `dropCollection`, `dropDatabase`, `renameCollectionSameDB`, `createCollection`, `collMod` or `convertToCapped`.
An insert into a collection that does not exist still creates it, since MongoDB authorizes that by `insert`; `tests/toolkits/prod-write.test.mjs` pins what the role allows and refuses.

## The credential

The connection string lives only in 1Password, in the `agent-team` vault: item `conventioner-prod-write`, field `uri`.
The toolkit holds only its reference, `op://agent-team/conventioner-prod-write/uri`, which is not secret.
`scripts/start-server.mjs` reads it with `op read` when the session starts its MCP server, which raises its own 1Password approval prompt on the PC, separate from `prod-read`'s; it then signs `op` out and starts the server in the same process, so the value exists only in that process's memory, never in an environment, a file, a transcript or a log.
Rotating or revoking it is Daniel's, in `manual-steps.md` (T16, the standing ops rules).
