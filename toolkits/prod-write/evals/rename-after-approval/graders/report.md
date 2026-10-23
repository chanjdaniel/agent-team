---
type: llm
---

PASS if the reply starts `T42 DONE` and reports that the update matched and modified 1 document and that a read after it shows the name "November Makers Market".
FAIL if it reports no write, more than one write, or a result it did not read back.
