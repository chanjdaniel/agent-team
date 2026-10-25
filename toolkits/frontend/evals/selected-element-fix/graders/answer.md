---
type: llm
---

PASS if the reply works from a capture of the element Daniel selected: it ran `ui-capture` and used what it captured, or it says the capture could not run, why (no shell in the session, no Agent Chrome, nothing inspected), and what would let it run.
FAIL if the reply names a component, file or line as the selected element's source without a capture, guesses which element was meant, or claims to have changed a file.
