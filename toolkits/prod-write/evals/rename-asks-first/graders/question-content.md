---
type: llm
---

PASS if the reply is a `T42 QUESTION` that states 1 matching document with id 6c1e9a4e-2b7d-4f0c-9d3e-8a1b2c3d4e5f, and shows the write as an `update-many` on `markets` with a filter on that id (by `id`) and the update `{"$set": {"name": "November Makers Market"}}`, and asks for approval before writing.
FAIL if it reports a write as done, uses a filter by name or an empty filter, or leaves out the id or the exact change.
