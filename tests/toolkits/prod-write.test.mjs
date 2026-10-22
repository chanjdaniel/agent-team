// The prod-write toolkit's server as Claude Code starts it from toolkits/prod-write/.mcp.json, with
// op stubbed (helpers/op) and a throwaway MongoDB 8.0 (helpers/mongo.mjs) in place of production.
// The main test user has readWrite, so every tool missing here is the server's doing; a second
// user holds exactly the custom role Daniel creates in Atlas (ticket 01), to prove it is enough.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";
import { opStub, repoRoot, startServer, startToolkitServer, tempDir } from "./helpers/mcp.mjs";
import { startMongo } from "./helpers/mongo.mjs";
import { assertNoLeak, children, launcherRefusalTests } from "./helpers/toolkit.mjs";

const reference = "op://agent-team/conventioner-prod-write/uri";
const writeTools = ["create-index", "delete-many", "drop-index", "insert-many", "update-many"];
const absentTools = [
  "connect", "disconnect", "list-connections", "find", "aggregate", "aggregate-db", "count",
  "collection-indexes", "collection-schema", "collection-storage-size", "db-stats", "explain",
  "list-collections", "list-databases", "export", "mongodb-logs", "search-knowledge",
  "list-knowledge-sources", "create-collection", "drop-collection", "drop-database", "rename-collection",
];
// The spec's conventionerOpsWrite: on every collection of conventioner, and nothing inherited.
const opsWriteActions = [
  "find", "insert", "update", "remove", "createIndex", "dropIndex", "listCollections", "listIndexes",
  "collStats", "dbStats",
];
// The test users' password, which every connection string the op stub prints carries.
const marker = `pwmarker${randomBytes(8).toString("hex")}`;
const markets = [
  { _id: 1, name: "Riverside Night Market", city: "Vancouver", stalls: 40 },
  { _id: 2, name: "Harbour Craft Fair", city: "Victoria", stalls: 25 },
  { _id: 3, name: "Lakeside Summer Market", city: "Kelowna", stalls: 15 },
];
const on = { connectionId: "preconfigured", database: "conventioner" };

let db;
let home;

before(async () => {
  db = await startMongo();
  await db.createUser("ops-write", marker, [{ role: "readWrite", db: "conventioner" }]);
  await db.client.db("admin").command({
    createRole: "conventionerOpsWrite",
    privileges: [{ resource: { db: "conventioner", collection: "" }, actions: opsWriteActions }],
    roles: [],
  });
  await db.createUser("ops-write-role", marker, [{ role: "conventionerOpsWrite", db: "admin" }]);
});

after(async () => {
  await db?.stop();
});

beforeEach(async () => {
  await db.seed("conventioner", { markets });
  await collection("markets").createIndex({ city: 1 }, { name: "city_1" });
  home = tempDir("home");
});

// Start the server as `user`, initialize it as a client that supports elicitation (as Claude Code
// does), run `body`, then close it and check what must hold after every run.
async function withServer(body, { user = "ops-write", env, start = startToolkitServer.bind(null, "prod-write") } = {}) {
  const op = opStub({ value: db.uri(user, marker) });
  const server = start({ home, opDir: op.dir, env });
  try {
    await server.initialize({ elicitation: true });
    await body(server, op);
  } finally {
    await server.close();
    assertNoLeak(server, { marker, home });
  }
}

const names = (tools) => tools.map((tool) => tool.name).sort();
const collection = (name) => db.client.db("conventioner").collection(name);
const indexNames = async () => (await collection("markets").indexes()).map((index) => index.name).sort();
const elicitations = (server) => server.fromServer.filter((message) => message.method === "elicitation/create");

// One call of each tool, and what it must leave in the database.
const writes = [
  {
    tool: "insert-many",
    args: { collection: "markets", documents: [{ _id: 4, name: "Valley Makers Market", city: "Nelson", stalls: 10 }] },
    async check() {
      assert.deepEqual(await collection("markets").findOne({ _id: 4 }), { _id: 4, name: "Valley Makers Market", city: "Nelson", stalls: 10 });
      assert.equal(await collection("markets").countDocuments(), 4);
    },
  },
  {
    tool: "update-many",
    args: { collection: "markets", filter: { _id: 2 }, update: { $set: { name: "Harbour Winter Fair" } } },
    async check() {
      assert.equal((await collection("markets").findOne({ _id: 2 })).name, "Harbour Winter Fair");
      assert.equal((await collection("markets").findOne({ _id: 1 })).name, "Riverside Night Market");
    },
  },
  {
    tool: "delete-many",
    args: { collection: "markets", filter: { _id: 3 } },
    async check() {
      assert.deepEqual(await collection("markets").distinct("_id"), [1, 2]);
    },
  },
  {
    tool: "create-index",
    args: { collection: "markets", name: "stalls_-1", definition: [{ type: "classic", keys: { stalls: -1 } }] },
    async check() {
      assert.deepEqual(await indexNames(), ["_id_", "city_1", "stalls_-1"]);
    },
  },
  {
    tool: "drop-index",
    args: { collection: "markets", indexName: "city_1", type: "classic" },
    async check() {
      assert.deepEqual(await indexNames(), ["_id_"]);
    },
  },
];

test("the MCP config names one server, prod-write, with no secret and no path but through @TEAM_HOME@", () => {
  const config = JSON.parse(readFileSync(join(repoRoot, "toolkits", "prod-write", ".mcp.json"), "utf8"));
  assert.deepEqual(Object.keys(config.mcpServers), ["prod-write"]);
  const { command, args, env } = config.mcpServers["prod-write"];
  assert.equal(command, "node");
  assert.deepEqual(args, ["@TEAM_HOME@/toolkits/prod-write/scripts/start-server.mjs"]);
  assert.equal(env, undefined);
});

describe("the tools", () => {
  test("are exactly the document-write and index tools", async () => {
    await withServer(async (server) => {
      const listed = names(await server.listTools());
      assert.deepEqual(listed, writeTools);
      for (const tool of absentTools) assert.ok(!listed.includes(tool), `${tool} is listed`);
      assert.deepEqual(listed.filter((name) => name.startsWith("atlas")), []);
    });
  });

  test("stay that set when the environment says otherwise", async () => {
    const env = { MDB_MCP_READ_ONLY: "true", MDB_MCP_DISABLED_TOOLS: "", MDB_MCP_CONFIRMATION_REQUIRED_TOOLS: "delete-many" };
    await withServer(async (server) => {
      assert.deepEqual(names(await server.listTools()), writeTools);
      const result = await server.callTool("delete-many", { ...on, collection: "markets", filter: { _id: 3 } });
      assert.ok(!result.isError, result.text);
      assert.deepEqual(elicitations(server), []);
    }, { env });
  });
});

describe("writes", () => {
  for (const { tool, args, check } of writes) {
    test(`${tool} changes the seeded data as asked, with no elicitation request`, async () => {
      await withServer(async (server) => {
        const result = await server.callTool(tool, { ...on, ...args });
        assert.ok(!result.isError, result.text);
        assert.deepEqual(elicitations(server), []);
      });
      await check();
    });
  }

  // The control: with the server's own default list, the same client is asked to confirm, so the
  // empty list is what keeps Claude Code's ask rule the one gate.
  test("the server's default confirmation list would elicit, and the test client sees it", async () => {
    const dir = tempDir("control");
    writeFileSync(join(dir, "start.mjs"), `import { startMongodbMcp } from ${JSON.stringify(join(repoRoot, "servers", "mongodb-mcp.mjs"))};
await startMongodbMcp({ name: "control", reference: "op://x/y/z", settings: { MDB_MCP_READ_ONLY: "false" } });
`);
    const start = (options) => startServer({ command: process.execPath, args: [join(dir, "start.mjs")] }, options);
    await withServer(async (server) => {
      const result = await server.callTool("delete-many", { ...on, collection: "markets", filter: { _id: 3 } });
      assert.equal(result.isError, true);
      assert.equal(elicitations(server).length, 1);
    }, { start });
    assert.equal(await collection("markets").countDocuments(), 3);
  });
});

describe("the conventionerOpsWrite role", () => {
  for (const { tool, args, check } of writes) {
    test(`is enough for ${tool}`, async () => {
      await withServer(async (server) => {
        const result = await server.callTool(tool, { ...on, ...args });
        assert.ok(!result.isError, result.text);
      }, { user: "ops-write-role" });
      await check();
    });
  }

  test("is refused dropping or renaming a collection, and dropping the database", async () => {
    const client = await db.connectAs("ops-write-role", marker);
    try {
      const conventioner = client.db("conventioner");
      const refused = { codeName: "Unauthorized" };
      await assert.rejects(conventioner.collection("markets").drop(), refused);
      await assert.rejects(conventioner.dropDatabase(), refused);
      await assert.rejects(conventioner.renameCollection("markets", "markets_renamed"), refused);
    } finally {
      await client.close();
    }
    assert.equal(await collection("markets").countDocuments(), 3);
    assert.deepEqual(names(await db.client.db("conventioner").listCollections().toArray()), ["markets"]);
  });

  // MongoDB lets insert create a collection, and insert with remove run $out, without the
  // createCollection action. No prod-write tool runs either (no create-collection, no
  // aggregate), and neither does more than delete-many and insert-many could.
  test("still allows creating a collection and $out, which only insert and remove imply", async () => {
    const client = await db.connectAs("ops-write-role", marker);
    try {
      const conventioner = client.db("conventioner");
      await conventioner.createCollection("ops_new");
      await conventioner.collection("markets").aggregate([{ $match: { _id: 1 } }, { $out: "ops_new" }]).toArray();
    } finally {
      await client.close();
    }
    assert.deepEqual(await collection("ops_new").distinct("_id"), [1]);
  });
});

describe("the secret", () => {
  test("is read once from its reference, then op signs out, with stdin never the transport", async () => {
    await withServer(async (_server, op) => {
      assert.deepEqual(op.calls(), [`read --no-newline ${reference} stdin=/dev/null`, "signout stdin=/dev/null"]);
    });
  });

  test("is not in the server's starting environment, and the server has no child process", async () => {
    await withServer(async (server) => {
      const check = () => {
        const environ = readFileSync(`/proc/${server.pid}/environ`, "utf8");
        assert.ok(!environ.includes(marker), "the password marker is in /proc/<pid>/environ");
        assert.ok(!environ.includes("MDB_MCP_CONNECTION_STRING"));
        assert.deepEqual(children(server.pid), []);
      };
      check();
      await server.callTool("update-many", { ...on, collection: "markets", filter: { _id: 1 }, update: { $inc: { stalls: 1 } } });
      check();
    });
  });
});

describe("the launcher refuses before the server starts", () => {
  launcherRefusalTests("prod-write", () => ({ value: db.uri("ops-write", marker), home, marker }));
});
