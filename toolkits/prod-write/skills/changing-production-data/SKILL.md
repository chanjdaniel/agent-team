---
name: changing-production-data
description: Changes documents or indexes in a project's production MongoDB database through the prod-write tools, one approved call at a time, each filtered by the document's key and checked by a read before and after. Use when an ops request asks to fix, rename, insert, delete or re-index production data, before the first read for it.
---

# Changing production data

The `prod-write` server is the pinned MongoDB MCP server connected as a write user that cannot drop or rename a collection or a database.
Its tools are `insert-many`, `update-many`, `delete-many`, `create-index` and `drop-index`, named `mcp__prod-write__<tool>` or `mcp__plugin_prod-write_prod-write__<tool>` depending on the launch; it has no read tool, so every read goes through `prod-read` and the `querying-production-data` skill.
What the toolkit can and cannot reach, and where its credential lives: [docs/access.md](${CLAUDE_PLUGIN_ROOT}/docs/access.md).

Every `prod-write` call raises a permission prompt on Daniel's phone that shows only the call's raw input.
The ops role's write protocol (read, ask, write, read again) is the contract; this skill is how each step is done.

## 1. Read what the write will match

- Write the filter first, by the document's key: `id` for Conventioner's documents (a UUID string), or `_id`.
  A filter by name, by state or by any field another document could share is how one fix becomes many.
- `count` that exact filter on `prod-read`, then `find` it with a projection of the key and the fields the change touches, and `limit: 21`: 21 results means more than 20 documents, which waits for Daniel's own `mongodump`.
- Check the data docs for fields derived from the one being changed (a market's `slug` derives from its `name`, which may change only while the market is a draft) and for rules the app enforces on writes; a direct write bypasses them all, so each one the change touches is named in the QUESTION.

## 2. Ask, in the shape the prompt will show

One QUESTION covers the whole change: the count and the ids read, then each call exactly as it will be sent, with what it does in plain words.

```text
T42 QUESTION 1 document in markets matches, id 6c1e9a4e-2b7d-4f0c-9d3e-8a1b2c3d4e5f (name "Novmber Makers Market", phase draft).
Write 1 of 1, update-many on conventioner.markets:
  filter {"id": "6c1e9a4e-2b7d-4f0c-9d3e-8a1b2c3d4e5f"}
  update {"$set": {"name": "November Makers Market"}}
  Renames that market; its slug "novmber-makers-market" is unchanged by this write.
Approve?
```

An empty filter is written `EVERY DOCUMENT (filter {})`; a request that needs one is said to be a request for every document in the collection.
Then wait for the answer; no write tool is called before it comes.

## 3. Write, one call per approved change

Send each call with exactly the input the QUESTION showed, since Daniel compares the two on the prompt:

| Tool | Input beside `connectionId: "preconfigured"`, `database`, `collection` |
| - | - |
| `update-many` | `filter` by key, `update` with operators only (`$set`, `$unset`, `$inc`); `upsert` left out |
| `delete-many` | `filter` by key |
| `insert-many` | `documents`, each with its `id` and every field the data docs require |
| `create-index` | `definition: [{"type": "classic", "keys": {"<field>": 1}}]`, `name` |
| `drop-index` | `indexName`, `type: "classic"` |

`filter` is optional to the server, and a missing one matches every document: always send it.

Each result says what happened: `Matched 1 document(s). Modified 1 document(s).`, ``Deleted `1` document(s) ...``, ``Inserted `1` document(s) ...``.
A count other than the one the QUESTION stated stops the change: report it before any further call.

A declined prompt returns "The user doesn't want to proceed with this tool use."; it is Daniel's answer to that call.

## 4. Read again

`find` the same filter with the same projection, and report each document before and after, beside what was declined or not run.

## Worked example: renaming a market

Daniel asks to fix the typo in the November market's name.

1. `prod-read` `find` on `markets`, `filter: {"name": {"$regex": "^Novmber", "$options": "i"}}`, `projection: {"_id": 0, "id": 1, "name": 1, "slug": 1, "phase": 1}`, `limit: 21`: one document, `id` `6c1e...`, phase `draft`.
2. The data docs: `slug` derives from `name` and is stored; `name` may change only while the market is a draft, which it is.
3. The QUESTION above, sent to the coordinator; Daniel answers yes.
4. `prod-write` `update-many` with `filter: {"id": "6c1e..."}` and `update: {"$set": {"name": "November Makers Market"}}`: "Matched 1 document(s). Modified 1 document(s)."
5. `prod-read` `find` with the same filter and projection shows the new name and the old slug; the report says so, and that the slug changes only through the app or its migration.
