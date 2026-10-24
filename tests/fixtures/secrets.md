# The team's secrets (a fixture shaped like the team home's machine/secrets.md, 2026-10-24)

Every secret file a machine needs to run the team, for Daniel.
`machine/secrets.json` lists the same files for `team-secrets`, with no value in either.
The values live in 1Password, in the `agent-team` vault, one Document per file, titled with its id.

## The files

| Id | File, under `~` | What it is and where it comes from |
| - | - | - |
| `discord-bot-env` | `.claude/channels/discord/.env` | The coordinator's Discord bot token, `DISCORD_BOT_TOKEN=...`: Discord developer portal, the team's application, Bot, Reset Token. |
| `discord-access-json` | `.claude/channels/discord/access.json` | The Discord plugin's allowlist of who may message the coordinator: written by the plugin's pairing (`/discord:access`), not by hand. |
| `conventioner-env` | `Documents/projects/personal/Conventioner/.env` | Conventioner's Docker Compose environment: Conventioner's `.env.example` names each value. |
| `conventioner-front-end-env` | `Documents/projects/personal/Conventioner/front-end/.env` | The front-end dev server's environment: `front-end/.env.example` in Conventioner. |
| `conventioner-back-end-env` | `Documents/projects/personal/Conventioner/back-end/.env` | The back-end dev server's environment: `back-end/.env.example` in Conventioner. |
| `hub-env` | `agent-team/hub/.env` | The hub bot's token, `DISCORD_TOKEN=...` (phase 2, parked): disabled in the manifest until the hub exists. |

Each file has mode 600, and `team-secrets restore` makes any folder it creates with mode 700.

