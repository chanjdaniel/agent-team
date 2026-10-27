// The browser toolkit as team-worker --toolkit browser loads it: its plugin layout; its one
// SessionStart hook run as Claude Code runs a plugin's hook, with CLAUDE_PLUGIN_ROOT set to the
// toolkit and a stub chrome-devtools-axi first on PATH, under the user settings of today and under
// the guarded ones the PR proposes; and its ui-check skill, whose every chrome-devtools-axi command
// runs here on the client servers/ pins, headless, against a fixture site.
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { promisify } from "node:util";
import { chromePath, serveFixture } from "./helpers/chrome.mjs";
import { repoRoot, tempDir, testPath } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "browser");
const hooks = JSON.parse(readFileSync(join(toolkit, "hooks", "hooks.json"), "utf8"));
const banner = "chrome-devtools-axi banner";

// The hook's Bash 5 and jq, found where the caller's PATH has them (Homebrew's on macOS, whose
// /bin/bash is 3.2), linked into a directory of their own so nothing else of that PATH comes along.
const tools = tempDir("tools");
for (const name of ["bash", "jq"]) {
  symlinkSync(execFileSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" }).trim(), join(tools, name));
}

// A HOME whose user settings run each SessionStart command given, and a stub chrome-devtools-axi.
function machine(commands) {
  const home = tempDir("home");
  mkdirSync(join(home, ".claude"));
  writeFileSync(join(home, ".claude", "settings.json"), JSON.stringify({
    hooks: { SessionStart: commands.map((command) => ({ matcher: "", hooks: [{ type: "command", command, timeout: 10 }] })) },
  }));
  const stubs = tempDir("stubs");
  writeFileSync(join(stubs, "chrome-devtools-axi"), `#!/bin/sh\necho '${banner}'\n`, { mode: 0o755 });
  return { home, path: `${stubs}:${tools}:${testPath({ withOp: false })}` };
}

// The hook's command through a shell, as Claude Code runs a plugin hook: CLAUDE_PLUGIN_ROOT in its
// environment and the SessionStart event on stdin.
function runHook({ home, path }, role) {
  const { command } = hooks.hooks.SessionStart[0].hooks[0];
  return execFileSync("sh", ["-c", command], {
    cwd: home,
    encoding: "utf8",
    input: JSON.stringify({ session_id: "3169fcbd-0000-4000-8000-000000000000", hook_event_name: "SessionStart", source: "startup" }),
    env: { HOME: home, PATH: path, CLAUDE_PLUGIN_ROOT: toolkit, AGENT_TEAM_ROLE: role },
  });
}

describe("the browser toolkit", () => {
  test("is a plugin named browser with one hook, no MCP server and one skill, ui-check", () => {
    const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
    assert.equal(manifest.name, "browser");
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "hooks", "skills"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills")), ["ui-check"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills", "ui-check")), ["SKILL.md"]);
    assert.deepEqual(Object.keys(hooks.hooks), ["SessionStart"]);
    assert.equal(hooks.hooks.SessionStart.length, 1);
    assert.deepEqual(hooks.hooks.SessionStart[0].hooks, [{
      type: "command",
      command: '"${CLAUDE_PLUGIN_ROOT}/../../bin/hooks/axi-banner" chrome-devtools-axi',
      timeout: 10,
    }]);
  });

  test("its hook prints nothing while the user settings print the banner in every session", () => {
    const out = runHook(machine(["gh-axi", "chrome-devtools-axi", "lavish-axi"]), "builder");
    assert.equal(out, "");
  });

  test("its hook prints the banner once the user settings print it outside the team only", () => {
    const guarded = (tool) => `[ -n "$AGENT_TEAM_ROLE" ] || ${tool}`;
    const out = runHook(machine([guarded("gh-axi"), guarded("chrome-devtools-axi"), guarded("lavish-axi")]), "reviewer");
    assert.equal(out, `${banner}\n`);
  });

  test("its README says when the coordinator gives it", () => {
    const readme = readFileSync(join(toolkit, "README.md"), "utf8");
    assert.match(readme, /^## When the coordinator gives it$/m);
    assert.match(readme, /--toolkit browser/);
  });
});

const skillFile = join(toolkit, "skills", "ui-check", "SKILL.md");
const skill = readFileSync(skillFile, "utf8");

// The skill's code: its inline code spans and the lines of its fenced blocks.
const code = [
  ...[...skill.matchAll(/^ *```[^\n]*\n([\s\S]*?)^ *```$/gm)].flatMap(([, block]) => block.split("\n")),
  ...[...skill.replace(/^ *```[^\n]*\n[\s\S]*?^ *```$/gm, "").matchAll(/`([^`\n]+)`/g)].map(([, span]) => span),
];

// A command line's words, a quoted one whole and unquoted, up to the end of its command (a pipe, a
// semicolon or an &&).
function words(line) {
  const out = [];
  for (const [word] of line.matchAll(/"(?:[^"\\]|\\.)*"|'[^']*'|\S+/g)) {
    if (["|", ";", "&&", "||"].includes(word)) break;
    out.push(/^(["']).*\1$/s.test(word) ? word.slice(1, -1) : word);
  }
  return out;
}

// Every chrome-devtools-axi invocation the skill names, as its words after the command's name.
const invocations = code.flatMap((line) =>
  [...line.matchAll(/(?:^|\s)chrome-devtools-axi\s+(.*)$/g)].map(([, rest]) => words(rest)),
);

// An invocation's command and its flags, sorted: what the test must have run.
const signature = ([command, ...args]) =>
  [command, ...args.filter((a) => a.startsWith("--")).map((a) => a.split("=")[0]).sort()].join(" ");

// The skill's evals, each with the placeholders it may hold filled in.
const evals = invocations.filter(([command]) => command === "eval").map(([, js]) => js);
const skillEval = (kind, fill = {}) => {
  const found = evals.filter((js) => kind.test(js));
  assert.equal(found.length, 1, `the skill names one eval matching ${kind}, not ${found.length}`);
  return Object.entries(fill).reduce((js, [name, value]) => js.replaceAll(`<${name}>`, value), found[0]);
};
// The kinds of eval the test runs; the skill may name no other.
const evalKinds = { navigate: /location\.assign/, open: /\.click\(\)/, scroll: /scrollBy/, probe: /overflow/ };

// The viewports the skill sizes its tiles with, and the image each must give.
const viewports = {
  "1920x1080x1": [1920, 1080],
  "1920x1080x0.75": [1440, 810],
  "390x844x1,mobile,touch": [390, 844],
};

describe("the ui-check skill", () => {
  const frontmatter = skill.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? "";
  const field = (name) => frontmatter.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];

  test("is named ui-check, its description under 250 characters and its whole file under 8 kB", () => {
    assert.equal(field("name"), "ui-check");
    const description = field("description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /before delivering or approving/);
    const size = Buffer.byteLength(skill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  // A skill of the same name in another plugin a session loads would bring the check to a session
  // without the browser toolkit.
  test("is the only skill named ui-check in any toolkit or the coordinator's plugin", () => {
    const named = [];
    for (const root of [join(repoRoot, "toolkits"), join(repoRoot, "plugins")]) {
      for (const plugin of readdirSync(root)) {
        const skills = join(root, plugin, "skills");
        if (!existsSync(skills)) continue;
        for (const dir of readdirSync(skills)) {
          const text = readFileSync(join(skills, dir, "SKILL.md"), "utf8");
          if (dir === "ui-check" || /^name: ui-check$/m.test(text)) named.push(`${plugin}/${dir}`);
        }
      }
    }
    assert.deepEqual(named, ["browser/ui-check"]);
  });

  test("captures viewport tiles only, never the whole page, and never resizes the window", () => {
    assert.doesNotMatch(skill, /--full-page|fullPage/);
    assert.ok(!invocations.some(([command]) => command === "resize"), "the skill names resize");
  });

  test("sizes its tiles with the three viewports, and names no eval the test does not run", () => {
    const named = invocations.filter(([command]) => command === "emulate").flatMap((args) => {
      const at = args.indexOf("--viewport");
      return at < 0 ? [] : [args[at + 1]];
    });
    assert.deepEqual([...new Set(named)].sort(), Object.keys(viewports).sort());
    for (const js of evals) {
      assert.ok(Object.values(evalKinds).some((kind) => kind.test(js)), `an eval the test does not run: ${js}`);
    }
  });

  test("credits the chrome-devtools-mcp skills whose steps it adapts", () => {
    assert.match(skill, /chrome-devtools-mcp 1\.12\.0/);
    assert.match(skill, /a11y-debugging/);
    assert.match(skill, /debug-optimize-lcp/);
    assert.match(skill, /Apache-2\.0/);
  });
});

// The fixture site: a sign-in form, and a page with a menu, a dialog, an empty state, a disabled
// control, an element wider than a phone, one small target, a button with no name (the
// accessibility fault) and an error in its console. Every control but the small one is at least
// 48px each way, and the page is taller than a window.
const page = (title, body) => `<!doctype html>
<html lang="en">
<meta name="viewport" content="width=device-width">
<title>${title}</title>
<style>
  body { margin: 0; font: 16px sans-serif; }
  button, a, input { display: block; min-width: 120px; min-height: 48px; box-sizing: border-box; }
  .tiny { min-width: 0; min-height: 0; width: 20px; height: 20px; }
  .wide { width: 600px; height: 40px; background: #ddd; }
  .tall { height: 3000px; }
</style>
<main>${body}</main>
</html>`;
const pages = {
  "/": page("Sign in", `<form onsubmit="event.preventDefault(); location.assign('/home.html')">
    <label>Email <input name="email" type="email"></label>
    <label>Password <input name="password" type="password"></label>
    <button>Sign in</button>
  </form>`),
  "/home.html": page("Home", `<h1>Home</h1>
    <button id="menu" aria-label="Open menu" onclick="document.querySelector('#items').hidden = false">Menu</button>
    <ul id="items" hidden><li><a href="/two.html">Profile</a></li></ul>
    <button id="open-dialog" onclick="document.querySelector('dialog').showModal()">Order</button>
    <dialog><p>Confirm order</p><button onclick="this.closest('dialog').close()">Close</button></dialog>
    <button id="clear" onclick="document.querySelector('#orders').textContent = 'No orders yet'">Clear filters</button>
    <p id="orders">Order 1</p>
    <button disabled>Submit</button>
    <button class="icon"></button>
    <a class="tiny" href="/two.html">?</a>
    <div class="wide"></div>
    <div class="tall"></div>
    <script>console.error("fixture-error: the orders failed to load")</script>`),
  "/two.html": page("Second", "<h1>Second page</h1>"),
};

// A PNG's width and height, from its header.
function pngSize(file) {
  const data = readFileSync(file);
  assert.equal(data.toString("latin1", 1, 4), "PNG", `${file} is not a PNG`);
  return [data.readUInt32BE(16), data.readUInt32BE(20)];
}

// The ref of the element with that role and name in a snapshot axi printed.
function ref(output, role, name) {
  const found = output.match(new RegExp(`uid=(\\S+) ${role} "${name}"`));
  assert.ok(found, `no ${role} "${name}" in:\n${output}`);
  return `@${found[1]}`;
}

// A free port on 127.0.0.1, for the test's bridge: a named session's own port is hashed from its
// name into a range other sessions on the machine share.
async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

describe("every chrome-devtools-axi command ui-check names, run headless on a fixture site", () => {
  const ran = new Set();
  const home = tempDir("axi-home");
  const out = tempDir("axi-out");
  const axiBin = join(repoRoot, "servers", "node_modules", ".bin", "chrome-devtools-axi");
  let site, env;

  // One command, as a session runs it in its own named session: its output, or a failure with it.
  async function axi(...args) {
    ran.add(signature(args));
    try {
      const { stdout } = await promisify(execFile)(axiBin, args, { cwd: out, env, timeout: 120_000 });
      return stdout;
    } catch (error) {
      throw new Error(`chrome-devtools-axi ${args.join(" ")} failed (${error.code ?? error.signal}):\n${error.stdout}${error.stderr}`);
    }
  }
  const go = async (path, text) => {
    await axi("eval", skillEval(evalKinds.navigate, { path }));
    await axi("wait", text);
  };

  before(async () => {
    site = await serveFixture(pages);
    env = {
      HOME: home,
      PATH: testPath({ withOp: false }),
      CHROME_DEVTOOLS_AXI_SESSION: `toolkit-test-${process.pid}`,
      CHROME_DEVTOOLS_AXI_PORT: String(await freePort()),
      CHROME_DEVTOOLS_AXI_MCP_PATH: join(repoRoot, "servers", "node_modules", "chrome-devtools-mcp", "build", "src", "bin", "chrome-devtools-mcp.js"),
      CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH: chromePath(),
      CHROME_DEVTOOLS_AXI_CHROME_ARGS: "--use-mock-keychain --password-store=basic",
      CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS: "1",
      CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1",
    };
  });
  after(async () => {
    await promisify(execFile)(axiBin, ["stop"], { env, timeout: 60_000 }).catch(() => {});
    await site?.close();
  });

  test("signs in with open, fill and click, each taking its refs from the last output", async () => {
    const form = await axi("open", site.url);
    const email = await axi("fill", ref(form, "textbox", "Email"), "user@example.com");
    const password = await axi("fill", ref(email, "textbox", "Password"), "fixture-password");
    await axi("click", ref(password, "button", "Sign in"));
    assert.match(await axi("wait", "Home"), /^waited: Home$/m);
  });

  test("navigates with eval and wait, with no snapshot", async () => {
    const nav = await axi("eval", skillEval(evalKinds.navigate, { path: "/two.html" }));
    assert.doesNotMatch(nav, /uid=/);
    assert.match(await axi("wait", "Second page"), /^waited: Second page$/m);
    assert.equal(await axi("eval", "location.pathname").then((o) => o.match(/^result: (.*)$/m)[1]), '"\\"/two.html\\""');
    await go("/home.html", "Home");
  });

  test("opens a menu, a dialog and an empty state by selector, each printing a line", async () => {
    for (const [selector, text] of [["#menu", "Profile"], ["#open-dialog", "Confirm order"], ["#clear", "No orders yet"]]) {
      const opened = await axi("eval", skillEval(evalKinds.open, { selector }));
      assert.doesNotMatch(opened, /uid=/);
      assert.match(await axi("wait", text), new RegExp(`^waited: ${text}$`, "m"));
    }
    await go("/home.html", "Home");
  });

  test("captures one element from a snapshot's ref at its own size", async () => {
    await axi("emulate", "--viewport", "1920x1080x1");
    const snapshot = await axi("snapshot");
    assert.match(snapshot, /button "Submit" .*\bdisabled\b/);
    const tile = join(out, "home-menu.png");
    assert.match(await axi("screenshot", tile, "--uid", ref(snapshot, "button", "Open menu")), /^screenshot: /m);
    assert.deepEqual(pngSize(tile), [120, 48]);
  });

  test("captures a viewport tile of the size the skill gives at each of its viewports", async () => {
    for (const [viewport, size] of Object.entries(viewports)) {
      await axi("emulate", "--viewport", viewport);
      const tile = join(out, `home-${size.join("x")}.png`);
      await axi("screenshot", tile);
      assert.deepEqual(pngSize(tile), size, viewport);
      if (viewport === "1920x1080x0.75") {
        assert.match(await axi("eval", "innerWidth"), /^result: "1920"$/m, "the reduced scale changed the layout width");
      }
    }
  });

  test("scrolls a tall state one window at a time", async () => {
    await axi("emulate", "--viewport", "1920x1080x1");
    await go("/home.html", "Home");
    assert.match(await axi("eval", skillEval(evalKinds.scroll)), /^result: "1080"$/m);
    assert.match(await axi("eval", skillEval(evalKinds.scroll)), /^result: "2160"$/m);
  });

  test("the phone probe counts the overflow and the small targets at phone width", async () => {
    await axi("emulate", "--viewport", "390x844x1,mobile,touch");
    await go("/home.html", "Home");
    const result = (await axi("eval", skillEval(evalKinds.probe))).match(/^result: (.*)$/m)[1];
    assert.deepEqual(JSON.parse(JSON.parse(result)), { overflow: 210, small: 1 });
  });

  test("console lists the page's errors", async () => {
    assert.match(await axi("console"), /fixture-error: the orders failed to load/);
  });

  test("Lighthouse's snapshot audit and the skill's jq filter name the fixture's accessibility fault", async () => {
    await axi("emulate", "--viewport", "1920x1080x1");
    await go("/home.html", "Home");
    const reports = join(out, "lighthouse");
    assert.match(await axi("lighthouse", "--mode", "snapshot", "--output-dir", reports), /Accessibility: \d+/);
    const jq = code.map((line) => line.match(/(?:^|\s)jq -r '([^']+)'/)?.[1]).filter(Boolean);
    assert.equal(jq.length, 1, "the skill names one jq filter");
    const failing = execFileSync("jq", ["-r", jq[0], join(reports, "report.json")], { encoding: "utf8" });
    assert.match(failing, /^button-name: .*\[body > main > button\.icon\]$/m);
    assert.doesNotMatch(failing, /meta-description/, "the filter reads audits outside accessibility");
  });

  test("a throttled trace gives the LCP breakdown", async () => {
    assert.match(await axi("emulate", "--network", "Slow 4G", "--cpu", "4"), /networkConditions: Slow 4G/);
    assert.match(await axi("perf-start", "--no-auto-stop"), /^trace: started$/m);
    await axi("wait", "Home");
    const trace = await axi("perf-stop");
    assert.match(trace, /insight name: LCPBreakdown/);
    const set = trace.match(/insight set id: (\S+)/)[1];
    assert.match(await axi("perf-insight", set, "LCPBreakdown"), /## Insight Title: LCP breakdown/);
  });

  test("stop ends the session's bridge and its browser", async () => {
    const { pid } = JSON.parse(readFileSync(join(home, ".chrome-devtools-axi", "sessions", env.CHROME_DEVTOOLS_AXI_SESSION, "bridge.pid"), "utf8"));
    assert.match(await axi("stop"), /^status: stopped$/m);
    assert.throws(() => process.kill(pid, 0), "the bridge still runs");
  });

  test("the skill names no command or flag the test has not run", () => {
    const missing = [...new Set(invocations.map(signature))].filter((s) => !ran.has(s));
    assert.deepEqual(missing, []);
  });
});
