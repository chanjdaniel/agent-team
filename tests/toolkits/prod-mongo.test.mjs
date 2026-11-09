// The prod-mongo toolkit's server as Claude Code starts it from toolkits/prod-mongo/.mcp.json,
// with op stubbed (helpers/op), a throwaway MongoDB 8.0 (helpers/mongo.mjs) in place of
// production, a second one to restore its dumps into, and the lock's Database Tools from the
// test's own PATH (CI's toolkits job installs them into ~/.local/bin). A spy mongodump first on the
// server's PATH records the argument list and environment the server starts it with, then runs the
// real one; files in its directory make it hold after the dump, or lose a collection's documents.
// Every backups folder lives under ~/.cache/agent-team-tests/, since a dump of real data is never
// kept in a temporary directory, and is removed when the file exits.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, chmodSync, constants, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";
import { roomRefusal, stampOf } from "../../servers/prod-mongo/backup.mjs";
import { childEnv, scrubber } from "../../servers/prod-mongo/children.mjs";
import { humanBytes } from "../../servers/prod-mongo/dump.mjs";
import { restoreLimit } from "../../servers/prod-mongo/drill.mjs";
import { kept } from "../../servers/prod-mongo/list.mjs";
import { destinationRefusal, dumpByStamp } from "../../servers/prod-mongo/root.mjs";
import { perThreadCaches as throwawayCaches, startThrowaway, teamLabel, throwawayImage, throwawayName } from "../../servers/prod-mongo/throwaway.mjs";
import { opStub, repoRoot, startToolkitServer, stubDir, tempDir, testPath } from "./helpers/mcp.mjs";
import { mongoImage, perThreadCaches, startMongo } from "./helpers/mongo.mjs";
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

// A connection string no call can reach: a tool that answers with it read no database, and a
// refusal given with it came before any connection.
const unreachable = () => `mongodb://ops-read:${marker}@127.0.0.1:1/?authSource=admin&serverSelectionTimeoutMS=2000`;

async function withServer(body, { value = production.uri("ops-read", marker), env = {}, path = serverPath(spy)() } = {}) {
  const op = opStub({ value });
  const server = startToolkitServer("prod-mongo", { home, opDir: op.dir, path, env: { PROD_MONGO_ROOT: root, ...env } });
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

test("the tools are backup and list-backups, taking no input, and restore-drill, taking a backup's name or nothing", async () => {
  await withServer(async (server) => {
    const tools = await server.listTools();
    assert.deepEqual(tools.map((tool) => tool.name), ["backup", "list-backups", "restore-drill"]);
    for (const tool of tools.slice(0, 2)) assert.deepEqual(tool.inputSchema, { type: "object", properties: {}, additionalProperties: false }, tool.name);
    assert.equal(tools[1].annotations.readOnlyHint, true);
    const { inputSchema } = tools[2];
    assert.deepEqual(Object.keys(inputSchema.properties), ["backup"]);
    assert.equal(inputSchema.properties.backup.type, "string");
    assert.equal(inputSchema.required, undefined);
    assert.equal(inputSchema.additionalProperties, false);
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
    assert.match(lines.at(-1), /^The folder holds 1 dump \(\d+(\.\d)? (B|KiB|MiB)\); the newest 5 are kept, none is past that\.$/);
    assert.deepEqual(lines.slice(2, -1), [
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
      // list-backups takes no lock, and names the running backup's folder for what it is.
      const listed = await server.callTool("list-backups", {});
      assert.ok(!listed.isError, listed.text);
      assert.match(listed.text, /^- \.\d{4}-\d{2}-\d{2}T\d{6}Z\.partial: .*, being written by the backup running now$/m);
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
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: failed: could not reach the database");
    }, { value: unreachable() });
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

describe("the backups root", () => {
  // Each rule refuses backup and list-backups alike, with its reason, before any connection (the
  // database is unreachable, so a connection would have failed with that instead), and makes nothing.
  async function refused(expected, { env = {} } = {}) {
    await withServer(async (server) => {
      for (const tool of ["backup", "list-backups"]) {
        const result = await server.callTool(tool, {});
        assert.equal(result.isError, true, result.text);
        if (expected instanceof RegExp) assert.match(result.text, new RegExp(`^${tool}: failed: ${expected.source}$`));
        else assert.equal(result.text, `${tool}: failed: ${expected}`);
      }
    }, { value: unreachable(), env });
    assert.equal(spy.read("cmdline"), null, "mongodump ran");
  }
  const dir = (...parts) => {
    const path = join(home, ...parts);
    mkdirSync(path, { recursive: true });
    return path;
  };

  test("refuses one inside a git checkout", async () => {
    dir("repo", ".git");
    root = join(home, "repo", "backups");
    await refused("the backups folder ~/repo/backups is inside a git checkout: ~/repo holds .git");
    assert.equal(existsSync(root), false);
  });

  test("refuses one inside a linked worktree, whose .git is a file", async () => {
    dir("worktree");
    writeFileSync(join(home, "worktree", ".git"), "gitdir: /elsewhere\n");
    root = join(home, "worktree", "deep", "backups");
    await refused("the backups folder ~/worktree/deep/backups is inside a git checkout: ~/worktree holds .git");
    assert.equal(existsSync(join(home, "worktree", "deep")), false);
  });

  test("refuses a symlinked root whose real path is inside a checkout, made or not", async () => {
    dir("repo", ".git");
    dir("repo", "made");
    symlinkSync(join(home, "repo", "made"), join(home, "made-link"));
    symlinkSync(join(home, "repo", "not-yet"), join(home, "dangling-link"));
    for (const link of ["made-link", "dangling-link"]) {
      root = join(home, link);
      await refused(`the backups folder ~/${link} is inside a git checkout: ~/repo holds .git`);
    }
    assert.equal(existsSync(join(home, "repo", "not-yet")), false);
  });

  test("takes a symlinked root whose real path passes, and answers from the path as given", async () => {
    dir("elsewhere");
    symlinkSync(join(home, "elsewhere"), join(home, "link"));
    root = join(home, "link");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /^Backup taken: ~\/link\/\d{4}-\d{2}-\d{2}T\d{6}Z /);
    });
    assert.equal(readdirSync(join(home, "elsewhere")).length, 1);
  });

  test("refuses one inside the team home, named by TEAM_HOME or by the setting, even with no .git", async () => {
    dir("records");
    root = join(home, "records", "backups");
    await refused("the backups folder ~/records/backups is inside the team home, ~/records", { env: { TEAM_HOME: join(home, "records") } });
    dir(".config", "agent-team");
    writeFileSync(join(home, ".config", "agent-team", "home"), "records\n");
    await refused("the backups folder ~/records/backups is inside the team home, ~/records");
  });

  test("refuses one inside ~/.claude or ~/.no-mistakes", async () => {
    root = join(home, ".claude", "jobs", "backups");
    await refused("the backups folder ~/.claude/jobs/backups is inside ~/.claude, Claude Code's own folder of transcripts and jobs");
    root = join(home, ".no-mistakes", "backups");
    await refused("the backups folder ~/.no-mistakes/backups is inside ~/.no-mistakes, the gate's own folder of worktrees");
  });

  test("refuses one inside a shared temporary directory, TMPDIR or XDG_RUNTIME_DIR", async () => {
    root = join(tempDir("root"), "backups");
    await refused(/the backups folder \/\S+ is inside a shared temporary directory, \/(tmp|var\/folders|private\/\S+)/);
    root = join(dir("scratch"), "backups");
    await refused("the backups folder ~/scratch/backups is inside a shared temporary directory, ~/scratch", { env: { TMPDIR: join(home, "scratch") } });
    await refused("the backups folder ~/scratch/backups is inside a shared temporary directory, ~/scratch", { env: { XDG_RUNTIME_DIR: join(home, "scratch") } });
  });

  test("refuses one inside a synced folder, by its name or a sync client's marker", async () => {
    root = join(home, "Dropbox", "backups");
    await refused("the backups folder ~/Dropbox/backups is inside a synced folder, ~/Dropbox");
    dir("shared");
    writeFileSync(join(home, "shared", ".stfolder"), "");
    root = join(home, "shared", "backups");
    await refused("the backups folder ~/shared/backups is inside a synced folder: ~/shared holds .stfolder");
  });

  test("refuses one inside a CI workspace", async () => {
    root = join(dir("workspace"), "backups");
    await refused("the backups folder ~/workspace/backups is inside a CI workspace, GITHUB_WORKSPACE (~/workspace)", { env: { GITHUB_WORKSPACE: join(home, "workspace") } });
  });

  test("refuses the home itself and a relative path", async () => {
    root = home;
    await refused("the backups folder ~ is the home directory itself");
    root = "conventioner-backups";
    await refused("the backups folder conventioner-backups is not an absolute path");
  });

  test("sets a looser root to 0700 and says so once", async () => {
    mkdirSync(root);
    chmodSync(root, 0o755);
    await withServer(async (server) => {
      const first = await server.callTool("backup", {});
      assert.ok(!first.isError, first.text);
      const lines = first.text.split("\n");
      assert.equal(lines.at(-2), "~/conventioner-backups was mode 0755, open to others, so it is now 0700, yours alone.");
      assert.match(lines.at(-1), /^The folder holds 1 dump /);
      assert.equal(statSync(root).mode & 0o777, 0o700);
      const again = await server.callTool("list-backups", {});
      assert.ok(!again.isError, again.text);
      assert.doesNotMatch(again.text, /was mode/);
      chmodSync(root, 0o750);
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, /^~\/conventioner-backups was mode 0750, open to others, so it is now 0700, yours alone\.$/m);
      assert.equal(statSync(root).mode & 0o777, 0o700);
    });
  });
});

describe("list-backups", () => {
  const sized = (text) => text.replaceAll(/\d+(\.\d)? (B|KiB|MiB)/g, "<size>");

  test("says the root does not exist yet, and makes nothing", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("list-backups", {});
      assert.ok(!result.isError, result.text);
      assert.equal(result.text, "~/conventioner-backups does not exist yet, so it holds no dumps.\nThe folder holds no dumps; the newest 5 are kept.");
    }, { value: unreachable() });
    assert.equal(existsSync(root), false);
  });

  test("lists verified dumps newest first with what was derived from them, the other entries apart, and those past the rule", async () => {
    await withServer(async (server) => {
      assert.ok(!(await server.callTool("backup", {})).isError);
    });
    const [taken] = backups();
    // Five older copies of it, verified, and one whose manifest is not.
    const older = ["2025-01-01T000000Z", "2025-01-02T000000Z", "2025-01-03T000000Z", "2025-01-04T000000Z", "2025-01-05T000000Z"];
    for (const stamp of older) cpSync(join(root, taken), join(root, stamp), { recursive: true });
    cpSync(join(root, taken), join(root, "2025-06-01T000000Z"), { recursive: true });
    const unverified = join(root, "2025-06-01T000000Z", "manifest.json");
    writeFileSync(unverified, JSON.stringify({ ...JSON.parse(readFileSync(unverified, "utf8")), verified: false }));
    // What later tools derive from a dump, in its folder.
    const derived = (...parts) => join(root, taken, ...parts);
    mkdirSync(derived("drills"));
    writeFileSync(derived("drills", "2026-01-01T100000Z.json"), JSON.stringify({ verdict: "FAIL" }));
    writeFileSync(derived("drills", "2026-01-01T110000Z.json"), JSON.stringify({ verdict: "PASS" }));
    mkdirSync(derived("rehearsals", "2026-01-01T120000Z"), { recursive: true });
    mkdirSync(derived("undo", "2026-01-01T130000Z"), { recursive: true });
    mkdirSync(derived("undo", "2026-01-01T140000Z"), { recursive: true });
    mkdirSync(derived("diffs"));
    writeFileSync(derived("diffs", "2025-01-05T000000Z.json"), "{}");
    // Daniel's own dump, one a killed server left, a stamp-named folder with no manifest, a file.
    mkdirSync(join(root, "hand-dump"));
    writeFileSync(join(root, "hand-dump", "markets.bson"), "hand-made");
    mkdirSync(join(root, ".2025-02-01T000000Z.partial"));
    writeFileSync(join(root, ".2025-02-01T000000Z.partial", "x"), "part");
    mkdirSync(join(root, "2025-03-01T000000Z"));
    writeFileSync(join(root, "notes.txt"), "mine");

    spy = spyMongodump();
    let text;
    await withServer(async (server) => {
      const result = await server.callTool("list-backups", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
    }, { value: unreachable() });
    assert.equal(spy.read("cmdline"), null, "mongodump ran");
    const summary = "4 collections and 1 view, 10 documents, <size>";
    const plain = "0 drills, 0 rehearsals, 0 undos, 0 diffs";
    assert.deepEqual(sized(text).split("\n"), [
      "~/conventioner-backups holds 7 dumps taken by this toolkit, newest first:",
      `- ${taken}: ${summary}, verified; 2 drills (newest PASS), 1 rehearsal, 2 undos, 1 diff`,
      `- 2025-06-01T000000Z: ${summary}, not verified; ${plain}`,
      ...older.toReversed().map((stamp) => `- ${stamp}: ${summary}, verified; ${plain}`),
      "4 other entries:",
      "- .2025-02-01T000000Z.partial: <size>, left unfinished",
      "- 2025-03-01T000000Z: <size>, not taken by this toolkit",
      "- hand-dump: <size>, not taken by this toolkit",
      "- notes.txt: <size>, not taken by this toolkit",
      "In all, <size>.",
      `The folder holds 7 dumps (<size>); the newest ${kept} are kept, so 2 are past that, for Daniel to delete by hand: 2025-06-01T000000Z (not verified), 2025-01-01T000000Z.`,
    ]);
    const total = walk(root).reduce((sum, { stat }) => sum + (stat.isFile() ? stat.size : 0), 0);
    assert.ok(text.includes(`\nIn all, ${humanBytes(total)}.\n`), text);
    assert.match(text, /^- hand-dump: 9 B, not taken by this toolkit$/m);
    assert.ok(!text.includes(home) && !text.includes(email), text);
    // The toolkit never deletes a dump.
    assert.equal(backups().length, 11);
  });

  test("backup's answer names the dumps past the rule too", async () => {
    mkdirSync(root, { mode: 0o700 });
    const old = ["2025-01-01T000000Z", "2025-01-02T000000Z", "2025-01-03T000000Z", "2025-01-04T000000Z", "2025-01-05T000000Z"];
    for (const stamp of old) {
      mkdirSync(join(root, stamp));
      writeFileSync(join(root, stamp, "manifest.json"), JSON.stringify({ verified: true, totals: { collections: 1, views: 0, documents: 1 } }));
    }
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      assert.match(result.text.split("\n").at(-1), /^The folder holds 6 dumps \(\S+ \S+\); the newest 5 are kept, so 1 is past that, for Daniel to delete by hand: 2025-01-01T000000Z\.$/);
    });
  });
});

describe("restore-drill", () => {
  const realDocker = (process.env.PATH ?? "").split(delimiter).map((dir) => join(dir, "docker")).find((path) => existsSync(path));
  const { MongoClient } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");
  const environOf = process.platform === "linux" ? "tr '\\0' '\\n' </proc/$$/environ" : "ps -E -ww -o command= -p $$";
  const cmdlineOf = process.platform === "linux" ? "tr '\\0' '\\n' </proc/$$/cmdline" : "ps -ww -o command= -p $$";

  // The spy docker: each call's arguments, one per line and ended by "--- end", in `calls`, and
  // the environment `docker run` starts with, in `run-environ`; then the real docker, but for
  // `docker port`, which fails while `fail-port` exists.
  function spyDocker() {
    const dir = tempDir("docker-spy");
    writeFileSync(join(dir, "docker"), `#!/bin/sh
dir='${dir}'
{ printf '%s\\n' "$@"; echo '--- end'; } >>"$dir/calls"
if [ "$1" = run ]; then ${environOf} >"$dir/run-environ"; fi
if [ "$1" = port ] && [ -f "$dir/fail-port" ]; then echo 'Error: no port, as the test asked' >&2; exit 1; fi
exec '${realDocker}' "$@"
`, { mode: 0o755 });
    const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "");
    const calls = () => read("calls").split("--- end\n").filter(Boolean).map((call) => call.split("\n").filter(Boolean));
    return { dir, read, calls, set: (name) => writeFileSync(join(dir, name), "") };
  }

  // The spy mongorestore: its argument list, environment and the kind of its --config file, then
  // the real one; with `hold` it waits after the restore until `go` exists or its parent is gone,
  // and with `fail` it then exits 1 with a line naming the throwaway's connection string.
  function spyMongorestore() {
    const dir = tempDir("mongorestore-spy");
    writeFileSync(join(dir, "mongorestore"), `#!/bin/sh
dir='${dir}'
real='${join(toolsDir, "mongorestore")}'
[ "$1" = --version ] && exec "$real" "$@"
${cmdlineOf} >"$dir/cmdline"
${environOf} >"$dir/environ"
config=\${1#--config=}
if [ -p "$config" ]; then echo fifo >"$dir/config-kind"; else echo other >"$dir/config-kind"; fi
"$real" "$@"
status=$?
if [ -f "$dir/hold" ]; then
  : >"$dir/held"
  while [ ! -f "$dir/go" ] && kill -0 $PPID 2>/dev/null; do sleep 0.1; done
fi
if [ -f "$dir/fail" ]; then echo "Failed: restoring into $(sed -n 's/^uri: //p' "$config" 2>/dev/null)mongodb://root:x@127.0.0.1 {\"doc\": 1}" >&2; exit 1; fi
exit $status
`, { mode: 0o755 });
    const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : null);
    return { dir, read, set: (name, text = "") => writeFileSync(join(dir, name), text) };
  }

  let docker;
  let restorer;
  const drillPath = () => [spy.dir, restorer.dir, docker.dir, toolsDir, testPath()].join(":");
  // Under tests/run the heavy-run lock is held, so the server's team-heavy runs the drill at once;
  // run alone, this file holds none, and the drill runs at once all the same (the lock test holds
  // one in the test's HOME).
  const held = { TEAM_HEAVY_HELD: process.env.TEAM_HEAVY_HELD ?? "1" };
  const drillServer = (body, options = {}) => withServer(body, { path: drillPath(), ...options, env: { ...held, ...options.env } });
  beforeEach(() => {
    docker = spyDocker();
    restorer = spyMongorestore();
  });

  async function takeBackup() {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
    });
    return backups().filter((name) => /^\d{4}-\d{2}-\d{2}T\d{6}Z$/.test(name)).sort().at(-1);
  }
  const gone = (name) => {
    const inspected = spawnSync(realDocker, ["container", "inspect", name], { encoding: "utf8" });
    return inspected.status !== 0 && /no such (container|object)/i.test(inspected.stderr);
  };
  const timed = (text) => text.replace(/: (PASS|FAIL) in \d+( min \d+)? s, /, ": $1 in <time>, ");
  const drillsOf = (stamp) => (existsSync(join(root, stamp, "drills")) ? readdirSync(join(root, stamp, "drills")) : []);

  test("the throwaway's image and its environment are the test helpers' own", () => {
    assert.equal(throwawayImage, mongoImage);
    assert.deepEqual(throwawayCaches, perThreadCaches);
  });

  // The rehearsal's form: the throwaway on the default bridge and on the caller's network too.
  test("the throwaway is a loopback-only, tmpfs, 2 GiB, self-ending --rm container that joins a network under an alias", async () => {
    const network = `prod-mongo-test-${randomBytes(4).toString("hex")}`;
    execFileSync(realDocker, ["network", "create", "--internal", network], { stdio: "pipe" });
    const name = throwawayName("drill");
    try {
      const throwaway = await startThrowaway({ name, kind: "drill", join: { network, alias: "mongodb" }, MongoClient });
      const [inspected] = JSON.parse(execFileSync(realDocker, ["container", "inspect", name], { encoding: "utf8" }));
      const { HostConfig: host, Config: config } = inspected;
      assert.ok(inspected.NetworkSettings.Networks[network]?.Aliases?.includes("mongodb"), JSON.stringify(inspected.NetworkSettings.Networks));
      assert.ok(inspected.NetworkSettings.Networks.bridge, "not on the default bridge");
      assert.equal(host.AutoRemove, true);
      assert.equal(host.Memory, 2 * 1024 ** 3);
      assert.equal(host.MemorySwap, 2 * 1024 ** 3);
      assert.deepEqual(host.PortBindings, { "27017/tcp": [{ HostIp: "127.0.0.1", HostPort: "" }] });
      assert.deepEqual(Object.keys(host.Tmpfs).sort(), ["/data/configdb", "/data/db"]);
      assert.deepEqual(inspected.Mounts.filter(({ Type }) => Type === "volume"), [], "it has a volume");
      assert.deepEqual(config.Entrypoint, ["timeout"]);
      assert.deepEqual(config.Cmd, ["3600", "docker-entrypoint.sh", "mongod"]);
      assert.equal(config.Labels[teamLabel("toolkit")], "prod-mongo");
      assert.equal(config.Labels[teamLabel("expires")], throwaway.expires);
      await throwaway.client.db("admin").command({ ping: 1 });
      assert.deepEqual(await throwaway.stop(), { gone: true });
      assert.ok(gone(name));
    } finally {
      spawnSync(realDocker, ["rm", "--force", name]);
      spawnSync(realDocker, ["network", "rm", network]);
    }
  });

  test("passes on a backup the test took, records its verdict beside it, and leaves nothing running", async () => {
    const stamp = await takeBackup();
    let text;
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, new RegExp(`^- ${stamp}: .*, verified; 1 drill \\(newest PASS\\), 0 rehearsals, 0 undos, 0 diffs$`, "m"));
    });
    const [file] = drillsOf(stamp);
    assert.deepEqual(drillsOf(stamp), [file]);
    assert.match(file, /^\d{4}-\d{2}-\d{2}T\d{6}Z\.json$/);
    assert.deepEqual(timed(text).split("\n"), [
      `Restore drill of ~/conventioner-backups/${stamp}: PASS in <time>, mongorestore ${mongodumpVersion}`,
      "4 collections and 1 view, 10 documents, each collection's count and index names as its manifest gives them.",
      `Recorded in ~/conventioner-backups/${stamp}/drills/${file}; nothing was left running.`,
    ]);
    assert.equal(statSync(join(root, stamp, "drills")).mode & 0o777, 0o700);
    assert.equal(statSync(join(root, stamp, "drills", file)).mode & 0o777, 0o600);
    const record = JSON.parse(readFileSync(join(root, stamp, "drills", file), "utf8"));
    assert.equal(record.verdict, "PASS");
    assert.equal(record.stamp, stamp);
    assert.equal(record.image, mongoImage);
    assert.deepEqual(record.collections.map(({ name, match }) => [name, match]), [["accounts", true], ["applications", true], ["archived", true], ["markets", true], ["open_markets", true]]);
    assert.deepEqual(record.collections.find(({ name }) => name === "markets").restored, { type: "collection", documents: 3, indexes: ["_id_", "name_unique"] });

    // The throwaway: started once, as the spec says, and gone.
    const runs = docker.calls().filter(([command]) => command === "run");
    assert.equal(runs.length, 1);
    const [run] = runs;
    const name = run[run.indexOf("--name") + 1];
    assert.match(name, /^prod-mongo-drill-[0-9a-f]{12}$/);
    assert.ok(gone(name), `${name} is still there`);
    for (const part of ["--rm", "--detach"]) assert.ok(run.includes(part), part);
    const pairs = run.slice(0, -4).flatMap((arg, n) => (arg.startsWith("--") ? [`${arg} ${run[n + 1]}`] : []));
    for (const pair of [
      "--memory 2g", "--memory-swap 2g", "--publish 127.0.0.1::27017", "--tmpfs /data/db", "--tmpfs /data/configdb",
      "--env GLIBC_TUNABLES=glibc.pthread.rseq=1", "--env MONGO_INITDB_ROOT_USERNAME=root", "--env MONGO_INITDB_ROOT_PASSWORD", "--entrypoint timeout",
      `--label ${teamLabel("owner")}=agent-team`, `--label ${teamLabel("kind")}=drill`, `--label ${teamLabel("toolkit")}=prod-mongo`,
    ]) {
      assert.ok(pairs.includes(pair), `docker run has no ${pair}`);
    }
    assert.deepEqual(run.slice(-4), [mongoImage, "3600", "docker-entrypoint.sh", "mongod"]);
    const expires = Date.parse(pairs.find((pair) => pair.startsWith(`--label ${teamLabel("expires")}=`)).split("=")[1]);
    assert.ok(Math.abs(expires - (Date.parse(record.started) + 3600_000)) < 60_000, "expires is not its start plus an hour");

    // The password: in docker run's own environment, and nowhere else.
    const password = /^MONGO_INITDB_ROOT_PASSWORD=([0-9a-f]{48})$/m.exec(docker.read("run-environ"))?.[1];
    assert.ok(password, "docker run's environment holds no password");
    for (const call of docker.calls()) assert.ok(!call.join(" ").includes(password), `the password is in docker ${call[0]}'s argument list`);
    for (const what of ["cmdline", "environ"]) assert.ok(!restorer.read(what).includes(password), `the password is in mongorestore's ${what}`);
    assert.doesNotMatch(restorer.read("cmdline"), /mongodb:\/\//);
    assert.equal(restorer.read("config-kind"), "fifo\n");
    assert.match(restorer.read("cmdline"), new RegExp(`^--config=\\S*/${stamp}/drills/\\.\\S+\\.config\\.fifo$`, "m"));
    assert.ok(!text.includes(password));
    for (const { path, stat } of walk(home)) {
      assert.ok(!stat.isFIFO(), `${path} is a FIFO`);
      if (stat.isFile()) assert.ok(!readFileSync(path).includes(password), `${path} holds the password`);
    }
  });

  test("fails on a manifest altered to a wrong count, naming the collection, records FAIL and leaves nothing running", async () => {
    const stamp = await takeBackup();
    const path = join(root, stamp, "manifest.json");
    const manifest = JSON.parse(readFileSync(path, "utf8"));
    manifest.collections.find(({ name }) => name === "markets").dumped = 4;
    writeFileSync(path, JSON.stringify(manifest));
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(result.isError, true);
      const [file] = drillsOf(stamp);
      assert.deepEqual(timed(result.text).split("\n"), [
        `Restore drill of ~/conventioner-backups/${stamp}: FAIL in <time>, mongorestore ${mongodumpVersion}`,
        "1 of 5 did not match the manifest:",
        "- markets: 3 documents restored, 4 in its manifest",
        `Recorded in ~/conventioner-backups/${stamp}/drills/${file}; nothing was left running.`,
      ]);
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, new RegExp(`^- ${stamp}: .*; 1 drill \\(newest FAIL\\),`, "m"));
    });
    const [file] = drillsOf(stamp);
    assert.equal(JSON.parse(readFileSync(join(root, stamp, "drills", file), "utf8")).verdict, "FAIL");
    const [run] = docker.calls().filter(([command]) => command === "run");
    assert.ok(gone(run[run.indexOf("--name") + 1]));
  });

  test("fails a dump mongorestore cannot restore, with its scrubbed reason, and removes the throwaway on an error with no verdict", async () => {
    const stamp = await takeBackup();
    restorer.set("fail");
    await drillServer(async (server) => {
      const failed = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(failed.isError, true);
      const lines = timed(failed.text).split("\n");
      assert.equal(lines[0], `Restore drill of ~/conventioner-backups/${stamp}: FAIL in <time>, mongorestore ${mongodumpVersion}`);
      assert.equal(lines[1], "mongorestore exited 1: Failed: restoring into [uri], so the dump did not restore.");
      assert.match(lines.at(-1), /; nothing was left running\.$/);
    });
    assert.equal(drillsOf(stamp).length, 1);
    docker.set("fail-port");
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(result.isError, true);
      assert.equal(
        result.text,
        `restore-drill: failed: docker gave no loopback port for the throwaway MongoDB: Error: no port, as the test asked, so ~/conventioner-backups/${stamp} has no verdict; nothing was left running.`,
      );
    });
    assert.equal(drillsOf(stamp).length, 1, "a Docker failure recorded a verdict");
    const names = docker.calls().filter(([command]) => command === "run").map((run) => run[run.indexOf("--name") + 1]);
    assert.equal(names.length, 2);
    for (const name of names) assert.ok(gone(name), `${name} is still there`);
  });

  test("refuses before Docker is touched: no backup, a stamp not under the root, a dump not verified or too big", async () => {
    await drillServer(async (server) => {
      const none = await server.callTool("restore-drill", {});
      assert.equal(none.text, "restore-drill: failed: ~/conventioner-backups does not exist yet, so it holds no backup to drill");
    });
    const stamp = await takeBackup();
    cpSync(join(root, stamp), join(root, "2025-01-01T000000Z"), { recursive: true });
    const unverified = join(root, "2025-01-01T000000Z", "manifest.json");
    writeFileSync(unverified, JSON.stringify({ ...JSON.parse(readFileSync(unverified, "utf8")), verified: false }));
    cpSync(join(root, stamp), join(root, "2025-02-01T000000Z"), { recursive: true });
    const big = join(root, "2025-02-01T000000Z", "manifest.json");
    const bigManifest = JSON.parse(readFileSync(big, "utf8"));
    writeFileSync(big, JSON.stringify({ ...bigManifest, totals: { ...bigManifest.totals, bytes: restoreLimit + 1 } }));
    const outside = join(home, "elsewhere", stamp);
    cpSync(join(root, stamp), outside, { recursive: true });
    await drillServer(async (server) => {
      for (const [backup, reason] of [
        [outside, `"${outside.slice(0, 40)}..." is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`],
        [`../elsewhere/${stamp}`, `"../elsewhere/${stamp}" is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`],
        ["2024-01-01T000000Z", "~/conventioner-backups holds no backup 2024-01-01T000000Z"],
        ["2025-01-01T000000Z", "~/conventioner-backups/2025-01-01T000000Z has no verified manifest.json, so it is not a dump this toolkit took"],
        ["2025-02-01T000000Z", "~/conventioner-backups/2025-02-01T000000Z is 512.0 MiB, more than the 512.0 MiB a drill restores in memory"],
      ]) {
        const result = await server.callTool("restore-drill", { backup });
        assert.equal(result.isError, true, backup);
        assert.equal(result.text, `restore-drill: failed: ${reason}`, backup);
      }
      const typed = await server.callTool("restore-drill", { backup: 7 });
      assert.equal(typed.text, "restore-drill: failed: that is not a backup's name, which is its UTC start, as 2026-11-08T142305Z");
      const other = await server.callTool("restore-drill", { root: "/tmp" });
      assert.equal(other.text, "restore-drill: takes no root");
    });
    assert.deepEqual(docker.calls(), [], "docker ran");
    assert.equal(restorer.read("cmdline"), null, "mongorestore ran");
    assert.deepEqual(drillsOf(stamp), []);
  });

  test("removes the toolkit's container, network and image past their expiry, naming each, and keeps the rest", async () => {
    const stamp = await takeBackup();
    const tag = randomBytes(4).toString("hex");
    const labels = (expires, toolkit = "prod-mongo") => ["--label", `${teamLabel("owner")}=agent-team`, "--label", `${teamLabel("kind")}=drill`, "--label", `${teamLabel("toolkit")}=${toolkit}`, "--label", `${teamLabel("expires")}=${expires}`];
    const made = { containers: [], networks: [], images: [] };
    const make = (name, labelArgs) => {
      execFileSync(realDocker, ["run", "--detach", "--name", name, ...labelArgs, "--entrypoint", "sleep", mongoImage, "600"], { stdio: "pipe" });
      made.containers.push(name);
    };
    try {
      make(`prod-mongo-drill-expired-${tag}`, labels("2020-01-01T00:00:00Z"));
      make(`prod-mongo-drill-live-${tag}`, labels("2999-01-01T00:00:00Z"));
      make(`not-prod-mongo-${tag}`, labels("2020-01-01T00:00:00Z", "other"));
      execFileSync(realDocker, ["commit", `prod-mongo-drill-expired-${tag}`, `prod-mongo-expired-test:${tag}`], { stdio: "pipe" });
      made.images.push(`prod-mongo-expired-test:${tag}`);
      execFileSync(realDocker, ["network", "create", ...labels("2020-01-01T00:00:00Z"), `prod-mongo-expired-${tag}`], { stdio: "pipe" });
      made.networks.push(`prod-mongo-expired-${tag}`);
      await drillServer(async (server) => {
        const result = await server.callTool("restore-drill", { backup: stamp });
        assert.ok(!result.isError, result.text);
        assert.match(
          result.text.split("\n").at(-1),
          new RegExp(`^Removed what an earlier run left past its expiry: (\\S+ \\S+, )*container prod-mongo-drill-expired-${tag}(, \\S+ \\S+)*\\.$`),
        );
        for (const part of [`network prod-mongo-expired-${tag}`, `image prod-mongo-expired-test:${tag}`]) assert.ok(result.text.includes(part), part);
        assert.ok(!result.text.includes(`live-${tag}`) && !result.text.includes(`not-prod-mongo-${tag}`), result.text);
      });
      assert.ok(gone(`prod-mongo-drill-expired-${tag}`));
      assert.ok(!gone(`prod-mongo-drill-live-${tag}`));
      assert.ok(!gone(`not-prod-mongo-${tag}`));
      assert.notEqual(spawnSync(realDocker, ["network", "inspect", `prod-mongo-expired-${tag}`]).status, 0, "the expired network is still there");
      assert.notEqual(spawnSync(realDocker, ["image", "inspect", `prod-mongo-expired-test:${tag}`]).status, 0, "the expired image is still there");
      // Each expired one removed by its id; the drill's own by its name.
      const [run] = docker.calls().filter(([command]) => command === "run");
      const own = run[run.indexOf("--name") + 1];
      const removals = docker.calls().filter(([command, sub]) => command === "rm" || (["network", "image"].includes(command) && sub === "rm"));
      assert.equal(removals.filter((call) => call.at(-1) !== own).length, 3, JSON.stringify(removals));
      for (const call of removals.filter((args) => args.at(-1) !== own)) assert.match(call.at(-1), /^(sha256:)?[0-9a-f]{64}$/, call.join(" "));
    } finally {
      for (const name of made.containers) spawnSync(realDocker, ["rm", "--force", name]);
      for (const name of made.networks) spawnSync(realDocker, ["network", "rm", name]);
      for (const name of made.images) spawnSync(realDocker, ["image", "rm", "--force", name]);
    }
  });

  test("answers that the machine is busy while another run holds the heavy-run lock, and runs nothing", async () => {
    const stamp = await takeBackup();
    const lock = join(home, ".local", "state", "agent-team", "heavy.lock");
    mkdirSync(dirname(lock), { recursive: true });
    writeFileSync(lock, "the test's own run (pid 1) since now\n");
    const holder = spawn("flock", [lock, "sleep", "300"], { stdio: "ignore" });
    try {
      await until(() => spawnSync("flock", ["-n", lock, "true"]).status !== 0);
      await withServer(async (server) => {
        const result = await server.callTool("restore-drill", { backup: stamp });
        assert.equal(result.isError, true);
        assert.equal(result.text, "restore-drill: the machine is busy: the heavy-run lock is held by the test's own run (pid 1) since now; ask again later");
      }, { path: drillPath(), env: { PROD_MONGO_HEAVY_WAIT_MINUTES: "0" } });
    } finally {
      holder.kill();
    }
    assert.deepEqual(docker.calls(), [], "docker ran");
    assert.deepEqual(drillsOf(stamp), []);
  });

  test("shares the one-long-call lock with backup", async () => {
    spy.set("hold");
    await drillServer(async (server) => {
      const first = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      const drill = await server.callTool("restore-drill", {});
      assert.equal(drill.text, "restore-drill: a backup is already running");
      spy.set("go");
      assert.ok(!(await first).isError);
    });
    assert.deepEqual(docker.calls(), []);
  });

  // The script as Daniel runs it: through team-heavy (this test's HOME has a lock of its own),
  // with no MCP server and no op.
  const byHand = (args, { path = [toolsDir, testPath()].join(":") } = {}) =>
    spawn(join(repoRoot, "bin", "team-heavy"), ["run", "--kind", "restore-drill", "--", process.execPath, join(repoRoot, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs"), ...args], {
      env: { HOME: home, PATH: path, PROD_MONGO_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    });
  const ended = (child) =>
    new Promise((resolve) => {
      let stdout = "";
      let stderr = "";
      child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
      child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
      child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
    });

  test("run by hand through team-heavy: --text prints the tool's answer, and without it one JSON object", async () => {
    const stamp = await takeBackup();
    const text = await ended(byHand([stamp, "--text"]));
    assert.equal(text.code, 0, text.stderr);
    assert.match(text.stdout, new RegExp(`^Restore drill of ~/conventioner-backups/${stamp}: PASS in \\d+ s, mongorestore `));
    assert.match(text.stdout, /; nothing was left running\.\n$/);
    const json = await ended(byHand([stamp]));
    assert.equal(json.code, 0, json.stderr);
    assert.equal(json.stdout.split("\n").filter(Boolean).length, 1, json.stdout);
    const result = JSON.parse(json.stdout);
    assert.equal(result.verdict, "PASS");
    assert.deepEqual(result.cleanup, { gone: true });
    assert.ok(gone(result.container));
    assert.equal(drillsOf(stamp).length, 2);
    const refused = await ended(byHand(["--uri=mongodb://x", stamp]));
    assert.equal(refused.code, 1);
    assert.deepEqual(JSON.parse(refused.stdout), { refused: "takes exactly one argument, a backup's name, its UTC start as 2026-11-08T142305Z (and --text for the answer as text)" });
  });

  test("restoring.md's commands: the drill by hand as the tests run it, and the restore to production, run as Daniel would", async () => {
    const doc = readFileSync(join(repoRoot, "toolkits", "prod-mongo", "docs", "restoring.md"), "utf8");
    assert.ok(doc.includes("\n~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text\n"));
    const blocks = [...doc.matchAll(/^```bash\n([\s\S]*?)^```$/gm)].map(([, body]) => body);
    const restore = blocks.find((body) => body.startsWith("read -rs PROD_URI\n"));
    assert.ok(restore, "restoring.md has no restore command");
    const stamp = await takeBackup();
    await target.client.db("conventioner").dropDatabase();
    await target.client.db("conventioner").collection("markets").insertOne({ name: "written since the dump" });
    const restored = spawnSync("bash", ["-c", restore.replaceAll("<stamp>", stamp)], {
      input: `${targetUri}\n`,
      env: { HOME: home, PATH: [restorer.dir, toolsDir, testPath()].join(":") },
      encoding: "utf8",
    });
    assert.equal(restored.status, 0, restored.stderr);
    assert.deepEqual(await collectionsOf(target.client), await collectionsOf(production.client));
    assert.equal(await target.client.db("conventioner").collection("markets").countDocuments({ name: "written since the dump" }), 0);
    const { password } = new URL(targetUri);
    assert.ok(!restorer.read("cmdline").includes(password), "the password is in mongorestore's argument list");
    assert.doesNotMatch(restorer.read("cmdline"), /mongodb:\/\//);
    assert.ok(!restorer.read("environ").includes(password), "the password is in mongorestore's environment");
    assert.equal(restorer.read("config-kind"), "fifo\n");
  });

  test("removes its throwaway when stopped by SIGINT, SIGTERM or SIGHUP mid-drill, and records no verdict", async () => {
    const stamp = await takeBackup();
    const signals = ["SIGINT", "SIGTERM", "SIGHUP"];
    const script = join(repoRoot, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs");
    // One copy of the dump and one holding mongorestore spy per drill, all three at once.
    const runs = signals.map((signal, n) => {
      const copy = `2025-0${n + 1}-01T000000Z`;
      cpSync(join(root, stamp), join(root, copy), { recursive: true });
      const holding = spyMongorestore();
      holding.set("hold");
      const child = spawn(process.execPath, [script, copy], { env: { HOME: home, PATH: [holding.dir, toolsDir, testPath()].join(":"), PROD_MONGO_ROOT: root }, stdio: ["ignore", "pipe", "pipe"] });
      return { signal, copy, holding, child, done: ended(child) };
    });
    await until(() => runs.every(({ holding }) => holding.read("held") !== null), 180_000);
    for (const { child, signal } of runs) child.kill(signal);
    for (const { signal, copy, done } of runs) {
      const result = await done;
      assert.equal(result.code, 128 + { SIGINT: 2, SIGTERM: 15, SIGHUP: 1 }[signal], result.stderr);
      const out = JSON.parse(result.stdout);
      assert.equal(out.failed, `the drill was stopped (${signal})`);
      assert.deepEqual(out.cleanup, { gone: true });
      assert.ok(gone(out.container), out.container);
      assert.deepEqual(drillsOf(copy), []);
    }
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

  test("the room rule's edges: exactly enough passes, a byte short refuses naming both numbers", () => {
    const gib = 1024 ** 3;
    assert.equal(roomRefusal(gib, 0), undefined);
    assert.equal(roomRefusal(gib + 2 * gib, gib), undefined);
    assert.equal(
      roomRefusal(gib + 2 * gib - 1, gib),
      "the backups folder's disk has 3.0 GiB free, less than the 3.0 GiB a dump needs (1 GiB plus twice the database's 1.0 GiB of data)",
    );
    assert.match(roomRefusal(0, 0), /^the backups folder's disk has 0 B free, less than the 1\.0 GiB a dump needs/);
  });

  // The rules the server cannot reach on this machine: macOS's folders, the CI variables, the forms
  // a symlink gives, on a context written out.
  describe("destinationRefusal", () => {
    const linux = { home: "/home/d", teamHome: "/home/d/agent-team-records", tmpdir: "/tmp", env: {}, platform: "linux", holding: {}, resolved: {} };
    const mac = { ...linux, home: "/Users/d", teamHome: undefined, tmpdir: "/var/folders/ab/T", platform: "darwin" };
    const refusal = (path, context) => destinationRefusal(path, context);

    test("passes the launcher's root, and one beside the checkouts", () => {
      assert.equal(refusal("/home/d/conventioner-backups", linux), undefined);
      assert.equal(refusal("/srv/backups", linux), undefined);
      assert.equal(refusal("/Users/d/conventioner-backups", mac), undefined);
    });

    test("refuses / and the home, however written", () => {
      assert.equal(refusal("/", linux), "the backups folder / is / itself");
      assert.equal(refusal("/home/d/", linux), "the backups folder ~ is the home directory itself");
      assert.equal(refusal("/home/d/x/..", linux), "the backups folder ~ is the home directory itself");
    });

    test("refuses Desktop and Documents on macOS only", () => {
      for (const name of ["Desktop", "Documents"]) {
        assert.equal(refusal(`/Users/d/${name}/backups`, mac), `the backups folder ~/${name}/backups is inside a synced folder, ~/${name}`);
        assert.equal(refusal(`/home/d/${name}/backups`, linux), undefined);
      }
    });

    test("refuses macOS's cloud folders and temporary directories", () => {
      assert.equal(refusal("/Users/d/Library/CloudStorage/GoogleDrive-d/backups", mac), "the backups folder ~/Library/CloudStorage/GoogleDrive-d/backups is inside a synced folder, ~/Library/CloudStorage");
      assert.equal(refusal("/Users/d/Library/Mobile Documents/backups", mac), "the backups folder ~/Library/Mobile Documents/backups is inside a synced folder, ~/Library/Mobile Documents");
      assert.equal(refusal("/private/var/folders/ab/T/backups", mac), "the backups folder /private/var/folders/ab/T/backups is inside a shared temporary directory, /private/var/folders");
      assert.equal(refusal("/private/tmp/backups", mac), "the backups folder /private/tmp/backups is inside a shared temporary directory, /private/tmp");
    });

    test("refuses every synced folder by name, a work OneDrive included", () => {
      for (const name of ["Box", "Dropbox", "Google Drive", "GoogleDrive", "iCloud Drive", "MEGA", "Nextcloud", "OneDrive", "ownCloud", "pCloudDrive", "Sync"]) {
        assert.equal(refusal(`/home/d/${name}/b`, linux), `the backups folder ~/${name}/b is inside a synced folder, ~/${name}`);
      }
      assert.equal(refusal("/home/d/OneDrive - Acme Ltd/b", linux), "the backups folder ~/OneDrive - Acme Ltd/b is inside a synced folder, ~/OneDrive - Acme Ltd");
      assert.equal(refusal("/home/d/OneDriveNotes/b", linux), undefined);
    });

    test("refuses below any sync client's marker, a .sync_*.db file included", () => {
      for (const marker of [".dropbox", ".dropbox.cache", ".nextcloudsync.log", ".owncloudsync.log", ".stfolder", ".sync", ".sync_4f2a.db"]) {
        assert.equal(refusal("/data/share/b", { ...linux, holding: { "/data/share": [marker] } }), `the backups folder /data/share/b is inside a synced folder: /data/share holds ${marker}`);
      }
    });

    test("refuses the CI workspaces and the temporary directories the environment names", () => {
      for (const name of ["GITHUB_WORKSPACE", "RUNNER_WORKSPACE", "RUNNER_TEMP"]) {
        assert.equal(refusal("/home/runner/work/x/b", { ...linux, env: { [name]: "/home/runner/work/x" } }), `the backups folder /home/runner/work/x/b is inside a CI workspace, ${name} (/home/runner/work/x)`);
      }
      assert.equal(refusal("/run/user/1000/b", { ...linux, env: { XDG_RUNTIME_DIR: "/run/user/1000" } }), "the backups folder /run/user/1000/b is inside a shared temporary directory, /run/user/1000");
      assert.equal(refusal("/var/tmp/b", linux), "the backups folder /var/tmp/b is inside a shared temporary directory, /var/tmp");
      assert.equal(refusal("/dev/shm/b", linux), "the backups folder /dev/shm/b is inside a shared temporary directory, /dev/shm");
    });

    test("judges the real path as well as the one given, and a named directory by its real path too", () => {
      assert.equal(refusal("/home/d/link", { ...linux, real: "/home/d/Dropbox/b" }), "the backups folder ~/link is inside a synced folder, ~/Dropbox");
      assert.equal(refusal("/home/d/link", { ...linux, real: "/home/d/repo/b", holding: { "/home/d/repo": [".git"] } }), "the backups folder ~/link is inside a git checkout: ~/repo holds .git");
      assert.equal(refusal("/home/d/b", { ...linux, real: "/mnt/records/b", teamHome: "/home/d/records", resolved: { "/home/d/records": "/mnt/records" } }), "the backups folder ~/b is inside the team home, ~/records");
      // A home that is itself a symlink: its real form is the home too.
      assert.equal(refusal("/home/d/b", { ...linux, real: "/data/home/d/.claude/b", resolved: { "/home/d": "/data/home/d" } }), "the backups folder ~/b is inside ~/.claude, Claude Code's own folder of transcripts and jobs");
      // A prefix of a name is not a parent.
      assert.equal(refusal("/home/d/agent-team-records-old/b", linux), undefined);
      assert.equal(refusal("/tmpfiles/b", linux), undefined);
    });
  });

  describe("dumpByStamp", () => {
    let real;
    beforeEach(() => {
      real = join(newHome(), "backups");
      mkdirSync(real);
      const make = (stamp, manifest) => {
        mkdirSync(join(real, stamp));
        if (manifest !== undefined) writeFileSync(join(real, stamp, "manifest.json"), manifest);
      };
      make("2026-11-08T142305Z", JSON.stringify({ verified: true, totals: { documents: 3 } }));
      make("2026-11-08T150000Z", JSON.stringify({ verified: false }));
      make("2026-11-08T160000Z");
      make("2026-11-08T170000Z", "{not json");
      symlinkSync(join(real, "2026-11-08T142305Z"), join(real, "2026-11-08T180000Z"));
    });
    test("gives the verified dump of a stamp", () => {
      const { stamp, folder, manifest } = dumpByStamp(real, "2026-11-08T142305Z", "~/b");
      assert.deepEqual([stamp, folder, manifest.totals.documents], ["2026-11-08T142305Z", join(real, "2026-11-08T142305Z"), 3]);
    });

    test("refuses a path, a partial's name or anything not a stamp", () => {
      for (const stamp of ["../2026-11-08T142305Z", "/etc", "2026-11-08T142305Z/", ".2026-11-08T142305Z.partial", "2026-11-08", "", 7, undefined]) {
        assert.throws(() => dumpByStamp(real, stamp, "~/b"), { message: /is not a backup's name, which is its UTC start, as 2026-11-08T142305Z$/ }, String(stamp));
      }
      assert.throws(() => dumpByStamp(real, "../x", "~/b"), { message: `"../x" is not a backup's name, which is its UTC start, as 2026-11-08T142305Z` });
      assert.throws(() => dumpByStamp(real, "x".repeat(100), "~/b"), { message: `"${"x".repeat(40)}..." is not a backup's name, which is its UTC start, as 2026-11-08T142305Z` });
    });

    test("refuses a stamp with no folder, no verified manifest, or a symlink for a folder", () => {
      assert.throws(() => dumpByStamp(real, "2026-01-01T000000Z", "~/b"), { message: "~/b holds no backup 2026-01-01T000000Z" });
      for (const stamp of ["2026-11-08T150000Z", "2026-11-08T160000Z", "2026-11-08T170000Z"]) {
        assert.throws(() => dumpByStamp(real, stamp, "~/b"), { message: `~/b/${stamp} has no verified manifest.json, so it is not a dump this toolkit took` }, stamp);
      }
      assert.throws(() => dumpByStamp(real, "2026-11-08T180000Z", "~/b"), { message: "~/b/2026-11-08T180000Z is not a folder this toolkit took" });
    });
  });

  test("the retention rule keeps the 5 newest verified dumps", () => {
    assert.equal(kept, 5);
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
