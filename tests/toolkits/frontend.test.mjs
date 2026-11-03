// The frontend toolkit's scripts against a headless Chrome standing in for the Agent Chrome:
// ui-capture reads the element selected in DevTools on a local fixture page shaped like
// Conventioner's dev build (vite-plugin-vue-inspector's hidden __v_inspector props, a Vue app
// with a router), or the page Daniel is on when nothing is selected, and only localhost pages;
// agent-chrome starts Chrome with its own profile and debugging port.
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { chmodSync, existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { promisify } from "node:util";
import { bringToFront, browserSession, chromePath, inspect, serveFixture, serverListing, startChrome } from "./helpers/chrome.mjs";
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
<div id="app" data-v-app="">
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
  // The Vue 3 app on the element it is mounted on, its router at the current route's matched
  // records, outermost first, as vue-router 4 keeps them once the lazy components resolved.
  const component = (name, file) => ({ __name: name, __file: "/home/x/front-end/" + file });
  const matched = [
    { path: "/events/:id", name: undefined, components: { default: component("EventLayout", "src/layouts/EventLayout.vue") } },
    { path: "/events/:id/import", name: "event-import", components: { default: component("ImportView", "src/views/events/ImportView.vue") } },
  ];
  document.querySelector("#app").__vue_app__ = { config: { globalProperties: { $router: { currentRoute: { value: { matched } } } } } };
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

  // A Chrome started under a HOME with no login keychain (a test's) and without these raises
  // macOS's "A keychain cannot be found to store Chrome Safe Storage" on Daniel's screen.
  test("the stand-in Chrome runs with the mock keychain and the basic password store", () => {
    const args = execFileSync("ps", ["-o", "args=", "-p", String(chrome.pid)], { encoding: "utf8" });
    assert.match(args, / --use-mock-keychain /);
    assert.match(args, / --password-store=basic /);
  });

  // In the default context a page's first request can wait minutes for the profile's cookie
  // database on a busy Mac.
  test("the stand-in Chrome's every page is off the record, none in the default context", async () => {
    const browser = await browserSession(chrome.browserUrl);
    try {
      const { defaultBrowserContextId } = await browser.send("Target.getBrowserContexts");
      const pages = (await browser.send("Target.getTargets")).targetInfos.filter((t) => t.type === "page");
      assert.deepEqual(pages.map((t) => t.url).sort(), [site.url, elsewhere].sort());
      for (const page of pages) assert.notEqual(page.browserContextId, defaultBrowserContextId, page.url);
    } finally {
      browser.close();
    }
  });

  test("refuses a malformed command line and answers --help with its header", async () => {
    assert.equal((await script("ui-capture", [])).status, 2);
    assert.equal((await script("ui-capture", ["--browser-url", "http://example.com:9222", tempDir("out")])).status, 2);
    const help = await script("ui-capture", ["--help"]);
    assert.equal(help.status, 0);
    assert.match(help.stdout, /^Capture the element selected in the Agent Chrome's DevTools Elements panel/);
    assert.match(help.stdout, /Usage: ui-capture \[--browser-url <url>\] <out-dir>/);
    // The active-page rule, its four steps in order, each with the reason the capture gives.
    assert.match(
      help.stdout,
      new RegExp(
        [
          "The page it takes, the first that applies:",
          "  1\\. the localhost page whose DevTools Elements panel has an element selected[^]*",
          "  2\\. else a localhost page with DevTools open and nothing selected[^]*\"DevTools is\\s+open on it, nothing selected\";",
          "  3\\. else the visible localhost tab[^]*\"the visible localhost tab\";",
          "  4\\. else, when no localhost tab is visible[^]*the most recently active localhost tab[^]*\"the most recently active\\s+localhost tab; none is visible\"\\.",
          "Recency is the order of the Agent Chrome's /json/list, most recently active first\\.",
        ].join("\n"),
      ),
    );
  });

  test("fails in one line when no Agent Chrome answers", async () => {
    const port = await freePort();
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", `http://127.0.0.1:${port}`, out]);
    assert.equal(result.status, 1);
    assert.equal(result.stderr, `ui-capture: no Agent Chrome answers at http://127.0.0.1:${port}; start it with toolkits/frontend/scripts/agent-chrome\n`);
    assert.ok(!existsSync(join(out, "ui-pick.md")));
  });

  // In order: DevTools open on another page only, DevTools open on the fixture's default <body>,
  // then <html>, then each selection.
  test("captures the most recently active localhost tab when DevTools is open on another page only", async () => {
    await inspect(chrome.browserUrl, elsewhere, "p");
    await bringToFront(chrome.browserUrl, elsewhere);
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    const reason = "the most recently active localhost tab; none is visible";
    assert.equal(result.stdout, `ui-capture: page ${site.url} (${reason}), no element selected -> ${out}/ui-page.md\n`);
    assertPageCapture(out, site.url, { reason, visible: false });
    // The other page is never read: nothing of it reaches the output or a file.
    assert.ok(!`${result.stdout}${result.stderr}`.includes("marker-elsewhere"));
    for (const file of ["ui-page.md", "page-snapshot.txt"]) assert.ok(!readFileSync(join(out, file), "utf8").includes("marker-elsewhere"), file);
  });

  test("captures the page when DevTools is open on it and nothing is selected", async () => {
    await inspect(chrome.browserUrl, site.url, null);
    const out = join(tempDir("out"), "ui");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `ui-capture: page ${site.url} (DevTools is open on it, nothing selected), no element selected -> ${out}/ui-page.md\n`);
    assertPageCapture(out, site.url);
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    assert.ok(page.includes("\nVue route: the current route's matched records, outermost first (path, name, component and file)\n\n- /events/:id: EventLayout src/layouts/EventLayout.vue\n- /events/:id/import (event-import): ImportView src/views/events/ImportView.vue\n"), page);
    // The snapshot is the page's own, with DevTools' note that its selection is not in it.
    const snapshot = readFileSync(join(out, "page-snapshot.txt"), "utf8");
    assert.match(snapshot, /RootWebArea "Fixture app"/);
    assert.match(snapshot, /button "Open navigation"/);
    for (const file of ["ui-page.md", "page-snapshot.txt"]) assert.ok(!readFileSync(join(out, file), "utf8").includes("marker-elsewhere"), file);
  });

  test("captures the page when the element selected is <html>", async () => {
    await inspect(chrome.browserUrl, site.url, "html");
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `ui-capture: page ${site.url} (DevTools is open on it, nothing selected), no element selected -> ${out}/ui-page.md\n`);
    assertPageCapture(out, site.url);
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

  // A failed capture leaves the directory as it found it: an earlier capture stays whole.
  test("a failed capture writes and removes nothing", async () => {
    const out = staleCapture();
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: the page carries no Vue source data /);
    assert.deepEqual(readdirSync(out).sort(), ["element.png", "ui-pick.md"]);
    assert.equal(readFileSync(join(out, "ui-pick.md"), "utf8"), "stale\n");
  });
});

// A localhost page with no Vue app on it, as a production build or another dev server.
describe("ui-capture on a page without a Vue router", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({ "/": "<!doctype html><title>Plain page</title><p>No Vue here</p>" });
    chrome = await startChrome([site.url]);
  });
  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  test("still captures the page, with no Vue router found, and removes the earlier element capture", async () => {
    await inspect(chrome.browserUrl, site.url, null);
    const out = staleCapture();
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assertPageCapture(out, site.url, { title: "Plain page" });
    assert.ok(readFileSync(join(out, "ui-page.md"), "utf8").includes("\nVue route: (no Vue router found)\n"));
  });
});

// A directory holding an earlier element capture's files, which a page capture does not write.
function staleCapture() {
  const out = tempDir("out");
  writeFileSync(join(out, "ui-pick.md"), "stale\n");
  writeFileSync(join(out, "element.png"), "stale\n");
  return out;
}

// A page capture of `url` in `out`, taken for `reason`, with `others` the other localhost tabs:
// ui-page.md's lines, a PNG of the viewport, the snapshot, and none of an element capture's files.
function assertPageCapture(out, url, { title = "Fixture app", route = "/", reason = "DevTools is open on it, nothing selected", others = "none", visible = true } = {}) {
  assert.deepEqual(readdirSync(out).sort(), visible ? ["page-snapshot.txt", "page.png", "ui-page.md"] : ["page-snapshot.txt", "ui-page.md"]);
  const page = readFileSync(join(out, "ui-page.md"), "utf8");
  assert.match(page, /^# The page capture\n\nCaptured \d{4}-\d\d-\d\dT[\d:.]+Z by ui-capture from the Agent Chrome at http:\/\/127\.0\.0\.1:\d+\.\n/);
  assert.ok(page.includes(`\nPage: ${url}\nRoute: ${route}\nTitle: ${title}\n\nTaken because: ${reason}\nOther localhost tabs: ${others}\n`), page);
  const shot = visible
    ? "- page.png: the viewport, as Daniel sees it"
    : "- no page.png: the tab is not visible, and Chrome paints no hidden tab, so it has no screenshot";
  assert.ok(page.includes(`\nFiles:\n\n${shot}\n- page-snapshot.txt: the page's accessibility snapshot (take_snapshot)\n`), page);
  assert.ok(!page.includes("ui-pick.md") && !page.includes("element.png"), page);
  if (visible) assert.deepEqual([...readFileSync(join(out, "page.png")).subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "page.png is a PNG");
  assert.match(readFileSync(join(out, "page-snapshot.txt"), "utf8"), new RegExp(`RootWebArea "${title}"`));
}

// The Agent Chrome with DevTools closed on every page: two localhost tabs and one off localhost,
// which Daniel's clicks bring to the front in turn. The off-localhost page's marker must reach
// nothing, and its tab is never attached to, which the browser reports to a session that
// discovers targets.
describe("ui-capture with DevTools closed", () => {
  let site, chrome, first, second, offsite, browser;
  const attached = [];
  before(async () => {
    site = await serveFixture({ "/": fixture, "/second": "<!doctype html><title>Second page</title><p>The second tab</p>" });
    first = site.url;
    second = `${site.url}second`;
    offsite = "data:text/html,<title>Off localhost</title><p>marker-offsite</p>";
    chrome = await startChrome([first, second, offsite]);
    browser = await browserSession(chrome.browserUrl);
    browser.on("Target.targetInfoChanged", ({ targetInfo }) => targetInfo.attached && attached.push(targetInfo.url));
    await browser.send("Target.setDiscoverTargets", { discover: true });
  });
  after(async () => {
    browser?.close();
    await chrome?.close();
    await site?.close();
  });
  const capture = async (url, reason, others) => {
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `ui-capture: page ${url} (${reason}), no element selected -> ${out}/ui-page.md\n`);
    const title = url === first ? "Fixture app" : "Second page";
    // A tab in step 4 is hidden, and gets no screenshot.
    const visible = !reason.includes("none is visible");
    assertPageCapture(out, url, { title, route: new URL(url).pathname, reason, others, visible });
    for (const file of readdirSync(out)) assert.ok(!readFileSync(join(out, file), "utf8").includes("marker-offsite"), file);
    assert.ok(!`${result.stdout}${result.stderr}`.includes("marker-offsite"));
    return out;
  };

  test("captures the visible localhost tab", async () => {
    await bringToFront(chrome.browserUrl, first);
    const out = await capture(first, "the visible localhost tab", second);
    assert.ok(readFileSync(join(out, "ui-page.md"), "utf8").includes("\n- /events/:id/import (event-import): ImportView src/views/events/ImportView.vue\n"));
  });

  test("captures the other localhost tab once it is brought to the front", async () => {
    await bringToFront(chrome.browserUrl, second);
    await capture(second, "the visible localhost tab", first);
  });

  test("captures the most recently active localhost tab when the off-localhost tab is in front, and never attaches to that one", async () => {
    await bringToFront(chrome.browserUrl, first);
    await bringToFront(chrome.browserUrl, offsite);
    await capture(first, "the most recently active localhost tab; none is visible", second);
    // Every capture so far attached to the localhost tabs only.
    assert.ok(attached.includes(first) && attached.includes(second), attached.join(", "));
    assert.deepEqual(attached.filter((url) => !url.startsWith(site.url) && /^(data|https?):/.test(url)), []);
  });

  test("takes the localhost page DevTools is open on over the visible one", async () => {
    await inspect(chrome.browserUrl, first, null);
    await bringToFront(chrome.browserUrl, second);
    await capture(first, "DevTools is open on it, nothing selected", second);
  });
});

// The Agent Chrome open on a page off localhost only.
describe("ui-capture with no localhost page open", () => {
  let chrome;
  before(async () => {
    chrome = await startChrome(["data:text/html,<title>Off localhost</title><p>marker-offsite</p>"]);
  });
  after(async () => {
    await chrome?.close();
  });

  test("fails in one line and writes nothing", async () => {
    const out = join(tempDir("out"), "ui");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.equal(result.stderr, "ui-capture: the Agent Chrome has no localhost page open\n");
    assert.equal(result.stdout, "");
    assert.ok(!existsSync(out));
  });
});

// A page that never answers the DevTools protocol (here a script that never ends; on a busy
// machine, a starved or hung renderer) stops the capture in one line, not a stack trace, after
// the 30 s each call is given.
describe("ui-capture on a page that does not answer", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({ "/": "<!doctype html><title>Busy</title><script>setTimeout(() => { for (;;) {} }, 200)</script>" });
    chrome = await startChrome([site.url]);
  });
  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  test("says the page does not answer, and what to do", async () => {
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: [a-z_]+ got no answer in 30 s: a page of the Agent Chrome does not answer \(a busy machine can cause it, or a hung page\); reload it, or wait, and try again\n$/);
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
    const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 90_000 });
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
    const { server, pages } = await serverListing(() => declaredServer(chrome.browserUrl), site.url);
    try {
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
        `--user-data-dir=${home}/.local/share/agent-team/agent-chrome --remote-debugging-port=${port} --no-first-run --no-default-browser-check --use-mock-keychain --password-store=basic ${site.url}\n`,
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
