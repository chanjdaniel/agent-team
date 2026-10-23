// The prod-write server, as Claude Code starts it from ../.mcp.json: the pinned MongoDB MCP server
// with only its document-write and index tools, on the write user's connection string from
// 1Password. See servers/mongodb-mcp.mjs.
import { startMongodbMcp } from "../../../servers/mongodb-mcp.mjs";

await startMongodbMcp({
  name: "prod-write",
  reference: "op://agent-team/conventioner-prod-write/uri",
  settings: {
    MDB_MCP_READ_ONLY: "false",
    // By name, operation type or category: no reads (they go through prod-read), no second
    // connection, no drop, rename or create of a collection or database, no Atlas, Atlas Local or
    // assistant tools, no export (it writes files) and no server logs.
    MDB_MCP_DISABLED_TOOLS: [
      "read", "metadata", "connect", "list-connections", "export", "mongodb-logs",
      "drop-database", "drop-collection", "rename-collection", "create-collection",
      "atlas", "atlas-local", "assistant",
    ].join(","),
    // Claude Code's ask rule (settings/ops.json) is the one gate on every write: no second,
    // elicitation dialog from the server.
    MDB_MCP_CONFIRMATION_REQUIRED_TOOLS: "",
  },
});
