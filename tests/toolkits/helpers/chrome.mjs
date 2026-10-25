// A headless Chrome standing in for the Agent Chrome, and Daniel's hand in its DevTools.
//
//   const site = await serveFixture({ "/": html });   a local page server on 127.0.0.1
//   const chrome = await startChrome([site.url, "data:text/html,..."]);
//   chrome.browserUrl                                 http://127.0.0.1:<port>, its remote debugging
//   chrome.pid                                        its process
//   await inspect(chrome.browserUrl, site.url, "button.menu");   Inspect: DevTools open on that
//                                                     page, the element selected in Elements
//   const { server, pages } = await serverListing(connect, url);   a server whose list names url
//   await chrome.close(); await site.close();
//
// Chrome is the machine's (TEAM_CHROME, else Google Chrome's app on macOS, else google-chrome or
// chromium on PATH), started with a throwaway profile, the mock keychain and the basic password
// store (no keychain prompt under the test's HOME), and no first-run, sync or metrics. inspect
// drives the DevTools window through the pinned chrome-devtools-mcp with --experimentalDevtools
// and --devtoolsComments (which brings open_devtools),
// setting the Elements panel's selection exactly as a click there does; ui-capture never runs
// with that flag.
import { spawn, execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { repoRoot, tempDir } from "./mcp.mjs";

const modules = join(repoRoot, "servers", "node_modules");
const devtoolsServer = join(modules, "chrome-devtools-mcp", "build", "src", "bin", "chrome-devtools-mcp.js");

export function chromePath() {
  const candidates = [process.env.TEAM_CHROME, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"];
  for (const name of ["google-chrome-stable", "google-chrome", "chromium", "chromium-browser"]) {
    try {
      candidates.push(execFileSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" }).trim());
    } catch {
      // not on PATH
    }
  }
  const found = candidates.find((path) => path && existsSync(path));
  if (!found) throw new Error("no Chrome found: set TEAM_CHROME, or install Google Chrome or Chromium");
  return found;
}

// A page server on 127.0.0.1, an ephemeral port, serving `pages` ({ path: html }).
export async function serveFixture(pages) {
  const server = createServer((request, response) => {
    const page = pages[new URL(request.url, "http://x").pathname];
    response.writeHead(page === undefined ? 404 : 200, { "content-type": "text/html; charset=utf-8" });
    response.end(page ?? "not found");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}/`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

// Headless Chrome on an ephemeral debugging port, a tab for each of `urls`; resolves once each
// tab has loaded (shows its URL and title). On a busy machine a tab can wait a long time for its
// first request, and a tab that has not loaded never answers the DevTools protocol, so a tab not
// loaded within 20 s is closed and opened again, twice, and then the whole Chrome is started
// again, twice at most.
export async function startChrome(urls) {
  for (let launch = 1; ; launch++) {
    const chrome = await launchChrome(urls);
    let targets = [];
    for (let round = 1; round <= 3; round++) {
      const deadline = Date.now() + 20_000;
      while (Date.now() < deadline) {
        targets = await fetch(`${chrome.browserUrl}/json/list`, { signal: AbortSignal.timeout(5000) })
          .then((r) => r.json())
          .catch(() => []);
        if (urls.every((url) => loaded(targets, url))) return chrome;
        await sleep(100);
      }
      for (const url of urls.filter((url) => !loaded(targets, url))) {
        for (const t of targets.filter((t) => t.type === "page" && t.url === url)) {
          await fetch(`${chrome.browserUrl}/json/close/${t.id}`, { signal: AbortSignal.timeout(5000) }).catch(() => {});
        }
        await fetch(`${chrome.browserUrl}/json/new?${encodeURI(url)}`, { method: "PUT", signal: AbortSignal.timeout(10_000) }).catch(() => {});
      }
    }
    await chrome.close();
    if (launch === 3) {
      const tabs = targets.filter((t) => t.type === "page").map((t) => `${t.url} "${t.title}"`);
      throw new Error(`Chrome did not load ${urls.join(", ")} in three launches; its tabs: ${tabs.join(", ") || "none"}`);
    }
  }
}

// Whether the browser's targets show a page at `url` with its own title, loaded.
const loaded = (targets, url) => targets.some((t) => t.type === "page" && t.url === url && t.title && t.title !== url);

// One headless Chrome, its tabs opened but not waited for.
async function launchChrome(urls) {
  const profile = tempDir("chrome-profile");
  const child = spawn(
    chromePath(),
    [
      "--headless=new",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-sync",
      "--disable-background-networking",
      "--metrics-recording-only",
      "--use-mock-keychain",
      "--password-store=basic",
      // A laptop-sized window, so DevTools docked beside the page leaves it a usable width.
      "--window-size=1600,1000",
      urls[0],
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  // Chrome's own logging, kept for the error should it never open its port.
  let log = "";
  child.stderr.on("data", (chunk) => (log = (log + chunk).slice(-4000)));
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const close = async () => {
    child.kill("SIGTERM");
    await Promise.race([exited, sleep(5000).then(() => child.kill("SIGKILL"))]);
  };
  let port;
  for (let i = 0; i < 600 && !port; i++) {
    try {
      port = readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0];
    } catch {
      await sleep(50);
    }
  }
  if (!port) {
    await close();
    throw new Error(`Chrome did not open its debugging port:\n${log}`);
  }
  const browserUrl = `http://127.0.0.1:${port}`;
  // Headless Chrome opens one URL from its command line; the others are new tabs.
  for (const url of urls.slice(1)) {
    await fetch(`${browserUrl}/json/new?${encodeURI(url)}`, { method: "PUT", signal: AbortSignal.timeout(10_000) });
  }
  return { browserUrl, pid: child.pid, close };
}

// An MCP client of the pinned chrome-devtools-mcp attached to the browser; `call` returns text.
export async function devtoolsClient(browserUrl, flags = []) {
  const { Client } = await import(join(modules, "@modelcontextprotocol", "sdk", "dist", "esm", "client", "index.js"));
  const { StdioClientTransport } = await import(join(modules, "@modelcontextprotocol", "sdk", "dist", "esm", "client", "stdio.js"));
  const client = new Client({ name: "toolkit-test", version: "0" });
  await client.connect(
    new StdioClientTransport({
      command: process.execPath,
      args: [devtoolsServer, `--browser-url=${browserUrl}`, "--no-usage-statistics", "--no-performance-crux", "--no-page-id-routing", ...flags],
      env: { PATH: process.env.PATH, HOME: process.env.HOME, CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS: "1", CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" },
      stderr: "ignore",
    }),
  );
  const call = async (name, args = {}) => {
    // Generous: the helper stands in for Daniel's hand on a test machine that may be very busy.
    const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 90_000 });
    const text = result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
    if (result.isError) throw new Error(`${name}: ${text}`);
    return text;
  };
  return { call, close: () => client.close() };
}

// Ask `connect()` for a server until its list_pages names `url`, as `listed` in inspect does:
// resolves to { server, pages }.
export async function serverListing(connect, url) {
  for (let connection = 1; connection <= 3; connection++) {
    const server = await connect();
    for (let attempt = 0; attempt < 30; attempt++) {
      const pages = await server.call("list_pages");
      if (pages.includes(`(${url})`)) return { server, pages };
      await sleep(100);
    }
    await server.close();
  }
  throw new Error(`no server listed ${url}`);
}

// Daniel's Inspect on the page at `pageUrl`: DevTools opened on it, then (unless `selector` is
// null, leaving DevTools' own default selection) the element matching `selector` selected in
// the Elements panel.
export async function inspect(browserUrl, pageUrl, selector) {
  const flags = ["--experimentalDevtools", "--devtoolsComments"];
  const deadline = Date.now() + 180_000;
  const inTime = () => {
    if (Date.now() > deadline) throw new Error(`inspect ${selector} on ${pageUrl}: not done in 180 s`);
  };
  let devtools;
  const reconnect = async () => {
    await devtools?.close().catch(() => {});
    devtools = await devtoolsClient(browserUrl, flags);
  };
  await reconnect();
  try {
    const pageIds = (list, test) =>
      [...list.matchAll(/^(\d+): (.*?)( \[selected\])?$/gm)]
        .filter(([, , rest]) => test(rest.endsWith(")") ? rest.slice(rest.lastIndexOf(" (") + 2, -1) : rest))
        .map(([, id]) => Number(id));
    // The server lists a tab once it has attached to it: slowly on a busy machine, or never on
    // that connection when the attach failed, so ask again, and after 30 asks on a new connection.
    const listed = async (test) => {
      for (;;) {
        for (let attempt = 0; attempt < 30; attempt++) {
          inTime();
          const ids = pageIds(await devtools.call("list_pages"), test);
          if (ids.length) return ids;
          await sleep(100);
        }
        await reconnect();
      }
    };
    const [app] = await listed((url) => url === pageUrl);
    await devtools.call("select_page", { pageId: app });
    await devtools.call("open_devtools");
    if (selector === null) return;
    // Each DevTools window, until the one inspecting that page. While every window listed
    // inspects another page or has not loaded its Elements panel yet, ask again, and every tenth
    // pass on a new connection, which attaches to a window the last one missed.
    for (let pass = 1; ; pass++) {
      for (const window of await listed((url) => url.startsWith("devtools://"))) {
        inTime();
        await devtools.call("select_page", { pageId: window });
        const result = await devtools.call("evaluate_script", {
          function: `async () => {
            const SDK = await import('/bundled/core/sdk/sdk.js');
            const UI = await import('/bundled/ui/legacy/legacy.js');
            let current = null;
            for (let i = 0; i < 20 && !current; i++) {
              current = UI.Context.Context.instance().flavor(SDK.DOMModel.DOMNode);
              if (!current) await new Promise((r) => setTimeout(r, 100));
            }
            if (!current) return 'not loaded';
            if (current.domModel().target().inspectedURL() !== ${JSON.stringify(pageUrl)}) return 'another page';
            const dom = current.domModel();
            const doc = await dom.requestDocument();
            const id = await dom.querySelector(doc.id, ${JSON.stringify(selector)});
            if (!id) return 'no element matches';
            UI.Context.Context.instance().setFlavor(SDK.DOMModel.DOMNode, dom.nodeForId(id));
            return 'selected';
          }`,
        });
        if (result.includes('"selected"')) return;
        if (!result.includes('"another page"') && !result.includes('"not loaded"')) throw new Error(`inspect ${selector}: ${result}`);
      }
      if (pass % 10 === 0) await reconnect();
      else await sleep(200);
    }
  } finally {
    await devtools?.close();
  }
}
