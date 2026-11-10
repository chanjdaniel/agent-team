// The effect toolkit's Foldkit DevTools MCP server, started as its .mcp.json declares (the wrapper
// in scripts/, on the @foldkit/devtools-mcp servers/ pins) and spoken to over stdio, against real
// Vite dev servers of tests/toolkits/fixtures/foldkit-app/ open in a headless Chrome: one in a
// project's primary checkout, one in a worktree slot inside it (.claude/worktrees/1), and a second
// slot (.claude/worktrees/2) with no dev server. Every dev server and server shares one relay
// registry, a private directory under the test's own XDG_RUNTIME_DIR, so the machine's is never
// read or written.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, cpSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { browserSession, startChrome } from "./helpers/chrome.mjs";
import { repoRoot, serverConfig, startServer, tempDir } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "effect");
const modules = join(repoRoot, "servers", "node_modules");
const fixture = join(repoRoot, "tests", "toolkits", "fixtures", "foldkit-app");
const readme = readFileSync(join(toolkit, "README.md"), "utf8");
const skill = readFileSync(join(toolkit, "skills", "effect-v4", "SKILL.md"), "utf8");

const run = tempDir("foldkit");
const home = join(run, "home");
const xdg = join(run, "xdg");
const registry = join(xdg, "foldkit-devtools-relays");
const checkout = join(run, "intone_app");
const slot = join(checkout, ".claude", "worktrees", "1");
const emptySlot = join(checkout, ".claude", "worktrees", "2");
mkdirSync(home);
mkdirSync(xdg, { mode: 0o700 });
for (const dir of [checkout, slot, emptySlot]) {
  mkdirSync(dir, { recursive: true });
  cpSync(fixture, dir, { recursive: true });
  symlinkSync(modules, join(dir, "node_modules"));
}

// A Vite dev server of the app in `dir`, its Model's app field `name`: resolves once it serves
// its page and its relay's record is in the registry.
async function startDevServer(dir, name) {
  const child = spawn(process.execPath, [join(modules, "vite", "bin", "vite.js"), "--port", "0"], {
    cwd: dir,
    env: { HOME: home, PATH: process.env.PATH, XDG_RUNTIME_DIR: xdg, VITE_FIXTURE_APP: name, NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  child.stdout.on("data", (chunk) => (log += chunk));
  child.stderr.on("data", (chunk) => (log += chunk));
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const close = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    child.kill("SIGTERM");
    await Promise.race([exited, sleep(5000).then(() => child.kill("SIGKILL"))]);
  };
  const root = realpathSync(dir);
  for (let i = 0; i < 300; i++) {
    const url = log.match(/Local:\s+(http:\/\/\S+)/)?.[1];
    if (url && records().some((record) => record.root === root)) return { url, close, log: () => log };
    if (child.exitCode !== null) break;
    await sleep(100);
  }
  await close();
  throw new Error(`the dev server in ${dir} did not start:\n${log}`);
}

const records = () => {
  try {
    return readdirSync(registry).filter((name) => name.endsWith(".json"))
      .map((name) => JSON.parse(readFileSync(join(registry, name), "utf8")));
  } catch {
    return [];
  }
};

// The toolkit's server for `worktree`, as team-worker would start it, with its temporary
// directory (where its private registry lives) inside the test's.
function devtools(worktree, env = {}) {
  const tmp = tempDir("tmp");
  const server = startServer(serverConfig("effect", { server: "foldkit-devtools", worktree }), {
    home,
    env: { XDG_RUNTIME_DIR: xdg, TMPDIR: tmp, ...env },
  });
  server.tmp = tmp;
  return server;
}

// The server on its own, with no wrapper, for the case the wrapper is there for.
function bareServer(worktree) {
  return startServer({ command: process.execPath, args: [join(modules, "@foldkit", "devtools-mcp", "dist", "server.js")] }, {
    home,
    env: { XDG_RUNTIME_DIR: xdg, FOLDKIT_PROJECT_ROOT: worktree },
  });
}

// foldkit_list_runtimes' project roots, asked until it lists `count` runtimes or 60 s pass: a
// page's bridge connects once Vite has bundled the app's dependencies for it, a second or two
// after it loads on an idle machine and far longer on a busy one. A refusal is returned at once,
// as { error }.
async function runtimeRoots(server, count = 1) {
  const deadline = Date.now() + 60_000;
  for (;;) {
    const result = await server.callTool("foldkit_list_runtimes", {});
    if (result.isError) return { error: result.text };
    const roots = JSON.parse(result.text).runtimes.map((runtime) => runtime.projectRoot).sort();
    if (roots.length >= count || Date.now() > deadline) return { roots };
    await sleep(200);
  }
}

const NOT_CONNECTED = /^Error: Not connected to a Foldkit dev server\./;

describe("the effect toolkit's Foldkit DevTools MCP server", () => {
  let checkoutApp, slotApp, chrome;
  before(async () => {
    [checkoutApp, slotApp] = await Promise.all([startDevServer(checkout, "checkout"), startDevServer(slot, "slot")]);
    chrome = await startChrome([checkoutApp.url, slotApp.url]);
    // Until both pages' bridges have connected, which the server alone, rooted at the checkout,
    // sees: every case below then starts from two running apps.
    const server = bareServer(checkout);
    try {
      await server.initialize();
      const { roots } = await runtimeRoots(server, 2);
      assert.deepEqual(roots, [realpathSync(checkout), realpathSync(slot)].sort(),
        `the apps' pages did not connect:\n${checkoutApp.log()}\n${slotApp.log()}`);
    } finally {
      await server.close();
    }
  });
  after(async () => {
    await chrome?.close();
    await Promise.all([checkoutApp?.close(), slotApp?.close()]);
  });

  test("starts the toolkit's wrapper with FOLDKIT_PROJECT_ROOT set to the session's worktree", () => {
    const config = JSON.parse(readFileSync(join(toolkit, ".mcp.json"), "utf8"));
    assert.deepEqual(Object.keys(config.mcpServers), ["foldkit-devtools"]);
    assert.deepEqual(config.mcpServers["foldkit-devtools"], {
      command: "node",
      args: ["@TEAM_CODE@/toolkits/effect/scripts/foldkit-devtools-mcp.mjs"],
      env: { FOLDKIT_PROJECT_ROOT: "@WORKTREE@" },
    });
  });

  test("runs the @foldkit/devtools-mcp servers/ pins, the version intone's foldkit 0.170.0 shipped with", () => {
    const pins = JSON.parse(readFileSync(join(repoRoot, "servers", "package.json"), "utf8")).dependencies;
    assert.equal(pins["@foldkit/devtools-mcp"], "0.26.0");
    assert.equal(pins.foldkit, "0.170.0");
    assert.equal(pins["@foldkit/vite-plugin"], "0.29.0");
    const installed = JSON.parse(readFileSync(join(modules, "@foldkit", "devtools-mcp", "package.json"), "utf8"));
    assert.equal(installed.version, "0.26.0");
    assert.equal(installed.devDependencies.foldkit, pins.foldkit);
  });

  test("lists the server's tools, every one of which its README names", async () => {
    const server = devtools(slot);
    try {
      await server.initialize();
      const names = (await server.listTools()).map((tool) => tool.name).sort();
      assert.deepEqual(names, [
        "foldkit_count_messages_by_tag", "foldkit_diff_models", "foldkit_dispatch_message", "foldkit_dispatch_messages",
        "foldkit_get_init", "foldkit_get_message", "foldkit_get_message_schema", "foldkit_get_model", "foldkit_get_model_at",
        "foldkit_get_runtime_state", "foldkit_list_keyframes", "foldkit_list_messages", "foldkit_list_runtimes",
        "foldkit_replay_to_keyframe", "foldkit_resume",
      ]);
      for (const name of names) assert.ok(readme.includes(`\`${name}\``), `the README does not name ${name}`);
    } finally {
      await server.close();
    }
  });

  test("on its own, in a slot with no dev server, reads the enclosing checkout's app, which the wrapper is for", async () => {
    const server = bareServer(emptySlot);
    try {
      await server.initialize();
      assert.deepEqual(await runtimeRoots(server), { roots: [realpathSync(checkout)] });
    } finally {
      await server.close();
    }
  });

  test("in a slot sees only the slot's app, not the checkout's that encloses it", async () => {
    const server = devtools(slot);
    try {
      await server.initialize();
      assert.deepEqual(await runtimeRoots(server), { roots: [realpathSync(slot)] });
      const model = async () => JSON.parse((await server.callTool("foldkit_get_model", {})).text).value;
      assert.deepEqual(await model(), { app: "slot", count: 0 });
      // Its dispatch changes the slot's running app.
      const dispatched = await server.callTool("foldkit_dispatch_message", { message: { _tag: "ClickedIncrement" } });
      assert.ok(!dispatched.isError, dispatched.text);
      assert.deepEqual(await model(), { app: "slot", count: 1 });
      // Its private registry: one directory, shared with no one, holding the slot's record only.
      const [mirror, ...more] = readdirSync(server.tmp);
      assert.deepEqual(more, []);
      assert.equal(statSync(join(server.tmp, mirror)).mode & 0o777, 0o700);
      const slotRecord = records().find((record) => record.root === realpathSync(slot));
      assert.deepEqual(readdirSync(join(server.tmp, mirror)), [`${slotRecord.id}.json`]);
    } finally {
      await server.close();
    }
    assert.deepEqual(readdirSync(server.tmp), [], "the server's private registry outlived it");
  });

  test("in a slot with no dev server sees none, not the checkout's that encloses it", async () => {
    const server = devtools(emptySlot);
    try {
      await server.initialize();
      const { error } = await runtimeRoots(server);
      assert.match(error, NOT_CONNECTED);
      assert.match((await server.callTool("foldkit_get_model", {})).text, NOT_CONNECTED);
      const dispatched = await server.callTool("foldkit_dispatch_message", { message: { _tag: "ClickedIncrement" } });
      assert.match(dispatched.text, NOT_CONNECTED);
    } finally {
      await server.close();
    }
  });

  test("finds a slot's dev server started after it on the next call, and loses it when it stops", async () => {
    const server = devtools(emptySlot);
    let app;
    try {
      await server.initialize();
      assert.match((await runtimeRoots(server)).error, NOT_CONNECTED);
      app = await startDevServer(emptySlot, "second slot");
      const browser = await browserSession(chrome.browserUrl);
      try {
        await browser.send("Target.createTarget", { url: app.url });
      } finally {
        browser.close();
      }
      assert.deepEqual(await runtimeRoots(server), { roots: [realpathSync(emptySlot)] });
      await app.close();
      assert.match((await runtimeRoots(server)).error, NOT_CONNECTED);
    } finally {
      await app?.close();
      await server.close();
    }
  });

  test("ignores FOLDKIT_DEVTOOLS_MCP_PORT and FOLDKIT_DEVTOOLS_MCP_HOST, which skip the registry", async () => {
    const port = new URL(records().find((record) => record.root === realpathSync(checkout)).url).port;
    const server = devtools(slot, { FOLDKIT_DEVTOOLS_MCP_PORT: port, FOLDKIT_DEVTOOLS_MCP_HOST: "127.0.0.1" });
    try {
      await server.initialize();
      assert.deepEqual(await runtimeRoots(server), { roots: [realpathSync(slot)] });
    } finally {
      await server.close();
    }
    assert.match(server.stderr, /^foldkit-devtools: ignoring FOLDKIT_DEVTOOLS_MCP_PORT: /m);
    assert.match(server.stderr, /^foldkit-devtools: ignoring FOLDKIT_DEVTOOLS_MCP_HOST: /m);
    assert.match(server.stderr, new RegExp(`looking up Foldkit dev servers for ${realpathSync(slot)} on each tool call`));
  });

  test("ignores a registry another user could read, as the server would", async () => {
    chmodSync(registry, 0o750);
    const server = devtools(slot);
    try {
      await server.initialize();
      assert.match((await runtimeRoots(server)).error, NOT_CONNECTED);
    } finally {
      chmodSync(registry, 0o700);
      await server.close();
    }
    assert.match(server.stderr, /^foldkit-devtools: ignoring the relay registry at .*: it is readable or writable by other users$/m);
  });

  for (const { what, args = [], env, reason } of [
    { what: "when given an argument", args: ["init"], env: { FOLDKIT_PROJECT_ROOT: slot }, reason: /^takes no arguments$/ },
    { what: "with no FOLDKIT_PROJECT_ROOT", env: {}, reason: /^FOLDKIT_PROJECT_ROOT is not set$/ },
    { what: "with @WORKTREE@ unfilled", env: { FOLDKIT_PROJECT_ROOT: "@WORKTREE@" }, reason: /^FOLDKIT_PROJECT_ROOT is not an absolute path: @WORKTREE@$/ },
    { what: "with a worktree that does not exist", env: { FOLDKIT_PROJECT_ROOT: join(run, "gone") }, reason: /^FOLDKIT_PROJECT_ROOT is not a directory: / },
  ]) {
    test(`refuses to start ${what}`, async () => {
      const { command, args: configArgs } = serverConfig("effect", { server: "foldkit-devtools" });
      const tmp = tempDir("tmp");
      const server = startServer({ command, args: configArgs, env }, { home, env: { XDG_RUNTIME_DIR: xdg, TMPDIR: tmp }, args });
      try {
        await assert.rejects(server.initialize(), /server exited \(1\)/);
      } finally {
        await server.close();
      }
      assert.equal(server.stdout, "");
      const lines = server.stderr.split("\n").filter(Boolean);
      assert.equal(lines.length, 1, server.stderr);
      assert.match(lines[0], /^foldkit-devtools: /);
      assert.match(lines[0].slice("foldkit-devtools: ".length), reason);
      assert.deepEqual(readdirSync(tmp), []);
    });
  }

  test("its skill and README say when to use it and that Models and payloads enter the context", () => {
    const section = skill.match(/^## 9\. Foldkit's DevTools MCP server\n([\s\S]*?)(?=^## |(?![\s\S]))/m)?.[1] ?? "";
    assert.match(section, /foldkit_/);
    assert.match(section, /context/);
    assert.match(section, /secret/);
    assert.match(readme, /foldkit_dispatch_message/);
    assert.match(readme, /tests\/toolkits\/effect-devtools\.test\.mjs/);
  });
});
