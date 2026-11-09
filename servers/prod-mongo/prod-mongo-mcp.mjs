// Serve prod-mongo's MCP server over stdio: the body of toolkits/prod-mongo/scripts/start-server.mjs.
//
//   await startProdMongo({ name, reference, database, root })
//
// `reference` is the 1Password secret reference of a connection string, `database` the one
// database every tool works on, and `root` the backups folder, written from ~/ (PROD_MONGO_ROOT
// replaces it, for the tests only). Before it answers MCP's initialize it, in order: refuses any
// argument; finds mongodump on PATH and reads its version, so no 1Password prompt is spent on a
// launch that cannot back up; imports the pinned MCP SDK and MongoDB driver; reads the connection
// string with readSecrets (op-secret.mjs), checked as prod-read's is. On any failure it exits 1
// with one `<name>: <reason>` line on stderr, never holding the value.
// The value lives only in this function's closure, never in process.env: no child gets it but
// mongodump, through the FIFO backup.mjs feeds it. Every child is started with childEnv()
// (children.mjs), and every child's or the driver's error text reaches an answer only through
// scrubbed. The umask is 077, so every file and directory it or a child makes is its user's alone.
// Its tools: backup (backup.mjs), list-backups (list.mjs) and restore-drill (drill.mjs, which runs
// toolkits/prod-mongo/scripts/restore-drill.mjs through bin/team-heavy), each checking the root
// against root.mjs's rules before it touches it. One long call runs at a time: a backup or a
// restore-drill while either runs is refused at once; list-backups takes no such lock. A long tool
// sends a progress notification per step when the call carries a progressToken. A tool's run gives
// its answer's text, or { text, isError } for an answer that is an error in its own form.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { connectionStringRefusal } from "../mongodb-mcp.mjs";
import { readSecrets } from "../op-secret.mjs";
import { childEnv, scrubber } from "./children.mjs";
import { takeBackup } from "./backup.mjs";
import { drillTool } from "./drill.mjs";
import { kept, listing } from "./list.mjs";
import { Refusal } from "./refusal.mjs";
import { checkRoot } from "./root.mjs";

export async function startProdMongo({ name, reference, database, root: configuredRoot }) {
  const fail = (reason) => {
    process.stderr.write(`${name}: ${reason}\n`);
    process.exit(1);
  };

  if (process.argv.length > 2) fail("takes no arguments");
  process.umask(0o077);

  const version = spawnSync("mongodump", ["--version"], { env: childEnv(), stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", timeout: 30_000 });
  if (version.error?.code === "ENOENT") fail("mongodump is not installed: team-doctor names the install");
  const mongodumpVersion = /^mongodump version: (\S+)$/m.exec(version.stdout ?? "")?.[1];
  if (!mongodumpVersion) fail("mongodump --version gave no version: team-doctor names the install");

  let sdk;
  try {
    sdk = await importSdk();
  } catch {
    fail("the pinned MCP SDK or MongoDB driver is not installed: run servers/install");
  }

  const [value] = readSecrets(name, [reference], connectionStringRefusal);
  const scrubbed = scrubber(value);
  const home = homedir();
  const root = process.env.PROD_MONGO_ROOT ?? configuredRoot.replace(/^~(?=\/)/, home);
  const shown = (path) => (path === home ? "~" : path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path);

  const tools = [
    {
      name: "backup",
      description:
        `Dump the ${database} database into a new folder under ${shown(root)}, named for the UTC time it started, ` +
        "and check the dump against the database's own counts taken before and after it. Answers the folder, each collection's " +
        "document count and the size, never a document. A dump that does not match is removed. Takes no input.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      long: true,
      run: ({ progress }) =>
        takeBackup({ MongoClient: sdk.MongoClient, value, database, root, mongodump: { command: "mongodump", version: mongodumpVersion }, scrubbed, shown, progress }),
    },
    {
      name: "list-backups",
      description:
        `List the dumps under ${shown(root)}, newest first: each one's collections, documents, size, whether it was verified, ` +
        "its newest restore drill's verdict and what was derived from it; then any other entry there (a hand-made dump, " +
        `one a killed backup left unfinished) by name and size; the total, and the dumps past the rule that keeps the newest ${kept} ` +
        "verified ones, for Daniel to delete by hand. Reads only the folder, no database, and sets it to mode 0700 when it is looser. Takes no input.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
      long: false,
      run: () => {
        const { real, note, missing } = checkRoot(root, { shown });
        return listing({ real, shownRoot: shown(root), note, missing });
      },
    },
    {
      name: "restore-drill",
      description:
        `Prove a dump under ${shown(root)} restores: restore it into a throwaway local MongoDB (in memory, on the loopback only, ` +
        "behind a password of its own, removed at the end on every path), compare each collection's document count and index names " +
        "with the dump's manifest, and record the verdict in the dump's folder. Answers PASS or FAIL, each collection that did not " +
        "match, the time taken and that nothing was left running; never a document. Never reaches the production database. It runs " +
        "through the machine's heavy-run lock, waiting up to 20 minutes for it, and answers that the machine is busy when it is still held.",
      inputSchema: {
        type: "object",
        properties: {
          backup: { type: "string", description: "The backup's name, its UTC start as list-backups gives it (2026-11-08T142305Z); the newest verified backup when left out." },
        },
        additionalProperties: false,
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      long: true,
      run: ({ input, progress }) => drillTool({ input, root, shown, scrubbed, progress }),
    },
  ];

  let running = null;
  const server = new sdk.Server({ name, version: "0.1.0" }, { capabilities: { tools: {} } });
  server.setRequestHandler(sdk.ListToolsRequestSchema, async () => ({
    tools: tools.map(({ name: toolName, description, inputSchema, annotations }) => ({ name: toolName, description, inputSchema, annotations })),
  }));
  server.setRequestHandler(sdk.CallToolRequestSchema, async ({ params }, extra) => {
    // Every path from ~/, since the home's own path holds the account's name.
    const refuse = (message) => ({ content: [{ type: "text", text: `${params.name}: ${scrubbed(message).replaceAll(`${home}/`, "~/")}` }], isError: true });
    const tool = tools.find((candidate) => candidate.name === params.name);
    if (!tool) return refuse(`not a tool of ${name}`);
    const input = params.arguments ?? {};
    const unknown = Object.keys(input).filter((key) => !Object.hasOwn(tool.inputSchema.properties, key));
    if (unknown.length) return refuse(`takes no ${unknown.join(" or ")}`);
    if (tool.long && running) return refuse(`a ${running} is already running`);

    const token = params._meta?.progressToken;
    let step = 0;
    const progress = (message) => {
      step += 1;
      if (token === undefined) return;
      extra.sendNotification({ method: "notifications/progress", params: { progressToken: token, progress: step, message } }).catch(() => {});
    };
    if (tool.long) running = tool.name;
    try {
      const answer = await tool.run({ input, progress });
      if (typeof answer === "string") return { content: [{ type: "text", text: answer }] };
      return { content: [{ type: "text", text: answer.text.replaceAll(`${home}/`, "~/") }], ...(answer.isError ? { isError: true } : {}) };
    } catch (error) {
      if (error instanceof Refusal) return refuse(`failed: ${error.message}`);
      return refuse(`failed: ${error?.message ?? error}`);
    } finally {
      if (tool.long) running = null;
    }
  });
  process.stdin.on("end", () => process.exit(0));
  await server.connect(new sdk.StdioServerTransport());
}

async function importSdk() {
  const [{ Server }, { StdioServerTransport }, { ListToolsRequestSchema, CallToolRequestSchema }, { MongoClient }] = await Promise.all([
    import("@modelcontextprotocol/sdk/server/index.js"),
    import("@modelcontextprotocol/sdk/server/stdio.js"),
    import("@modelcontextprotocol/sdk/types.js"),
    import("mongodb"),
  ]);
  return { Server, StdioServerTransport, ListToolsRequestSchema, CallToolRequestSchema, MongoClient };
}

