// The frontend toolkit's scripts against a headless Chrome standing in for the Agent Chrome:
// ui-capture reads the element selected in DevTools on a local fixture page shaped like
// Conventioner's dev build (vite-plugin-vue-inspector's hidden __v_inspector props), and only
// localhost pages; agent-chrome starts Chrome with its own profile and debugging port.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { promisify } from "node:util";
import { chromePath, inspect, serveFixture, startChrome } from "./helpers/chrome.mjs";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";

const scripts = join(repoRoot, "toolkits", "frontend", "scripts");
const modules = join(repoRoot, "servers", "node_modules");
const run = promisify(execFile);

// A script's exit status, stdout and stderr, whatever the status.
async function script(name, args, options = {}) {
  try {
    const { stdout, stderr } = await run(join(scripts, name), args, { timeout: 120_000, ...options });
    return { status: 0, stdout, stderr };
  } catch (error) {
    if (error.code === undefined || typeof error.code !== "number") throw error;
    return { status: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}

// A page like Conventioner's dev build: each element the inspector tags carries its source in
// __vnode.props.__v_inspector, and a component's elements its instance chain.
const fixture = `<!doctype html>
<title>Fixture app</title>
<style>
  .menu-button[data-v-8e30ecee] { height: 100%; aspect-ratio: 1; }
  .menu-button { color: rgb(1, 2, 3); }
  .plain { padding: 4px; }
</style>
<div id="app">
  <header>
    <button data-v-8e30ecee class="menu-button" aria-label="Open navigation">Menu</button>
  </header>
  <div class="plain">Plain text</div>
  <div class="untagged">Untagged</div>
</div>
<script>
  const tag = (selector, loc) => (document.querySelector(selector).__vnode = { props: { __v_inspector: loc } });
  tag("#app", "src/App.vue:88:3");
  tag("header", "src/App.vue:89:5");
  tag(".menu-button", "src/components/elements/ElementBanner.vue:30:5");
  tag(".plain", "src/App.vue:95:5");
  const app = { type: { __name: "App", __file: "/home/x/front-end/src/App.vue" }, parent: null };
  document.querySelector(".menu-button").__vueParentComponent = {
    type: { __name: "ElementBanner", __file: "/home/x/front-end/src/components/elements/ElementBanner.vue" },
    parent: app,
  };
  document.querySelector("#app").__vueParentComponent = app;
  // The untagged element sits outside every tagged one, as in a production build.
  document.body.append(document.querySelector(".untagged"));
</script>`;
const elsewhere = "data:text/html,<title>Elsewhere</title><p>marker-elsewhere</p>";

describe("ui-capture", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({ "/": fixture });
    chrome = await startChrome([site.url, elsewhere]);
  });
  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  test("refuses a malformed command line and answers --help with its header", async () => {
    assert.equal((await script("ui-capture", [])).status, 2);
    assert.equal((await script("ui-capture", ["--browser-url", "http://example.com:9222", tempDir("out")])).status, 2);
    const help = await script("ui-capture", ["--help"]);
    assert.equal(help.status, 0);
    assert.match(help.stdout, /^Capture the element selected in the Agent Chrome's DevTools Elements panel/);
    assert.match(help.stdout, /Usage: ui-capture \[--browser-url <url>\] <out-dir>/);
  });

  test("fails in one line when no Agent Chrome answers", async () => {
    const port = await freePort();
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", `http://127.0.0.1:${port}`, out]);
    assert.equal(result.status, 1);
    assert.equal(result.stderr, `ui-capture: no Agent Chrome answers at http://127.0.0.1:${port}; start it with toolkits/frontend/scripts/agent-chrome\n`);
    assert.ok(!existsSync(join(out, "ui-pick.md")));
  });

  // In order: no DevTools yet, DevTools open on its default <body>, then each selection.
  test("fails in one line when no localhost page has DevTools open, even with DevTools open on another page", async () => {
    await inspect(chrome.browserUrl, elsewhere, "p");
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.equal(result.stderr, "ui-capture: no localhost page of the Agent Chrome has DevTools open; right-click the element and Inspect\n");
    // The other page is never read: nothing of it reaches the output.
    assert.ok(!`${result.stdout}${result.stderr}`.includes("marker-elsewhere"));
    assert.ok(!existsSync(join(out, "ui-pick.md")));
  });

  test("fails in one line when DevTools is open but nothing is selected", async () => {
    await inspect(chrome.browserUrl, site.url, null);
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, tempDir("out")]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: DevTools is open on http:\/\/127\.0\.0\.1:\d+\/ but no element is selected \(it shows <body>\); right-click the element and Inspect, or click it in the Elements panel\n$/);
  });

  test("captures the selected element: its page, source and component chains, HTML, matched CSS and screenshots", async () => {
    await inspect(chrome.browserUrl, site.url, ".menu-button");
    const out = join(tempDir("out"), "ui");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^ui-capture: button "Open navigation" .* at button src\/components\/elements\/ElementBanner\.vue:30:5 -> /);
    const pick = readFileSync(join(out, "ui-pick.md"), "utf8");
    assert.match(pick, /^# The selected element\n\nCaptured \d{4}-\d\d-\d\dT[\d:.]+Z by ui-capture from the Agent Chrome at http:\/\/127\.0\.0\.1:\d+\.\n/);
    assert.ok(pick.includes(`Page: ${site.url}\nRoute: /\n`));
    assert.match(pick, /Snapshot line: `uid=\S+ button "Open navigation" .*\[selected in the DevTools Elements panel\]`/);
    assert.ok(pick.includes("- button src/components/elements/ElementBanner.vue:30:5\n- header src/App.vue:89:5\n- div src/App.vue:88:3\n"));
    assert.ok(pick.includes("- ElementBanner src/components/elements/ElementBanner.vue\n- App src/App.vue\n"));
    assert.match(pick, /```html\n<button data-v-8e30ecee="" class="menu-button" aria-label="Open navigation">Menu<\/button>\n```/);
    assert.match(pick, /\.menu-button\[data-v-8e30ecee\] .*\{\n\s+height: 100%;\n\s+aspect-ratio: 1;/);
    assert.match(pick, /color: rgb\(1, 2, 3\)/);
    assert.ok(!pick.includes("marker-elsewhere"));
    for (const png of ["element.png", "page.png"]) {
      assert.deepEqual([...readFileSync(join(out, png)).subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], `${png} is a PNG`);
    }
  });

  test("finds a selected element outside the accessibility tree in a verbose snapshot", async () => {
    await inspect(chrome.browserUrl, site.url, ".plain");
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    const pick = readFileSync(join(out, "ui-pick.md"), "utf8");
    assert.ok(pick.includes("- div src/App.vue:95:5\n- div src/App.vue:88:3\n"));
    assert.ok(pick.includes('<div class="plain">Plain text</div>'));
  });

  test("fails in one line when the selected element carries no Vue source data", async () => {
    await inspect(chrome.browserUrl, site.url, ".untagged");
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: the page carries no Vue source data \(no __v_inspector on .* or its parents\): a production build, or a Vue DevTools without the inspector\n$/);
    assert.ok(!existsSync(join(out, "ui-pick.md")));
  });
});

// The toolkit's server exactly as .mcp.json declares it, with ${CLAUDE_PLUGIN_ROOT} resolved as
// Claude Code does for --plugin-dir and the Agent Chrome's port moved to the test's.
async function declaredServer(browserUrl) {
  const { Client } = await import(join(modules, "@modelcontextprotocol", "sdk", "dist", "esm", "client", "index.js"));
  const { StdioClientTransport } = await import(join(modules, "@modelcontextprotocol", "sdk", "dist", "esm", "client", "stdio.js"));
  const entry = declared();
  const client = new Client({ name: "toolkit-test", version: "0" });
  await client.connect(
    new StdioClientTransport({
      command: entry.command === "node" ? process.execPath : entry.command,
      args: entry.args.map((arg) => (arg === "--browser-url=http://127.0.0.1:9222" ? `--browser-url=${browserUrl}` : arg)),
      env: { PATH: process.env.PATH, HOME: process.env.HOME, ...entry.env },
      stderr: "ignore",
    }),
  );
  const call = async (name, args = {}) => {
    const result = await client.callTool({ name, arguments: args });
    return result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
  };
  return { client, call, close: () => client.close() };
}
function declared() {
  const text = readFileSync(join(repoRoot, "toolkits", "frontend", ".mcp.json"), "utf8");
  return JSON.parse(text.replaceAll("${CLAUDE_PLUGIN_ROOT}", join(repoRoot, "toolkits", "frontend"))).mcpServers.frontend;
}

describe("the toolkit's MCP server", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({ "/": fixture });
    chrome = await startChrome([site.url, elsewhere]);
  });
  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  test("attaches to the Agent Chrome with ui-capture's allowlist, and with telemetry, CrUX and update checks off", () => {
    const entry = declared();
    const capture = readFileSync(join(scripts, "ui-capture"), "utf8").match(/^const allowed = (\[.*\]);$/m)[1];
    const patterns = entry.args.slice(entry.args.indexOf("--allowedUrlPattern") + 1).filter((arg) => !arg.startsWith("--"));
    assert.deepEqual(patterns, JSON.parse(capture));
    assert.ok(entry.args.includes("--browser-url=http://127.0.0.1:9222"));
    for (const flag of ["--no-usage-statistics", "--no-performance-crux", "--no-page-id-routing"]) assert.ok(entry.args.includes(flag), flag);
    assert.deepEqual(entry.env, { CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS: "1", CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" });
  });

  test("lists only the localhost pages, sees the DevTools selection, and refuses to navigate off localhost", async () => {
    await inspect(chrome.browserUrl, site.url, ".menu-button");
    const server = await declaredServer(chrome.browserUrl);
    try {
      const pages = await server.call("list_pages");
      assert.match(pages, /^1: Fixture app \(http:\/\/127\.0\.0\.1:\d+\/\)/m);
      assert.ok(!pages.includes("Elsewhere") && !pages.includes("devtools://"), pages);
      assert.match(await server.call("take_snapshot"), /button "Open navigation" .*\[selected in the DevTools Elements panel\]/);
      assert.match(await server.call("navigate_page", { type: "url", url: "https://example.com/" }), /blocked by blocklist\/allowlist rules/);
      // The eval mocks answer with the server's own tools/list.
      const listed = (await server.client.listTools()).tools;
      const mock = JSON.parse(readFileSync(join(repoRoot, "toolkits", "frontend", "evals", "mocks", "frontend", "_tools.json"), "utf8")).tools;
      assert.deepEqual(mock, listed, "toolkits/frontend/evals/mocks/frontend/_tools.json");
    } finally {
      await server.close();
    }
  });
});

describe("agent-chrome", () => {
  let home, port, chrome;
  before(async () => {
    home = tempDir("home");
    port = await freePort();
    // TEAM_CHROME: a wrapper that logs its arguments and runs the real Chrome headless, so the
    // test opens no window.
    chrome = join(tempDir("bin"), "chrome");
    writeFileSync(chrome, `#!/bin/sh\necho "$@" >>"${home}/chrome-args"\nexec "${chromePath()}" --headless=new "$@"\n`);
    chmodSync(chrome, 0o755);
  });
  after(async () => {
    // The Chrome agent-chrome left running, by its debugging port.
    const version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json()).catch(() => null);
    if (version) {
      const ws = new WebSocket(version.webSocketDebuggerUrl);
      await new Promise((resolve) => ws.addEventListener("open", resolve));
      ws.send(JSON.stringify({ id: 1, method: "Browser.close" }));
      await new Promise((resolve) => ws.addEventListener("close", resolve));
    }
  });

  const env = () => ({ ...process.env, HOME: home, TEAM_CHROME: chrome });

  test("starts Chrome with its own profile and debugging port, at the given page, then sees it running", async () => {
    const site = await serveFixture({ "/": fixture });
    try {
      const first = await script("agent-chrome", ["--port", String(port), site.url], { env: env() });
      assert.equal(first.status, 0, first.stderr);
      assert.equal(first.stdout, `agent-chrome: running on 127.0.0.1:${port} with the profile ~/.local/share/agent-team/agent-chrome, at ${site.url}\n`);
      assert.equal(
        readFileSync(join(home, "chrome-args"), "utf8"),
        `--user-data-dir=${home}/.local/share/agent-team/agent-chrome --remote-debugging-port=${port} --no-first-run --no-default-browser-check ${site.url}\n`,
      );
      const second = await script("agent-chrome", ["--port", String(port)], { env: env() });
      assert.equal(second.status, 0);
      assert.equal(second.stdout, `agent-chrome: a browser already answers on 127.0.0.1:${port}; opening nothing\n`);
      assert.equal(readFileSync(join(home, "chrome-args"), "utf8").split("\n").length, 2, "Chrome was started once");
    } finally {
      await site.close();
    }
  });

  test("refuses a malformed command line and a TEAM_CHROME that is not an executable", async () => {
    assert.equal((await script("agent-chrome", ["--port", "x"], { env: env() })).status, 2);
    assert.equal((await script("agent-chrome", ["--bogus"], { env: env() })).status, 2);
    const missing = await script("agent-chrome", ["--port", String(await freePort())], { env: { ...env(), TEAM_CHROME: "/nonexistent/chrome" } });
    assert.equal(missing.status, 1);
    assert.equal(missing.stderr, "agent-chrome: TEAM_CHROME is /nonexistent/chrome, which is not an executable\n");
    const help = await script("agent-chrome", ["--help"]);
    assert.match(help.stdout, /^Start the Agent Chrome: a headed Google Chrome/);
  });
});

// A TCP port nothing listens on.
async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}
