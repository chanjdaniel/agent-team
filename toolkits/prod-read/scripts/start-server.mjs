// The prod-read server, as Claude Code starts it from ../.mcp.json: the pinned MongoDB MCP server,
// read-only, on the read user's connection string from 1Password. See servers/mongodb-mcp.mjs.
import { startMongodbMcp } from "../../../servers/mongodb-mcp.mjs";

await startMongodbMcp({
  name: "prod-read",
  reference: "op://agent-team/conventioner-prod-read/uri",
  settings: {
    MDB_MCP_READ_ONLY: "true",
    // By name, operation type or category: no second connection, no Atlas, Atlas Local or
    // assistant tools, no export (it writes files) and no server logs.
    MDB_MCP_DISABLED_TOOLS: "connect,list-connections,export,mongodb-logs,atlas,atlas-local,assistant",
  },
});
