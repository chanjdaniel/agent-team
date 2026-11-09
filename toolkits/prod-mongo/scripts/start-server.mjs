// The prod-mongo server, as Claude Code starts it from ../.mcp.json: backups of Conventioner's
// production database, on the read user's connection string from 1Password, with the toolkit's
// settings (./settings.mjs). See servers/prod-mongo/server.mjs.
import { startProdMongo } from "../../../servers/prod-mongo/server.mjs";
import { settings } from "./settings.mjs";

await startProdMongo(settings);
