# What prod-read reaches

## It can

- Read every collection of Conventioner's production database, `conventioner` on the Atlas cluster `conventioner-prod` (project `conventioner-prod`, Flex, MongoDB 8.0): `find`, `count`, `aggregate`, `aggregate-db`, and the metadata tools (`list-databases`, `list-collections`, `collection-schema`, `collection-indexes`, `collection-storage-size`, `db-stats`, `explain`).
- Compute summaries in the database with aggregation pipelines, which keeps raw documents in Atlas.

## It cannot

- Write anything: the server runs read-only (no write tool is registered, and `$out` and `$merge` are refused), and its Atlas user has the built-in `read` role on `conventioner` only.
- Read another database or cluster: the user is restricted to the cluster `conventioner-prod`, and `read@conventioner` grants nothing else.
- Open another connection: `connect` and `list-connections` are disabled, so every tool works on the one connection the launcher opened (`connectionId: "preconfigured"`).
- Run server-side JavaScript (`$where`, `$function`, `$accumulator`), export results to files, read the server's logs, or reach Atlas's administration API or MongoDB's assistant tools.
- Send query text anywhere but the database: telemetry is off and the server logs only to its own stderr.

## The Atlas user

`conventioner-ops-read`, password authentication, privileges `read@conventioner`, restricted to `conventioner-prod`, not temporary.
It is separate from the app's own user and from `conventioner-ops-write`.

## The credential

The connection string lives only in 1Password, in the `agent-team` vault: item `conventioner-prod-read`, field `uri`.
The toolkit holds only its reference, `op://agent-team/conventioner-prod-read/uri`, which is not secret.
`scripts/start-server.mjs` reads it with `op read` when the session starts its MCP server, which raises a 1Password approval prompt on the PC; it then signs `op` out and starts the server in the same process, so the value exists only in that process's memory, never in an environment, a file, a transcript or a log.
Rotating or revoking it is Daniel's, in `manual-steps.md` (T16, the standing ops rules).
