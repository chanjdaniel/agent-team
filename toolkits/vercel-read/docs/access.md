# What vercel-read reaches

## It can

- Read, for Conventioner's two Vercel projects (`makers-market-management-front-end` and `makers-market-management-back-end`, team `chanjdaniels-projects`):
  - which deployment `conventioner.io` and `api.conventioner.io` each serve, and whether that is the project's newest ready production deployment (`domain-deployment`);
  - a project's deployments, with their state and commit, paging back (`list-deployments`);
  - one deployment's details: its aliases and its error code and message (`get-deployment`);
  - a deployment's runtime logs, as Vercel's Hobby plan keeps them (about an hour), with email addresses, phone numbers, URL credentials (URL-encoded too), Bearer and Basic credentials, Vercel tokens, private keys and the values of credential-named parameters, headers and JSON keys (`access_token=`, `x-api-key:`, `"password":`) masked (`runtime-logs`); the masks match shapes, so a secret of no known shape or name passes;
  - the names, types and targets of a project's environment variables, and whether each name given is set (`list-env-names`).
- Each of those is one or more `GET` requests to `https://api.vercel.com`, on one of five endpoints only: `/v7/deployments`, `/v13/deployments/{id or host}`, `/v9/projects/{id}/domains`, `/v1/projects/{id}/deployments/{id}/runtime-logs` and `/v10/projects/{id}/env`.

## It cannot

- Write anything: the server sends only `GET`s, so it cannot deploy, promote, roll back, redeploy, add, change or delete a variable, or change a project, a domain or an alias; there is no write tool, and the one request function refuses any other method, path, query key, project or host.
- Read a variable's value: it never sends `decrypt`, has no path to one variable (`/v1/projects/{id}/env/{id}`) or to a project itself (`/v9/projects/{id}`, which carries every value), and drops the `value` Vercel's list still carries for a `plain` variable, with its comment and every other field, before an answer is built.
- Read build logs (`/v3/deployments/{id}/events`), which may echo a variable.
- Read another project: every request names one of the two project ids read from 1Password at launch, or a deployment whose answer must belong to the project the call names.
- Reach team or account resources (members, billing, other projects, tokens, team-level aliases), which a project-scoped token is refused, and the server has no path to.
- Pass on what Vercel's answers carry beyond the allowed fields: a creator's email address, the Git provider's other metadata, a deployment's `env` and `build.env`, its OIDC claims, an alias's protection bypass secret.
- Send a token anywhere but Vercel: the only other origin the server takes is the tests' fake on the loopback (`VERCEL_READ_API`), and it refuses at start a value that is not `http://127.0.0.1:<port>` or `http://[::1]:<port>`; it follows no redirect.

## The tokens

Two Vercel access tokens, each scoped to one project (Vercel's "Project" scope), with a 90-day expiration:

- `agent-team-vercel-read-front-end`, for `makers-market-management-front-end`, in 1Password at `op://agent-team/conventioner-vercel-read/front-end-token`;
- `agent-team-vercel-read-back-end`, for `makers-market-management-back-end`, at `op://agent-team/conventioner-vercel-read/back-end-token`.

The same 1Password item holds the Vercel team id (`team-id`) and the two project ids (`front-end-project-id`, `back-end-project-id`), which are not secret but stay out of this public repository.
The toolkit holds only the references.
`scripts/start-server.mjs` reads all five with `op read` when the session starts its MCP server, which raises one 1Password approval prompt on the PC; it then signs `op` out and serves from the same process, so the tokens exist only in that process's memory, never in an environment, a file, a transcript or a log, and any error text it writes or answers has each token replaced by `[redacted]`.
Before it serves, it checks that each token reaches its own project and is refused the other, and exits when either check fails.
These are separate from GitHub's `VERCEL_TOKEN`, the Deploy workflow's, which is scoped to the team.

## If a token leaked

Vercel offers no read-only access token: a project-scoped token can read and write everything of its one project.
So whoever held one could, on that project: create a deployment, promote one or roll back to one, read every variable's decrypted value, create, change and delete variables, change the project's settings and domains, and delete the project.
It could not reach the other project, the team's other resources or Daniel's account: Vercel refuses a project-scoped token any request to another project, a user-level or a team-level resource, and such a token cannot mint new tokens.

What limits that here:

- The token never reaches the agent: it lives only in the server process, which the ops session talks to over stdio, and an ops session has no shell, no web and no file access outside its worktree.
- The server's only outbound requests are the `GET`s above; no tool can name another path, method, project or host.
- Every answer is built from allowed fields, never passed through.
- Each token is scoped to one project, so one leak reaches one project; the launcher refuses a token that reaches the other project, as a team-scoped or full-account token would.
- Each token expires after 90 days, and deleting it on Vercel's Account Tokens page ends it at once.

## Rotating and revoking

Making, rotating and revoking the tokens are Daniel's steps, in the team home's `manual-steps.md`.

- Rotating, before the 90 days end, or at once if a token was ever pasted anywhere or an agent reports one exposed: create a new token the same way, paste it over its field in 1Password, then delete the old token on Account Tokens (`vercel.com/account/tokens`); nothing in the toolkit changes.
- Revoking at once: delete both tokens on Account Tokens, or the 1Password item; every launch with `vercel-read` then exits with "the <project> token was refused", and the session reports BLOCKED.
- An expired token shows the same way, and rotating it fixes it.
