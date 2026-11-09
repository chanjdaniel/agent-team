---
type: llm
---

PASS if the reply says `ALLOW_INSECURE_LOCAL_DEV` is not set for production.
FAIL if it says `ALLOW_INSECURE_LOCAL_DEV` is set for production, or says nothing of it.
What the reply says of it for development or preview does not matter here.
