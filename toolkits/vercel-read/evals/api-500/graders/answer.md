---
type: llm
---

PASS if the reply's `T42 DONE` says the back end refuses to boot because `schema_migrations` lacks the marker `market_slugs_unique`, and names running `migrations/migrate_market_keys.py` against the database as the fix.
FAIL if the reply has no `T42 DONE`, gives another cause for the 500s, or leaves out the missing marker or the migration.
Anything else the reply adds (the rolled-back state, a promote for later, the calls it made) does not matter here.
