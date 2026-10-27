// The browser toolkit as team-worker --toolkit browser loads it: its plugin layout, and its one
// SessionStart hook run as Claude Code runs a plugin's hook, with CLAUDE_PLUGIN_ROOT set to the
// toolkit and a stub chrome-devtools-axi first on PATH, under the user settings of today and under
// the guarded ones the PR proposes.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, test } from "node:test";
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
  test("is a plugin named browser with one hook, no MCP server and no skill", () => {
    const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
    assert.equal(manifest.name, "browser");
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.ok(!existsSync(join(toolkit, "skills")), "the toolkit carries skills");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "hooks"]);
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
