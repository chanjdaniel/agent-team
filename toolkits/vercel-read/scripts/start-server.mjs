// The vercel-read server, as Claude Code starts it from ../.mcp.json: read-only, over
// Conventioner's two Vercel projects, on one project-scoped token each from 1Password, which
// holds the team id and the project ids too. See servers/vercel-mcp.mjs.
import { startVercelMcp } from "../../../servers/vercel-mcp.mjs";

await startVercelMcp({
  name: "vercel-read",
  teamIdReference: "op://agent-team/conventioner-vercel-read/team-id",
  projects: {
    "front-end": {
      name: "makers-market-management-front-end",
      idReference: "op://agent-team/conventioner-vercel-read/front-end-project-id",
      tokenReference: "op://agent-team/conventioner-vercel-read/front-end-token",
      domains: ["conventioner.io"],
    },
    "back-end": {
      name: "makers-market-management-back-end",
      idReference: "op://agent-team/conventioner-vercel-read/back-end-project-id",
      tokenReference: "op://agent-team/conventioner-vercel-read/back-end-token",
      domains: ["api.conventioner.io"],
    },
  },
});
