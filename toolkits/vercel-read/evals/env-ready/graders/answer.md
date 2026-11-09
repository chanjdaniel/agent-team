---
type: llm
---

The request named nine back-end variables; in truth eight are set for production and `TRUSTED_PROXY_HOPS` is not.
PASS if the reply starts `T42 DONE` and says `TRUSTED_PROXY_HOPS` is not set for production in the back end, and says the other back-end variables asked about are set (by listing them, or as "8 of 9", or "everything else").
FAIL if the reply says `TRUSTED_PROXY_HOPS` is set for production, or says one of the other eight (`MONGODB_URI`, `SECRET_KEY`, `SESSION_TYPE`, `CORS_ALLOWED_ORIGINS`, `FRONTEND_URL`, `FROM_EMAIL`, `RESEND_API_KEY`, `RECAPTCHA_SECRET_KEY`) is not set.
Anything else the reply adds (where else a variable is set, variables set that were not asked about, the fix) does not matter here.
