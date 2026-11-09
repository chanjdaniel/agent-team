// The prod-mongo toolkit's server as Claude Code starts it from toolkits/prod-mongo/.mcp.json,
// with op stubbed (helpers/op), a throwaway MongoDB 8.0 (helpers/mongo.mjs) in place of
// production, a second one to restore its dumps into, and the lock's Database Tools from the
// test's own PATH (CI's toolkits job installs them into ~/.local/bin). A spy mongodump first on the
// server's PATH records the argument list and environment the server starts it with, then runs the
// real one; files in its directory make it hold after the dump, or lose a collection's documents.
// Every backups folder lives under ~/.cache/agent-team-tests/, since a dump of real data is never
// kept in a temporary directory, and is removed when the file exits.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, constants, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";
import { roomRefusal, stampOf } from "../../servers/prod-mongo/backup.mjs";
import { childEnv, scrubber } from "../../servers/prod-mongo/children.mjs";
import { opStub, repoRoot, startToolkitServer, stubDir, tempDir, testPath } from "./helpers/mcp.mjs";
import { startMongo } from "./helpers/mongo.mjs";
import { assertNoLeak, launcherRefusalTests } from "./helpers/toolkit.mjs";

const reference = "op://agent-team/conventioner-prod-read/uri";
// The read user's password, which every connection string the op stub prints carries.
const marker = `pwmarker${randomBytes(8).toString("hex")}`;
const email = `vendor-${randomBytes(4).toString("hex")}@example.com`;

// The lock's Database Tools, from this run's PATH.
const toolsDir = (process.env.PATH ?? "").split(delimiter).find((dir) => {
  try {
    accessSync(join(dir, "mongodump"), constants.X_OK);
    accessSync(join(dir, "mongorestore"), constants.X_OK);
    return true;
  } catch {
    return false;
  }
});
if (!toolsDir) throw new Error("mongodump and mongorestore are not on PATH: install the lock's Database Tools (bin/lib/tools.jq's download_sources)");
if (existsSync(join(toolsDir, "op"))) throw new Error(`a real op is beside mongodump, in ${toolsDir}`);
const mongodumpVersion = /^mongodump version: (\S+)$/m.exec(execFileSync(join(toolsDir, "mongodump"), ["--version"], { encoding: "utf8" }))[1];

// Every backups folder and test HOME lives here, under the developer's own home.
const testRoot = join(homedir(), ".cache", "agent-team-tests", `prod-mongo-${randomBytes(6).toString("hex")}`);
mkdirSync(testRoot, { recursive: true, mode: 0o700 });
process.on("exit", () => rmSync(testRoot, { recursive: true, force: true }));
let homes = 0;
const newHome = () => {
  const dir = join(testRoot, `home-${(homes += 1)}`);
  mkdirSync(dir, { mode: 0o700 });
  return dir;
};

// The spy mongodump: it records its argument list, its environment and the kind of file its
// --config names, then runs the real one; with `hold` it waits after the dump until `go` exists,
// and with `lose` (a collection's name) it empties that collection's dump. It runs no command the
// helpers spy on (cat, head, hostname).
function spyMongodump() {
  const dir = tempDir("mongodump-spy");
  const linux = process.platform === "linux";
  writeFileSync(join(dir, "mongodump"), `#!/bin/sh
dir='${dir}'
real='${join(toolsDir, "mongodump")}'
[ "$1" = --version ] && exec "$real" "$@"
${linux ? `tr '\\0' '\\n' </proc/$$/cmdline >"$dir/cmdline"
tr '\\0' '\\n' </proc/$$/environ >"$dir/environ"` : `ps -ww -o command= -p $$ >"$dir/cmdline"
ps -E -ww -o command= -p $$ >"$dir/environ"`}
config=\${1#--config=}
if [ -p "$config" ]; then echo fifo >"$dir/config-kind"; else echo other >"$dir/config-kind"; fi
"$real" "$@"
status=$?
if [ -f "$dir/lose" ]; then
  read -r lost <"$dir/lose"
  : | gzip >"$(dirname "$config")/dump/conventioner/$lost.bson.gz"
fi
if [ -f "$dir/hold" ]; then
  : >"$dir/held"
  while [ ! -f "$dir/go" ]; do sleep 0.1; done
fi
exit $status
`, { mode: 0o755 });
  const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : null);
  return { dir, read, set: (name, text = "") => writeFileSync(join(dir, name), text) };
}

const serverPath = (spy) => (options) => [spy?.dir, toolsDir, testPath(options)].filter(Boolean).join(":");

let production;
let target;
let targetUri;
let home;
let root;
let spy;

before(async () => {
  [production, target] = await Promise.all([startMongo(), startMongo()]);
  await production.createUser("ops-read", marker, [{ role: "read", db: "conventioner" }]);
  const restorer = `restorer${randomBytes(6).toString("hex")}`;
  await target.createUser("restorer", restorer, [{ role: "root", db: "admin" }]);
  targetUri = target.uri("restorer", restorer);
});

after(async () => {
  await Promise.all([production?.stop(), target?.stop()]);
});

beforeEach(async () => {
  await seed();
  home = newHome();
  root = join(home, "conventioner-backups");
  spy = spyMongodump();
});

// "Production": a collection with a unique index, one of nested documents, an empty one, a view,
// and one keyed by an email address.
async function seed() {
  await production.seed("conventioner", {
    markets: [
      { name: "Riverside Night Market", city: "Vancouver", stalls: 40 },
      { name: "Harbour Craft Fair", city: "Victoria", stalls: 25 },
      { name: "Lakeside Summer Market", city: "Kelowna", stalls: 15 },
    ],
    applications: Array.from({ length: 5 }, (_, n) => ({
      vendor: { name: `Vendor ${n}`, contact: { phone: `555-010${n}` } },
      booths: [{ size: "10x10", power: n % 2 === 0 }],
    })),
    accounts: [{ _id: email, role: "vendor" }, { _id: `other-${email}`, role: "admin" }],
  });
  const db = production.client.db("conventioner");
  await db.collection("markets").createIndex({ name: 1 }, { unique: true, name: "name_unique" });
  await db.createCollection("archived");
  await db.createCollection("open_markets", { viewOn: "markets", pipeline: [{ $match: { stalls: { $gte: 20 } } }] });
}

async function withServer(body, { value = production.uri("ops-read", marker) } = {}) {
  const op = opStub({ value });
  const server = startToolkitServer("prod-mongo", { home, opDir: op.dir, path: serverPath(spy)(), env: { PROD_MONGO_ROOT: root } });
  try {
    await server.initialize();
    await body(server, op);
  } finally {
    await server.close();
    assertNoLeak(server, { marker, home });
  }
}

const backups = () => (existsSync(root) ? readdirSync(root) : []);

// Every path under `dir`, files and directories, with its lstat.
function walk(dir) {
  return readdirSync(dir, { recursive: true }).map((name) => ({ path: join(dir, name), stat: lstatSync(join(dir, name)) }));
}

async function collectionsOf(client) {
  const db = client.db("conventioner");
  const listed = await db.listCollections().toArray();
  const out = {};
  for (const { name, type } of listed.filter(({ name }) => !name.startsWith("system."))) {
    if (type === "view") {
      out[name] = { type };
      continue;
    }
    const indexes = (await db.collection(name).indexes()).map((index) => index.name).sort();
    out[name] = { type, documents: await db.collection(name).countDocuments({}), indexes };
  }
  return out;
}

test("the MCP config names one server, prod-mongo, with no secret, no env and a timeout past the longest call", () => {
  const config = JSON.parse(readFileSync(join(repoRoot, "toolkits", "prod-mongo", ".mcp.json"), "utf8"));
  assert.deepEqual(Object.keys(config.mcpServers), ["prod-mongo"]);
  const { command, args, env, timeout } = config.mcpServers["prod-mongo"];
  assert.equal(command, "node");
  assert.deepEqual(args, ["@TEAM_CODE@/toolkits/prod-mongo/scripts/start-server.mjs"]);
  assert.equal(env, undefined);
  // A rehearsal may wait 20 minutes for the heavy-run lock, then run 45: past Claude Code's
  // 30-minute idle timeout for a stdio call.
  assert.equal(timeout, 90 * 60_000);
});

test("no file of the toolkit or its server is executable", () => {
  for (const dir of [join(repoRoot, "toolkits", "prod-mongo"), join(repoRoot, "servers", "prod-mongo")]) {
    for (const { path, stat } of walk(dir)) {
      if (stat.isFile()) assert.equal(stat.mode & 0o111, 0, `${path} is executable`);
    }
  }
});

test("the tools are backup alone, taking no input", async () => {
  await withServer(async (server) => {
    const tools = await server.listTools();
    assert.deepEqual(tools.map((tool) => tool.name), ["backup"]);
    assert.deepEqual(tools[0].inputSchema, { type: "object", properties: {}, additionalProperties: false });
  });
});

describe("backup", () => {
  test("takes a verified dump into a 0700 folder named for its UTC start, and answers its counts from ~/", async () => {
    const start = Date.now();
    let text;
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
    });
    const [stamp] = backups();
    assert.deepEqual(backups(), [stamp]);
    assert.match(stamp, /^\d{4}-\d{2}-\d{2}T\d{6}Z$/);
    const startedAt = Date.parse(`${stamp.slice(0, 13)}:${stamp.slice(13, 15)}:${stamp.slice(15, 17)}Z`);
    assert.ok(Math.abs(startedAt - start) < 60_000, `${stamp} is not the call's start`);

    const lines = text.split("\n");
    assert.match(lines[0], new RegExp(`^Backup taken: ~/conventioner-backups/${stamp} \\(\\d+(\\.\\d)? (B|KiB|MiB) on disk, \\d+ s\\), mongodump ${mongodumpVersion.replaceAll(".", "\\.")}$`));
    assert.equal(lines[1], "4 collections and 1 view, 10 documents, each matching the database's count:");
    assert.deepEqual(lines.slice(2), [
      "- accounts: 2 documents",
      "- applications: 5 documents",
      "- archived: 0 documents",
      "- markets: 3 documents",
      "- open_markets: a view, its definition only",
    ]);
    assert.ok(!text.includes(home) && !text.includes(homedir()), "the answer names an absolute path");
    assert.ok(!text.includes(email), "the answer holds a document's id");

    const folder = join(root, stamp);
    assert.equal(statSync(root).mode & 0o777, 0o700);
    for (const { path, stat } of [{ path: folder, stat: statSync(folder) }, ...walk(folder)]) {
      if (stat.isDirectory()) assert.equal(stat.mode & 0o777, 0o700, path);
      else {
        assert.ok(stat.isFile(), `${path} is neither a file nor a directory`);
        assert.equal(stat.mode & 0o777, 0o600, path);
      }
    }

    const manifestText = readFileSync(join(folder, "manifest.json"), "utf8");
    const manifest = JSON.parse(manifestText);
    assert.equal(manifest.database, "conventioner");
    assert.equal(manifest.verified, true);
    assert.equal(manifest.mongodump, mongodumpVersion);
    assert.match(manifest.server, /^8\.0\./);
    assert.ok(Date.parse(manifest.ended) >= Date.parse(manifest.started));
    assert.deepEqual(
      manifest.collections.map(({ name, type, before, after, dumped, judgement, indexes }) => ({ name, type, before, after, dumped, judgement, indexes })),
      [
        { name: "accounts", type: "collection", before: 2, after: 2, dumped: 2, judgement: "match", indexes: ["_id_"] },
        { name: "applications", type: "collection", before: 5, after: 5, dumped: 5, judgement: "match", indexes: ["_id_"] },
        { name: "archived", type: "collection", before: 0, after: 0, dumped: 0, judgement: "match", indexes: ["_id_"] },
        { name: "markets", type: "collection", before: 3, after: 3, dumped: 3, judgement: "match", indexes: ["_id_", "name_unique"] },
        { name: "open_markets", type: "view", before: null, after: null, dumped: null, judgement: "match", indexes: [] },
      ],
    );
    for (const { name, type, bytes } of manifest.collections) {
      if (type === "collection") assert.ok(bytes > 0, `${name} has no bytes`);
    }
    assert.deepEqual({ ...manifest.totals, bytes: manifest.totals.bytes > 0 }, { collections: 4, views: 1, documents: 10, bytes: true });
    for (const hidden of [marker, "127.0.0.1", String(production.port), email, "Riverside"]) {
      assert.ok(!manifestText.includes(hidden), `the manifest holds ${hidden}`);
    }
  });

  test("restores into another MongoDB with every collection's count and index names, the view and the empty collection included", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
    });
    const [stamp] = backups();
    await target.client.db("conventioner").dropDatabase();
    execFileSync(join(toolsDir, "mongorestore"), [`--uri=${targetUri}`, "--nsInclude", "conventioner.*", "--gzip", "--dir", join(root, stamp, "dump"), "--quiet"], { stdio: "pipe" });
    const restored = await collectionsOf(target.client);
    assert.deepEqual(restored, await collectionsOf(production.client));
    assert.deepEqual(Object.keys(restored).sort(), ["accounts", "applications", "archived", "markets", "open_markets"]);
    assert.equal(restored.open_markets.type, "view");
  });

  test("gives mongodump the connection string only through a FIFO, gone after the call, and writes it nowhere", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
    });
    const cmdline = spy.read("cmdline");
    const environ = spy.read("environ");
    assert.ok(cmdline && environ, "the spy did not run");
    for (const [what, text] of [["argument list", cmdline], ["environment", environ]]) {
      assert.ok(!text.includes(marker), `the password is in mongodump's ${what}`);
      assert.ok(!text.includes("ops-read"), `the user is in mongodump's ${what}`);
      assert.doesNotMatch(text, /mongodb(\+srv)?:\/\//, `a connection string is in mongodump's ${what}`);
      assert.ok(!text.includes(`127.0.0.1:${production.port}`), `the host is in mongodump's ${what}`);
    }
    assert.match(cmdline, /--config=\S*\/\.\d{4}-\d{2}-\d{2}T\d{6}Z\.partial\/config\.fifo/);
    assert.equal(spy.read("config-kind"), "fifo\n");
    // childEnv's variables, no more: the spy's sh adds PWD (and macOS's ps the rest of its line).
    if (process.platform === "linux") {
      const names = environ.split("\n").filter(Boolean).map((line) => line.split("=")[0]).filter((name) => name !== "PWD");
      assert.deepEqual(names.sort(), ["HOME", "PATH"]);
    }
    for (const { path, stat } of walk(root)) {
      assert.ok(!stat.isFIFO(), `${path} is a FIFO`);
      assert.ok(!path.endsWith("config.fifo"), `${path} is left`);
    }
    for (const dir of [home, join(repoRoot, "toolkits", "prod-mongo"), join(repoRoot, "servers", "prod-mongo")]) {
      for (const { path, stat } of walk(dir)) {
        if (stat.isFile()) assert.ok(!readFileSync(path).includes(marker), `${path} holds the password`);
      }
    }
  });

  test("reports a collection written during the dump as changed, with its counts before and after", async () => {
    spy.set("hold");
    await withServer(async (server) => {
      const call = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      await production.client.db("conventioner").collection("accounts").insertOne({ _id: `late-${email}`, role: "vendor" });
      spy.set("go");
      const result = await call;
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /each matching the database's count, but 1 changed during the dump:/);
      assert.match(result.text, /^- accounts: 2 documents, changed during the dump \(2 before, 3 after\)$/m);
    });
    const [stamp] = backups();
    const manifest = JSON.parse(readFileSync(join(root, stamp, "manifest.json"), "utf8"));
    const accounts = manifest.collections.find(({ name }) => name === "accounts");
    assert.deepEqual([accounts.before, accounts.after, accounts.dumped, accounts.judgement], [2, 3, 2, "changed"]);
  });

  test("fails a dump short of documents, naming the collection, and leaves no folder", async () => {
    spy.set("lose", "markets\n");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text.split("\n").length, 1, result.text);
      assert.match(result.text, /^backup: failed: the dump does not match the database, so it was removed: markets has 0 in the dump, 3 in the database before and after$/);
      for (const hidden of ["127.0.0.1", String(production.port), "ops-read"]) assert.ok(!result.text.includes(hidden), hidden);
    });
    assert.deepEqual(backups(), []);
  });

  test("refuses a second backup while one runs", async () => {
    spy.set("hold");
    await withServer(async (server) => {
      const first = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      const second = await server.callTool("backup", {});
      assert.equal(second.isError, true);
      assert.equal(second.text, "backup: a backup is already running");
      spy.set("go");
      assert.ok(!(await first).isError);
    });
    assert.equal(backups().length, 1);
  });

  test("refuses any input", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", { root: "/tmp" });
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: takes no root");
    });
    assert.deepEqual(backups(), []);
  });

  test("fails in one line naming neither the host nor the secret when the database is unreachable", async () => {
    const value = `mongodb://ops-read:${marker}@127.0.0.1:1/?authSource=admin&serverSelectionTimeoutMS=2000`;
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: failed: could not reach the database");
    }, { value });
    assert.deepEqual(backups(), []);
  });

  test("refuses a root that is a file", async () => {
    mkdirSync(dirname(root), { recursive: true });
    writeFileSync(root, "");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: failed: ~/conventioner-backups is not a directory");
    });
    assert.equal(statSync(root).isFile(), true);
  });
});

describe("the launcher refuses before the server starts", () => {
  launcherRefusalTests("prod-mongo", () => ({ value: production.uri("ops-read", marker), home, marker }), { path: serverPath() });

  test("when mongodump is not on PATH, before any op call", async () => {
    const op = opStub({ value: production.uri("ops-read", marker) });
    const server = startToolkitServer("prod-mongo", { home, opDir: op.dir, path: [stubDir, dirname(process.execPath)].join(":") });
    try {
      await assert.rejects(server.initialize(), /server exited \(1\)/);
    } finally {
      await server.close();
    }
    assert.equal(server.stderr, "prod-mongo: mongodump is not installed: team-doctor names the install\n");
    assert.deepEqual(op.calls(), []);
    assertNoLeak(server, { marker, home });
  });
});

describe("the server's rules", () => {
  test("a stamp is the UTC start to the second", () => {
    assert.equal(stampOf(new Date("2026-11-08T14:23:05.987Z")), "2026-11-08T142305Z");
  });

  test("a dump needs 1 GiB plus twice the database's data free", () => {
    const gib = 1024 ** 3;
    assert.equal(roomRefusal(gib + 2 * 100, 100), undefined);
    assert.equal(
      roomRefusal(gib, 512 * 1024 ** 2),
      "the backups folder's disk has 1.0 GiB free, less than the 2.0 GiB a dump needs (1 GiB plus twice the database's 512.0 MiB of data)",
    );
  });

  test("scrubbed drops every connection string, the secret's parts and hosts, and anything from a {", () => {
    const value = "mongodb+srv://ops:p%40ss-word@cluster0.example.mongodb.net/?retryWrites=true";
    const scrubbed = scrubber(value);
    assert.equal(scrubbed(`failed to connect to ${value}`), "failed to connect to [uri]");
    assert.equal(scrubbed("auth failed for p@ss-word at cluster0.example.mongodb.net: {\"doc\":1}"), "auth failed for [redacted] at [redacted]:");
    assert.equal(scrubbed("x".repeat(300)).length, 200);
  });

  test("childEnv passes its list and the extras, never the rest", () => {
    const saved = { ...process.env };
    try {
      Object.assign(process.env, { TEAM_HEAVY_HELD: "1", AGENT_TEAM_TASK: "T1", SECRET_THING: "no" });
      const env = childEnv({ EXTRA: "yes" });
      assert.equal(env.TEAM_HEAVY_HELD, "1");
      assert.equal(env.AGENT_TEAM_TASK, "T1");
      assert.equal(env.EXTRA, "yes");
      assert.equal(env.SECRET_THING, undefined);
      for (const key of Object.keys(env)) {
        assert.ok(["PATH", "HOME", "LANG", "AGENT_TEAM_TASK", "TEAM_HEAVY_HELD", "DOCKER_HOST", "DOCKER_CONTEXT", "EXTRA"].includes(key), key);
      }
    } finally {
      for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
      Object.assign(process.env, saved);
    }
  });
});

async function until(check, timeoutMs = 60_000) {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > timeoutMs) throw new Error("timed out waiting");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
