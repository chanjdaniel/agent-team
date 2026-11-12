// The frontend toolkit's scripts against a headless Chrome standing in for the Agent Chrome:
// ui-capture reads the element selected in DevTools on a local fixture page shaped like
// Conventioner's dev build (vite-plugin-vue-inspector's hidden __v_inspector props, a Vue app
// with a router), or the page Daniel is on when nothing is selected, and only localhost pages;
// agent-chrome starts Chrome with its own profile and debugging port. The Chrome is the machine's,
// or TEAM_CHROME, headless and never a window on the screen, and must be current enough for
// open_devtools, which chrome-helper.test.mjs checks fails at once on one too old.
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { connect, createServer } from "node:net";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { promisify } from "node:util";
import { bringToFront, browserSession, chromePath, inspect, serveFixture, serverListing, startChrome } from "./helpers/chrome.mjs";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";

const scripts = join(repoRoot, "toolkits", "frontend", "scripts");
const modules = join(repoRoot, "servers", "node_modules");
const run = promisify(execFile);

// The environment with no worker's role in it, as a builder running these tests has one, which
// ui-capture would hold to its gate; plus <extra>.
function environment(extra = {}) {
  const { AGENT_TEAM_ROLE, AGENT_TEAM_TASK, ...rest } = process.env;
  return { ...rest, ...extra };
}

// A script's exit status, stdout and stderr, whatever the status.
async function script(name, args, options = {}) {
  try {
    const { stdout, stderr } = await run(join(scripts, name), args, { timeout: 120_000, env: environment(), ...options });
    return { status: 0, stdout, stderr };
  } catch (error) {
    if (error.code === undefined || typeof error.code !== "number") throw error;
    return { status: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}

// A page like Conventioner's dev build: each element the inspector tags carries its source in
// __vnode.props.__v_inspector, and a component's elements its instance chain. At load, before any
// capture, it logs an error and a warning, has an image blocked by its content security policy
// (an error the browser logs once the script has run, which reaches a new session after every
// console call and exception, though it came before the next two), throws and leaves a rejection
// unhandled in timers after it, and fetches a path that answers 404, then a local port nothing
// listens on (after the 404, so their order holds); its empty icon, which the policy allows,
// keeps Chrome's favicon request from failing too.
const refused = `http://127.0.0.1:${await freePort()}/api/refused`;
const fixture = `<!doctype html>
<title>Fixture app</title>
<meta http-equiv="Content-Security-Policy" content="img-src data:">
<link rel="icon" href="data:,">
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
</script>
<script>
  console.error("fixture-error: the import preview failed", { id: 7 });
  console.warn("fixture-warning: the event has no dates");
  document.body.append(Object.assign(new Image(), { src: "/blocked.png" }));
  console.log("fixture-log: not a problem");
  fetch("/api/missing").finally(() => fetch("${refused}").catch(() => {}));
  setTimeout(() => {
    throw new Error("fixture-exception: the preview crashed");
  }, 200);
  setTimeout(() => Promise.reject(new Error("fixture-rejection: the save never ran")), 300);
</script>`;
// The line of the fixture holding `text`, as the page's source locations count them.
const fixtureLine = (text) => fixture.split("\n").findIndex((line) => line.includes(text)) + 1;
const elsewhere = 'data:text/html,<title>Elsewhere</title><p>marker-elsewhere</p><script>console.error("marker-elsewhere")</script>';

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
    // An element capture is the element and its page's capture.
    assert.match(help.stdout, /^Capture the element selected[^]*with a capture of the\s+page it is on; or, when nothing is selected, a\s+capture of the localhost page Daniel is on\.\n/);
    assert.match(help.stdout, /\n  1\. the localhost page whose DevTools Elements panel has an element selected: an element\n     capture of it and its page capture, "the selected element's page";\n/);
    assert.match(help.stdout, /\nWrites, creating <out-dir> if needed, for every capture, the page capture:\n  ui-page\.md [^]*\nand, for an element capture, the element's own:\n  ui-pick\.md /);
    // The page's history read over a session of its own, and why the server cannot give it.
    assert.match(help.stdout, /sends Runtime\.enable and Log\.enable[^]*sends Runtime\.disable and Log\.disable and closes: the server is started anew for each capture,\nand its list_console_messages and list_network_requests report nothing from before it\nattached\./);
    assert.match(help.stdout, /This read and the visibility read above are the only ones that speak\nthe protocol to a page without the server, and neither changes the page\./);
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
    // The console problems and failed requests of the page's load, from before ui-capture started,
    // in order, each with its source location (its column aside); the console.log is no problem.
    const at = (text) => `${site.url}:${fixtureLine(text)}:<column>`;
    const [, problems, failed, rest] = page
      .replace(/(:\d+):\d+: /g, "$1:<column>: ")
      .match(/\nConsole problems since the page loaded: 5, oldest first\n\n```\n([^`]*)\n```\n\nFailed requests since the page loaded: 2, oldest first\n\n```\n([^`]*)\n```\n\n([^]*)$/) ?? assert.fail(page);
    const lines = problems.split("\n");
    assert.equal(lines.length, 5, problems);
    assert.equal(lines[0], `error at ${at("fixture-error")}: fixture-error: the import preview failed Object`);
    assert.equal(lines[1], `warning at ${at("fixture-warning")}: fixture-warning: the event has no dates`);
    // The browser's own wording, which a Chrome update may change.
    assert.match(lines[2], new RegExp(`^error \\(security\\) at ${site.url}: .*${site.url}blocked\\.png.*Content Security Policy`));
    assert.equal(lines[3], `exception at ${at("fixture-exception")}: Uncaught Error: fixture-exception: the preview crashed`);
    assert.equal(lines[4], `exception at ${at("fixture-rejection")}: Uncaught (in promise) Error: fixture-rejection: the save never ran`);
    assert.equal(failed, `404 (Not Found) ${site.url}api/missing\nnet::ERR_CONNECTION_REFUSED ${refused}`);
    assert.ok(rest.startsWith("Not recorded: requests still pending, and each request's method.\nThe history starts at the page's last load: a route change inside the app keeps it, a reload clears it.\n"), rest);
    assert.ok(!page.includes("fixture-log"), page);
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

  test("captures the selected element: its page, source and component chains, HTML, matched CSS and screenshots, and its page's capture", async () => {
    await inspect(chrome.browserUrl, site.url, ".menu-button");
    const out = join(tempDir("out"), "ui");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    const head = /^ui-capture: button "Open navigation" .* at button src\/components\/elements\/ElementBanner\.vue:30:5 on /;
    assert.match(result.stdout, head);
    assert.equal(result.stdout.replace(head, ""), `${site.url} -> ${out}/ui-pick.md, ${out}/ui-page.md\n`);
    const pick = readFileSync(join(out, "ui-pick.md"), "utf8");
    assert.match(pick, /^# The selected element\n\nCaptured \d{4}-\d\d-\d\dT[\d:.]+Z by ui-capture from the Agent Chrome at http:\/\/127\.0\.0\.1:\d+\.\n/);
    assert.ok(pick.includes(`Page: ${site.url}\nRoute: /\n`));
    assert.ok(pick.includes(`\nRoute: /\nThe page's state (its title, Vue route, console problems, failed requests and snapshot): ui-page.md\n\n## Where it is\n`), pick);
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
    // The page around it: its own capture, with the page's console problems from its load.
    assertPageCapture(out, site.url, { reason: "the selected element's page", element: true });
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    assert.ok(page.includes("\n- /events/:id/import (event-import): ImportView src/views/events/ImportView.vue\n"), page);
    assert.ok(page.includes("\nConsole problems since the page loaded: 5, oldest first\n"), page);
    assert.ok(page.includes(`\nFailed requests since the page loaded: 2, oldest first\n`), page);
    assert.match(readFileSync(join(out, "page-snapshot.txt"), "utf8"), /button "Open navigation" .*\[selected in the DevTools Elements panel\]/);
    for (const file of ["ui-page.md", "page-snapshot.txt"]) assert.ok(!readFileSync(join(out, file), "utf8").includes("marker-elsewhere"), file);
  });

  // A page capture into the directory of an element capture leaves only its own files.
  test("a page capture after an element capture into the same directory leaves only the page capture", async () => {
    await inspect(chrome.browserUrl, site.url, ".menu-button");
    const out = tempDir("out");
    assert.equal((await script("ui-capture", ["--browser-url", chrome.browserUrl, out])).status, 0);
    assert.ok(existsSync(join(out, "ui-pick.md")) && existsSync(join(out, "element.png")));
    // <html> selected is nothing selected; a null selector would keep the button selected.
    await inspect(chrome.browserUrl, site.url, "html");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assertPageCapture(out, site.url);
  });

  test("finds a selected element outside the accessibility tree in a verbose snapshot", async () => {
    await inspect(chrome.browserUrl, site.url, ".plain");
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(` at div src/App\\.vue:95:5 on ${site.url.replace(/[.]/g, "\\.")} -> ${out}/ui-pick\\.md, ${out}/ui-page\\.md\n$`));
    const pick = readFileSync(join(out, "ui-pick.md"), "utf8");
    assert.ok(pick.includes("- div src/App.vue:95:5\n- div src/App.vue:88:3\n"));
    assert.ok(pick.includes('<div class="plain">Plain text</div>'));
    assertPageCapture(out, site.url, { reason: "the selected element's page", element: true });
  });

  test("fails in one line when the selected element carries no Vue source data", async () => {
    await inspect(chrome.browserUrl, site.url, ".untagged");
    const out = join(tempDir("out"), "ui");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: the page carries no Vue source data \(no __v_inspector on .* or its parents\): a production build, or a Vue DevTools without the inspector\n$/);
    assert.equal(result.stdout, "");
    assert.ok(!existsSync(out), "the out-dir is never made");
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
// The gate team-ui holds a worker to holds a run of the script itself too. Each case reads a port
// nothing listens on, so a run past the gate says no Agent Chrome answers, and none reads a Chrome.
describe("ui-capture in a worker session", () => {
  const events = [
    { ts: "2026-11-05T10:00:00Z", task: "T7", event: "opened", project: "p", path: "small", type: "fix", title: "t", branch: "b", base: "dev", base_sha: "aba9d074", worktree: "/w" },
    { ts: "2026-11-05T10:01:00Z", task: "T7", event: "walk", state: "on", thread: "interview" },
    { ts: "2026-11-05T10:01:00Z", task: "T9", event: "opened", project: "p", path: "small", type: "fix", title: "t", branch: "c", base: "dev", base_sha: "aba9d074", worktree: "/x" },
    { ts: "2026-11-05T10:02:00Z", task: "T9", event: "walk", state: "on" },
  ];
  let home, port, noChrome;
  before(async () => {
    home = tempDir("team-home");
    mkdirSync(join(home, "tasks"), { recursive: true });
    writeFileSync(join(home, "ledger.jsonl"), events.map((event) => JSON.stringify(event)).join("\n") + "\n");
    port = await freePort();
    noChrome = `ui-capture: no Agent Chrome answers at http://127.0.0.1:${port}; start it with toolkits/frontend/scripts/agent-chrome\n`;
  });
  const capture = (role, task, teamHome = home) =>
    script("ui-capture", ["--browser-url", `http://127.0.0.1:${port}`, tempDir("out")], {
      env: environment({ TEAM_HOME: teamHome, AGENT_TEAM_ROLE: role, AGENT_TEAM_TASK: task }),
    });

  test("refuses every role but a planner, its own task's walk on or not", async () => {
    for (const role of ["builder", "reviewer", "ops"]) {
      const result = await capture(role, "T7");
      assert.equal(result.status, 1);
      assert.equal(result.stderr, `ui-capture: a ${role} session takes no capture of the Agent Chrome: that is the coordinator's; send it your message\n`);
    }
  });

  test("refuses a planner with no walk on in its own interview thread", async () => {
    // T9's walk is in its task's own thread, and T11 has none.
    for (const task of ["T9", "T11"]) {
      const result = await capture("planner", task);
      assert.equal(result.status, 1);
      assert.match(result.stderr, new RegExp(`^ui-capture: ${task} has no interview walk on: `));
    }
  });

  test("lets that walk's planner, and the coordinator, past the gate", async () => {
    for (const [role, task] of [["planner", "T7"], ["coordinator", "T9"]]) {
      const result = await capture(role, task);
      assert.equal(result.status, 1);
      assert.equal(result.stderr, noChrome);
    }
  });

  test("refuses when the gate cannot read the ledger, a worker's capture never going on unjudged", async () => {
    const empty = tempDir("no-ledger");
    const result = await capture("planner", "T7", empty);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^ui-capture: T7 has no interview walk on: /);
    // A team home the library refuses says so in its one line.
    const missing = await capture("planner", "T7", join(empty, "missing"));
    assert.equal(missing.status, 1);
    assert.doesNotMatch(missing.stderr, /no Agent Chrome answers/);
    assert.equal(missing.stderr.trimEnd().split("\n").length, 1);
  });
});

describe("ui-capture on a page without a Vue router", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({ "/": '<!doctype html><title>Plain page</title><link rel="icon" href="data:,"><p>No Vue here</p>' });
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
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    assert.ok(page.includes("\nVue route: (no Vue router found)\n"), page);
    assert.ok(page.includes("\nConsole problems since the page loaded: none\n\nFailed requests since the page loaded: none\n"), page);
  });
});

// A localhost page that logs 60 errors at load, the last a long one holding a run of five
// backticks and a line break, and fetches 60 paths that answer 404.
describe("ui-capture on a page with more than 50 problems", () => {
  let site, chrome;
  before(async () => {
    site = await serveFixture({
      "/": `<!doctype html><title>Noisy page</title><link rel="icon" href="data:,">
<script>
  for (let i = 1; i < 60; i++) console.error("noisy-" + i);
  console.error("noisy-60 " + String.fromCharCode(96).repeat(5) + " first line\\nsecond line " + "x".repeat(600));
  // Handled, so a fetch a busy runner's network rejects stays a failed request, and is no problem more.
  for (let i = 1; i <= 60; i++) fetch("/gone-" + i).catch(() => {});
</script>`,
    });
    chrome = await startChrome([site.url]);
  });
  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  test("keeps the last 50 of each, says how many were left out, and fences a backtick run", async () => {
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assertPageCapture(out, site.url, { title: "Noisy page", reason: "the visible localhost tab" });
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    // Each section: its head, then a fence of six backticks around exactly 50 lines.
    const section = (title) => {
      const [, head, fence, body] = page.match(new RegExp(`\\n${title}: ([^\\n]*)\\n\\n(\`+)\\n([^]*?)\\n\\2\\n`));
      return { head, fence, lines: body.split("\n") };
    };
    const problems = section("Console problems since the page loaded");
    // The whole capture as the message, so a count that differs shows what it counted.
    assert.equal(problems.head, "the last 50 of 60, oldest first; the 10 before them are left out", page);
    assert.equal(problems.fence, "``````");
    assert.equal(problems.lines.length, 50);
    assert.deepEqual(
      problems.lines.slice(0, 49).map((line) => line.replace(/^error at \S+: /, "")),
      Array.from({ length: 49 }, (_, i) => `noisy-${i + 11}`),
    );
    // The page's text trimmed to 500 characters, its line break shown as \n.
    const text = `noisy-60 \`\`\`\`\` first line\nsecond line ${"x".repeat(600)}`;
    assert.equal(problems.lines[49].replace(/^error at \S+: /, ""), `${text.slice(0, 500).replace("\n", "\\n")} [trimmed: ${text.length} characters in all]`);
    const failed = section("Failed requests since the page loaded");
    assert.equal(failed.head, "the last 50 of 60, oldest first; the 10 before them are left out", page);
    assert.equal(failed.fence, "```");
    assert.equal(failed.lines.length, 50);
    for (const line of failed.lines) assert.match(line, new RegExp(`^(404 \\(Not Found\\)|net::ERR_\\w+) ${site.url}gone-\\d+$`));
  });
});

// The Agent Chrome seen through a proxy of its debugging address that lists each tab's DevTools
// protocol address as a loopback port of the test's: a relay to Chrome that records what
// ui-capture sends on its own sessions on the page, one nothing listens on, or one that takes the
// connection and never answers. The server, which connects at the browser's own address, is not
// moved, so the capture is taken in each.
describe("ui-capture's own DevTools protocol sessions on the page", () => {
  let site, chrome, proxy, silent, dead, relay;
  let socketPort;
  const held = new Set();
  const sent = [];
  before(async () => {
    site = await serveFixture({ "/": '<!doctype html><title>Unread page</title><link rel="icon" href="data:,"><script>console.error("unread-marker")</script>' });
    chrome = await startChrome([site.url]);
    dead = await freePort();
    silent = createServer((socket) => held.add(socket));
    await new Promise((resolve) => silent.listen(0, "127.0.0.1", resolve));
    // Each text frame the client sends after its upgrade request, unmasked (RFC 6455), as JSON.
    relay = createServer((client) => {
      const upstream = connect(Number(new URL(chrome.browserUrl).port), "127.0.0.1");
      held.add(client).add(upstream);
      client.on("error", () => {});
      upstream.on("error", () => {});
      client.pipe(upstream).pipe(client);
      let buffer = Buffer.alloc(0);
      let upgraded = false;
      client.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (!upgraded) {
          const end = buffer.indexOf("\r\n\r\n");
          if (end === -1) return;
          buffer = buffer.subarray(end + 4);
          upgraded = true;
        }
        for (;;) {
          if (buffer.length < 2) return;
          let length = buffer[1] & 127;
          let offset = 2;
          if (length === 126) [length, offset] = buffer.length < 4 ? [Infinity, 4] : [buffer.readUInt16BE(2), 4];
          else if (length === 127) [length, offset] = buffer.length < 10 ? [Infinity, 10] : [Number(buffer.readBigUInt64BE(2)), 10];
          const mask = buffer[1] & 128 ? buffer.subarray(offset, offset + 4) : null;
          if (mask) offset += 4;
          if (buffer.length < offset + length) return;
          const payload = Buffer.from(buffer.subarray(offset, offset + length));
          if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
          if ((buffer[0] & 15) === 1) sent.push(JSON.parse(payload));
          buffer = buffer.subarray(offset + length);
        }
      });
    });
    await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
    proxy = createHttpServer(async (request, response) => {
      const answer = await fetch(new URL(request.url, chrome.browserUrl));
      let body = await answer.text();
      if (request.url.startsWith("/json/list")) {
        const moved = (t) => (t.webSocketDebuggerUrl ? { ...t, webSocketDebuggerUrl: t.webSocketDebuggerUrl.replace(/^ws:\/\/[^/]+/, `ws://127.0.0.1:${socketPort}`) } : t);
        body = JSON.stringify(JSON.parse(body).map(moved));
      }
      response.writeHead(answer.status, { "content-type": "application/json; charset=UTF-8" });
      response.end(body);
    });
    await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  });
  after(async () => {
    for (const socket of held) socket.destroy();
    await new Promise((resolve) => silent?.close(resolve));
    await new Promise((resolve) => relay?.close(resolve));
    await new Promise((resolve) => proxy?.close(resolve));
    await chrome?.close();
    await site?.close();
  });

  const capture = async () => {
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", `http://127.0.0.1:${proxy.address().port}`, out]);
    assert.equal(result.status, 0, result.stderr);
    return out;
  };

  // The two reads that change nothing: the tab's visibility and focus, then the page's history.
  test("sends the page only its visibility read and the history read's enables and disables", async () => {
    socketPort = relay.address().port;
    const out = await capture();
    assertPageCapture(out, site.url, { title: "Unread page", reason: "the visible localhost tab" });
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    assert.ok(page.includes(`\nConsole problems since the page loaded: 1, oldest first\n\n\`\`\`\nerror at ${site.url}:1:`), page);
    assert.deepEqual(
      sent.map(({ method }) => method),
      ["Runtime.evaluate", "Runtime.enable", "Log.enable", "Runtime.disable", "Log.disable"],
    );
    assert.match(sent[0].params.expression, /^\(\{ visible: document\.visibilityState === 'visible', focus: document\.hasFocus\(\) \}\)$/);
    for (const { params } of sent.slice(1)) assert.equal(params, undefined);
  });

  const unread = async (why) => {
    const out = await capture();
    // The tab's visibility is unread too, so it is no visible tab, yet gets its screenshot.
    assertPageCapture(out, site.url, { title: "Unread page", reason: "the most recently active localhost tab; none is visible" });
    const page = readFileSync(join(out, "ui-page.md"), "utf8");
    const line = (title) => `\n${title}: the history could not be read: ${why}\n`;
    assert.ok(page.includes(line("Console problems since the page loaded")) && page.includes(line("Failed requests since the page loaded")), page);
    assert.ok(!page.includes("unread-marker"), page);
  };

  test("says so when no session on the page can be opened", async () => {
    socketPort = dead;
    await unread("no DevTools protocol session could be opened on it");
  });

  test("says so when the page gives no answer in 10 s", async () => {
    socketPort = silent.address().port;
    await unread("the page gave no answer in 10 s (a busy machine can cause it, or a hung page)");
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
// ui-page.md's lines, a PNG of the viewport, the snapshot, and an element capture's files only
// when `element` says it is the page of one; a tab that is not `visible` has no screenshots.
function assertPageCapture(out, url, { title = "Fixture app", route = "/", reason = "DevTools is open on it, nothing selected", others = "none", visible = true, element = false } = {}) {
  const files = [...(visible ? ["page.png"] : []), "page-snapshot.txt", "ui-page.md", ...(element ? ["ui-pick.md", ...(visible ? ["element.png"] : [])] : [])];
  assert.deepEqual(readdirSync(out).sort(), files.sort());
  const page = readFileSync(join(out, "ui-page.md"), "utf8");
  // bin/team-post reads where the page came from in these two fixed lines, the third and the fourth.
  assert.match(page, /^# The page capture\n\nCaptured \d{4}-\d\d-\d\dT[\d:.]+Z by ui-capture from the Agent Chrome at http:\/\/127\.0\.0\.1:\d+\.\nPage: http:\/\/(localhost|127\.0\.0\.1):\d+\//);
  assert.ok(page.includes(`\nPage: ${url}\nRoute: ${route}\nTitle: ${title}\n\nTaken because: ${reason}\nOther localhost tabs: ${others}\n`), page);
  const shot = visible
    ? "- page.png: the viewport, as Daniel sees it"
    : "- no page.png: the tab is not visible, and Chrome paints no hidden tab, so it has no screenshot";
  assert.match(page, /\nConsole problems since the page loaded: [^]*\nFailed requests since the page loaded: /);
  const note = "Not recorded: requests still pending, and each request's method.\nThe history starts at the page's last load: a route change inside the app keeps it, a reload clears it.\n";
  const elementShot = visible ? "- element.png: a screenshot of the selected element" : "- no element.png: the tab is not visible, as for page.png";
  const elementFiles = `- ui-pick.md: the selected element: its source and component chains, HTML and matched CSS\n${elementShot}\n`;
  assert.ok(page.endsWith(`\n${note}\nFiles:\n\n${shot}\n- page-snapshot.txt: the page's accessibility snapshot (take_snapshot)\n${element ? elementFiles : ""}`), page);
  if (!element) assert.ok(!page.includes("ui-pick.md") && !page.includes("element.png"), page);
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
    offsite = 'data:text/html,<title>Off localhost</title><p>marker-offsite</p><script>console.error("marker-offsite")</script>';
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
  // `visible`: whether the taken tab is its window's front tab, false for one in step 4.
  const capture = async (url, reason, others, visible = !reason.includes("none is visible")) => {
    const out = tempDir("out");
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `ui-capture: page ${url} (${reason}), no element selected -> ${out}/ui-page.md\n`);
    const title = url === first ? "Fixture app" : "Second page";
    // A hidden tab gets no screenshot.
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
    // Its tab is behind the second one, so hidden, with no screenshot.
    await capture(first, "DevTools is open on it, nothing selected", second, false);
  });

  // Daniel inspects an element, then clicks another tab: the element's tab is hidden, which Chrome
  // paints nothing of, so neither screenshot can be taken.
  test("captures an element selected on a tab that is no longer in front, without screenshots", async () => {
    await inspect(chrome.browserUrl, first, ".menu-button");
    await bringToFront(chrome.browserUrl, second);
    const out = tempDir("out");
    const started = Date.now();
    const result = await script("ui-capture", ["--browser-url", chrome.browserUrl, out]);
    // Not a screenshot's 30 s wait on a tab Chrome never paints.
    assert.ok(Date.now() - started < 20_000, `took ${Date.now() - started} ms`);
    assert.equal(result.status, 0, result.stderr);
    const head = /^ui-capture: button "Open navigation" .* at button src\/components\/elements\/ElementBanner\.vue:30:5 on /;
    assert.match(result.stdout, head);
    assert.equal(result.stdout.replace(head, ""), `${first} -> ${out}/ui-pick.md, ${out}/ui-page.md\n`);
    const pick = readFileSync(join(out, "ui-pick.md"), "utf8");
    assert.ok(pick.endsWith("\n## Screenshots\n\n- no element.png or page.png: the tab is not visible, and Chrome paints no hidden tab, so it has no screenshot\n"), pick);
    assertPageCapture(out, first, { reason: "the selected element's page", others: second, visible: false, element: true });
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
