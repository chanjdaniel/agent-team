// The vercel-read server, as Claude Code starts it from ../.mcp.json: read-only, over
// Conventioner's two Vercel projects, on one project-scoped token each from 1Password. See
// servers/vercel-mcp.mjs.
import { startVercelMcp } from "../../../servers/vercel-mcp.mjs";

await startVercelMcp({
  name: "vercel-read",
  teamId: "team_Gbd0cUxeyRWKRqeIhkta9F8Q",
  projects: {
    "front-end": {
      id: "prj_uWBC9BJyAmG3KITC5y23AHtq7eyN",
      name: "makers-market-management-front-end",
      reference: "op://agent-team/conventioner-vercel-read/front-end-token",
      domains: ["conventioner.io"],
    },
    "back-end": {
      id: "prj_KlG2FlrqAxbX7afm7xuYEcBzqPeg",
      name: "makers-market-management-back-end",
      reference: "op://agent-team/conventioner-vercel-read/back-end-token",
      domains: ["api.conventioner.io"],
    },
  },
});
