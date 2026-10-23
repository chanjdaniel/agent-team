// The prod-read toolkit's server as Claude Code starts it from toolkits/prod-read/.mcp.json, with
// op stubbed (helpers/op) and a throwaway MongoDB 8.0 (helpers/mongo.mjs) in place of production.
// The test user may write, so every refusal here is the server's own, not the database's.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync, readdirSync, readlinkSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";
import { opStub, repoRoot, startToolkitServer, tempDir } from "./helpers/mcp.mjs";
import { startMongo } from "./helpers/mongo.mjs";
import { assertNoLeak, children, evalMockTools, launcherRefusalTests } from "./helpers/toolkit.mjs";

const reference = "op://agent-team/conventioner-prod-read/uri";
const readTools = [
  "aggregate", "aggregate-db", "collection-indexes", "collection-schema", "collection-storage-size",
  "count", "db-stats", "explain", "find", "list-collections", "list-databases",
];
const absentTools = [
  "connect", "disconnect", "export", "mongodb-logs", "list-connections", "search-knowledge",
  "list-knowledge-sources", "insert-many", "update-many", "delete-many", "create-index", "drop-index",
  "create-collection", "drop-collection", "drop-database", "rename-collection",
];
// The test user's password, which every connection string the op stub prints carries.
const marker = `pwmarker${randomBytes(8).toString("hex")}`;
const markets = [
  { name: "Riverside Night Market", city: "Vancouver", stalls: 40 },
  { name: "Harbour Craft Fair", city: "Victoria", stalls: 25 },
  { name: "Lakeside Summer Market", city: "Kelowna", stalls: 15 },
];
const on = { connectionId: "preconfigured", database: "conventioner" };

let db;
let home;

before(async () => {
  db = await startMongo();
  await db.createUser("ops-read", marker, [{ role: "readWrite", db: "conventioner" }]);
  await db.createUser("ops-stale", "not-the-marker", [{ role: "read", db: "conventioner" }]);
});

after(async () => {
  await db?.stop();
});

beforeEach(async () => {
  await db.seed("conventioner", { markets, markets_copy: [{ name: "kept" }] });
  home = tempDir("home");
});

// Start the server on `value` (by default the test user's connection string), initialize it,
// run `body`, then close it and check what must hold after every run.
async function withServer(body, { value = db.uri("ops-read", marker), env } = {}) {
  const op = opStub({ value });
  const server = startToolkitServer("prod-read", { home, opDir: op.dir, env });
  try {
    await server.initialize();
    await body(server, op);
  } finally {
    await server.close();
    assertNoLeak(server, { marker, home });
  }
}

const names = (tools) => tools.map((tool) => tool.name).sort();
const documents = async (collection) =>
  db.client.db("conventioner").collection(collection).find({}, { projection: { _id: 0 } }).toArray();

test("the MCP config names one server, prod-read, with no secret and no path but through @TEAM_HOME@", () => {
  const config = JSON.parse(readFileSync(join(repoRoot, "toolkits", "prod-read", ".mcp.json"), "utf8"));
  assert.deepEqual(Object.keys(config.mcpServers), ["prod-read"]);
  const { command, args, env } = config.mcpServers["prod-read"];
  assert.equal(command, "node");
  assert.deepEqual(args, ["@TEAM_HOME@/toolkits/prod-read/scripts/start-server.mjs"]);
  assert.equal(env, undefined);
});

describe("the tools", () => {
  test("are exactly the prod-read set", async () => {
    await withServer(async (server) => {
      const listed = names(await server.listTools());
      assert.deepEqual(listed, readTools);
      for (const tool of absentTools) assert.ok(!listed.includes(tool), `${tool} is listed`);
      assert.deepEqual(listed.filter((name) => name.startsWith("atlas")), []);
    });
  });

  test("are what the skill's eval mocks hold, schemas and all", async () => {
    await withServer(async (server) => {
      const listed = await server.listTools();
      for (const kit of ["prod-read", "prod-write"]) {
        assert.deepEqual(evalMockTools(kit, "prod-read"), listed, `toolkits/${kit}/evals/mocks/prod-read/_tools.json`);
      }
    });
  });

  test("stay the prod-read set when the environment says otherwise", async () => {
    const env = { MDB_MCP_READ_ONLY: "false", MDB_MCP_DISABLED_TOOLS: "", MDB_MCP_DRY_RUN: "true" };
    await withServer(async (server) => {
      assert.deepEqual(names(await server.listTools()), readTools);
    }, { env });
  });
});

describe("reads", () => {
  test("find returns the seeded documents", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("find", { ...on, collection: "markets", filter: { city: "Victoria" } });
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /Harbour Craft Fair/);
      assert.doesNotMatch(result.text, /Riverside Night Market/);
    });
  });

  test("count counts the seeded documents", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("count", { ...on, collection: "markets", query: { stalls: { $gte: 20 } } });
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /Found 2 documents/);
    });
  });

  test("aggregate runs a read pipeline", async () => {
    await withServer(async (server) => {
      const pipeline = [{ $group: { _id: null, stalls: { $sum: "$stalls" } } }];
      const result = await server.callTool("aggregate", { ...on, collection: "markets", pipeline });
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /"stalls":\s*80/);
    });
  });

  test("list-collections lists the seeded collections", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("list-collections", on);
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /"markets"/);
      assert.match(result.text, /"markets_copy"/);
    });
  });
});

describe("refusals", () => {
  for (const [stage, spec] of [["$out", "markets_copy"], ["$merge", { into: "markets_copy" }]]) {
    test(`aggregate with ${stage} is refused and the target is unchanged`, async () => {
      await withServer(async (server) => {
        const pipeline = [{ $match: {} }, { [stage]: spec }];
        const result = await server.callTool("aggregate", { ...on, collection: "markets", pipeline });
        assert.equal(result.isError, true);
        assert.match(result.text, /In readOnly mode you can not run pipelines with \$out or \$merge stages/);
      });
      assert.deepEqual(await documents("markets_copy"), [{ name: "kept" }]);
    });
  }

  test("$where in a find filter is refused", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("find", { ...on, collection: "markets", filter: { $where: "true" } });
      assert.equal(result.isError, true);
      assert.match(result.text, /The "\$where" operator is not allowed/);
    });
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
      await server.callTool("find", { ...on, collection: "markets", filter: {} });
      await server.callTool("aggregate", { ...on, collection: "markets", pipeline: [{ $count: "n" }] });
      check();
    });
  });

  test("the server talks to nothing but the database", async () => {
    await withServer(async (server) => {
      await server.callTool("find", { ...on, collection: "markets", filter: {} });
      const peers = inetPeers(server.pid);
      assert.ok(peers.length > 0, "no connection to the database");
      assert.deepEqual([...new Set(peers)], [`127.0.0.1:${db.port}`]);
    });
  });

  test("is not printed when the password is wrong", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("find", { ...on, collection: "markets", filter: {} });
      assert.equal(result.isError, true);
    }, { value: db.uri("ops-stale", marker) });
  });

  test("is not printed when the database is unreachable", async () => {
    const value = `mongodb://ops-read:${marker}@127.0.0.1:1/?authSource=admin&serverSelectionTimeoutMS=2000`;
    await withServer(async (server) => {
      const result = await server.callTool("find", { ...on, collection: "markets", filter: {} });
      assert.equal(result.isError, true);
    }, { value });
  });
});

describe("the launcher refuses before the server starts", () => {
  launcherRefusalTests("prod-read", () => ({ value: db.uri("ops-read", marker), home, marker }));
});

// The remote address of every TCP and UDP socket the process holds, as "host:port".
function inetPeers(pid) {
  const inodes = new Set();
  for (const fd of readdirSync(`/proc/${pid}/fd`)) {
    try {
      const link = readlinkSync(`/proc/${pid}/fd/${fd}`);
      if (link.startsWith("socket:[")) inodes.add(link.slice(8, -1));
    } catch {
      // The descriptor closed while we looked.
    }
  }
  const peers = [];
  for (const table of ["tcp", "tcp6", "udp", "udp6"]) {
    for (const line of readFileSync(`/proc/${pid}/net/${table}`, "utf8").trim().split("\n").slice(1)) {
      const fields = line.trim().split(/\s+/);
      if (inodes.has(fields[9])) peers.push(address(fields[2]));
    }
  }
  return peers;
}

// /proc/net's hex address: IPv4 as one little-endian word, IPv6 as four.
function address(hex) {
  const [host, port] = hex.toLowerCase().split(":");
  const words = host.match(/.{8}/g).map((word) => word.match(/../g).reverse().join(""));
  const ipv4 = (word) => word.match(/../g).map((byte) => parseInt(byte, 16)).join(".");
  const ip = words.length === 1 ? ipv4(words[0])
    : words.slice(0, 3).join("") === "00000000000000000000ffff" ? ipv4(words[3])
    : words.join("").match(/.{4}/g).join(":");
  return `${ip}:${parseInt(port, 16)}`;
}
