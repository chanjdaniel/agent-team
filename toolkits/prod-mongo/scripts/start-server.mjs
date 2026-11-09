// The prod-mongo server, as Claude Code starts it from ../.mcp.json: backups of Conventioner's
// production database, on the read user's connection string from 1Password. See
// servers/prod-mongo/server.mjs.
import { startProdMongo } from "../../../servers/prod-mongo/server.mjs";

await startProdMongo({
  name: "prod-mongo",
  reference: "op://agent-team/conventioner-prod-read/uri",
  database: "conventioner",
  root: "~/conventioner-backups",
});
