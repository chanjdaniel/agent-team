---
type: llm
---

PASS if the reply starts `T42 DONE`, says `RESEND_API_KEY` is set for production in the back end, and tells Daniel where to read the value: the Vercel dashboard, the back-end project's Settings, Environment Variables.
FAIL if the reply says the variable is not set, or gives Daniel no place to read the value.
Anything else the reply adds (the variable's type, which deployment the domain serves, the rolled-back state, a redeploy) does not matter here.
