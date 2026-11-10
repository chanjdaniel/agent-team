// The codegraph toolkit as team-worker --toolkit codegraph loads it: its plugin layout, and its one
// SessionStart hook run as Claude Code runs a plugin's hook, with CLAUDE_PLUGIN_ROOT set to the
// toolkit and the SessionStart event on stdin, on a stub codegraph that records its arguments, for
// a builder, a reviewer and the roles it skips, with and without .codegraph/ and an index, and with
// each command failing, its banner held to six lines; and, where a real codegraph is on PATH (not
// on CI), once against it on a small project written here at run time, so the repository holds no
// .codegraph/, checking the banner names only subcommands that CLI has.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, test } from "node:test";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "codegraph");
const hooks = JSON.parse(readFileSync(join(toolkit, "hooks", "hooks.json"), "utf8"));
const system = ["/usr/bin", "/bin"];

// The hook's Bash 5 and jq, found where the caller's PATH has them (Homebrew's on macOS, whose
// /bin/bash is 3.2), linked into a directory of their own so nothing else of that PATH comes along.
const tools = tempDir("tools");
for (const name of ["bash", "jq"]) {
  symlinkSync(execFileSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" }).trim(), join(tools, name));
}

// The system directories hold no codegraph, so a PATH without the stub has none.
for (const dir of system) {
  assert.ok(!existsSync(join(dir, "codegraph")), `${dir} holds a codegraph, so no case can run without one`);
}

// A stub codegraph that logs each call's arguments to `calls` and its telemetry variables
// (CODEGRAPH_TELEMETRY and DO_NOT_TRACK, - when unset) to `env`, prints on stderr and, but for the
// JSON of `status --json`, on stdout (which the hook must keep out of its output), reports a
// directory initialised once it has a database, makes one on init, and exits with the code in
// `fail` when that file names the call's subcommand.
function stub() {
  const dir = tempDir("stub");
  writeFileSync(join(dir, "codegraph"), `#!/bin/sh
printf '%s\\n' "$*" >>'${dir}/calls'
printf '%s %s\\n' "\${CODEGRAPH_TELEMETRY:--}" "\${DO_NOT_TRACK:--}" >>'${dir}/env'
[ "$1" = status ] || echo "stub $1 output"
echo "stub $1 error" >&2
if [ -f '${dir}/fail' ]; then
  read -r sub code <'${dir}/fail'
  [ "$sub" = "$1" ] && exit "$code"
fi
eval "path=\\\${$#}"
case $1 in
  status)
    if [ -f "$path/.codegraph/codegraph.db" ]; then echo '{"initialized":true}'; else echo '{"initialized":false}'; fi ;;
  init) : >"$path/.codegraph/codegraph.db" ;;
esac
`, { mode: 0o755 });
  return {
    dir,
    fail: (sub, code) => writeFileSync(join(dir, "fail"), `${sub} ${code}\n`),
    calls: () => (existsSync(join(dir, "calls")) ? readFileSync(join(dir, "calls"), "utf8").trim().split("\n") : []),
    env: () => (existsSync(join(dir, "env")) ? readFileSync(join(dir, "env"), "utf8").trim().split("\n") : []),
  };
}

// A project directory, with a .codegraph/ holding only its tracked .gitignore unless told otherwise.
function project({ codegraph = true, indexed = false } = {}) {
  const dir = tempDir("project");
  if (codegraph) {
    mkdirSync(join(dir, ".codegraph"));
    writeFileSync(join(dir, ".codegraph", ".gitignore"), "*\n!.gitignore\n");
    if (indexed) writeFileSync(join(dir, ".codegraph", "codegraph.db"), "");
  }
  return dir;
}

// The hook's command through a shell, as Claude Code runs a plugin hook: CLAUDE_PLUGIN_ROOT in its
// environment and the SessionStart event on stdin, whose cwd is the session's directory.
function runHook({ role = "builder", cwd, eventCwd = cwd, path, env = {} }) {
  const event = { session_id: "3169fcbd-0000-4000-8000-000000000000", hook_event_name: "SessionStart", source: "startup" };
  if (eventCwd !== undefined) event.cwd = eventCwd;
  const { command } = hooks.hooks.SessionStart[0].hooks[0];
  const result = spawnSync("sh", ["-c", command], {
    cwd,
    encoding: "utf8",
    input: JSON.stringify(event),
    env: { HOME: tempDir("home"), PATH: path, CLAUDE_PLUGIN_ROOT: toolkit, ...(role ? { AGENT_TEAM_ROLE: role } : {}), ...env },
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const stubPath = (s) => [s.dir, tools, ...system].join(":");

// The banner's sentences, in the order the spec gives them.
const bannerOrder = [
  /index is ready/,
  /`codegraph explore "<symbol names or a question>"`/,
  /before grep, find or whole-file reads/,
  /`codegraph node <name>`/,
  /`codegraph sync`/,
  /still read the exact lines/i,
];

function assertBanner(out) {
  const lines = out.trimEnd().split("\n");
  assert.ok(lines.length <= 6, `the banner is ${lines.length} lines`);
  assert.doesNotMatch(out, /stub/, "codegraph's own output reached the session");
  let at = -1;
  for (const part of bannerOrder) {
    const found = out.search(part);
    assert.ok(found > at, `${part} is missing or out of order in:\n${out}`);
    at = found;
  }
}

describe("the codegraph toolkit", () => {
  test("is a plugin named codegraph with one SessionStart hook, no matcher, no MCP server and no skill", () => {
    const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
    assert.equal(manifest.name, "codegraph");
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "hooks", "scripts"]);
    assert.deepEqual(readdirSync(join(toolkit, "scripts")), ["codegraph-banner"]);
    accessSync(join(toolkit, "scripts", "codegraph-banner"), constants.X_OK);
    assert.deepEqual(Object.keys(hooks.hooks), ["SessionStart"]);
    assert.equal(hooks.hooks.SessionStart.length, 1);
    assert.ok(!("matcher" in hooks.hooks.SessionStart[0]), "the hook has a matcher, so a compacted session may miss the banner");
    assert.deepEqual(hooks.hooks.SessionStart[0].hooks, [{
      type: "command",
      command: '"${CLAUDE_PLUGIN_ROOT}/scripts/codegraph-banner"',
      timeout: 30,
    }]);
  });

  test("the repository holds no .codegraph/ directory", () => {
    assert.ok(!existsSync(join(repoRoot, ".codegraph")));
    const tracked = execFileSync("git", ["-C", repoRoot, "ls-files"], { encoding: "utf8" }).split("\n");
    assert.deepEqual(tracked.filter((path) => /(^|\/)\.codegraph\//.test(path)), []);
  });

  for (const role of ["builder", "reviewer"]) {
    test(`for a ${role} in an uninitialised .codegraph/ it builds the index, then prints the banner`, () => {
      const s = stub();
      const dir = project();
      const out = runHook({ role, cwd: dir, path: stubPath(s) });
      assert.equal(out.status, 0, out.stderr);
      assertBanner(out.stdout);
      assert.equal(out.stderr, "");
      assert.deepEqual(s.calls(), [`status --json ${dir}`, `init ${dir}`]);
      // Each call runs with CodeGraph's telemetry off, whatever the machine's setting.
      assert.deepEqual(s.env(), ["0 1", "0 1"]);
    });

    test(`for a ${role} with an index it syncs it, then prints the banner`, () => {
      const s = stub();
      const dir = project({ indexed: true });
      const out = runHook({ role, cwd: dir, path: stubPath(s) });
      assert.equal(out.status, 0, out.stderr);
      assertBanner(out.stdout);
      assert.deepEqual(s.calls(), [`status --json ${dir}`, `sync ${dir}`]);
      assert.deepEqual(s.env(), ["0 1", "0 1"]);
    });
  }

  test("the event's cwd wins over the hook's working directory, which is the fallback", () => {
    const s = stub();
    const dir = project({ indexed: true });
    const elsewhere = project({ codegraph: false });
    assert.equal(runHook({ cwd: elsewhere, eventCwd: dir, path: stubPath(s) }).status, 0);
    assert.deepEqual(s.calls(), [`status --json ${dir}`, `sync ${dir}`]);
    const t = stub();
    const out = runHook({ cwd: dir, eventCwd: undefined, path: stubPath(t) });
    assertBanner(out.stdout);
    assert.deepEqual(t.calls(), [`status --json ${dir}`, `sync ${dir}`]);
  });

  for (const [sub, indexed, code, command] of [
    ["init", false, 3, "codegraph init"],
    ["sync", true, 4, "codegraph sync"],
    ["status", true, 5, "codegraph status --json"],
  ]) {
    test(`a failing codegraph ${sub} prints one line naming it and its status, and exits 0`, () => {
      const s = stub();
      s.fail(sub, code);
      const dir = project({ indexed });
      const out = runHook({ cwd: dir, path: stubPath(s) });
      assert.equal(out.status, 0);
      assert.equal(out.stderr, "");
      const lines = out.stdout.trimEnd().split("\n");
      assert.equal(lines.length, 1, out.stdout);
      assert.ok(lines[0].includes(`\`${command} ${dir}\` exited ${code}`), lines[0]);
      assert.match(lines[0], /locate code as usual/);
    });
  }

  test("with no .codegraph/ it prints nothing and calls nothing", () => {
    const s = stub();
    const out = runHook({ cwd: project({ codegraph: false }), path: stubPath(s) });
    assert.deepEqual(out, { status: 0, stdout: "", stderr: "" });
    assert.deepEqual(s.calls(), []);
  });

  test("a .codegraph file, not a directory, counts as none", () => {
    const s = stub();
    const dir = project({ codegraph: false });
    writeFileSync(join(dir, ".codegraph"), "");
    assert.deepEqual(runHook({ cwd: dir, path: stubPath(s) }), { status: 0, stdout: "", stderr: "" });
    assert.deepEqual(s.calls(), []);
  });

  test("with no codegraph on PATH it prints nothing", () => {
    const out = runHook({ cwd: project(), path: [tools, ...system].join(":") });
    assert.deepEqual(out, { status: 0, stdout: "", stderr: "" });
  });

  for (const role of ["planner", "ops", "coordinator", ""]) {
    test(`for ${role ? `${role === "ops" ? "an" : "a"} ${role}` : "a session with no role"} it prints nothing and calls nothing`, () => {
      const s = stub();
      const out = runHook({ role, cwd: project(), path: stubPath(s) });
      assert.deepEqual(out, { status: 0, stdout: "", stderr: "" });
      assert.deepEqual(s.calls(), []);
    });
  }

  test("its README says when the coordinator gives it, what it writes, and the trial that gives it", () => {
    const readme = readFileSync(join(toolkit, "README.md"), "utf8");
    assert.match(readme, /^## When the coordinator gives it$/m);
    assert.match(readme, /--toolkit codegraph/);
    assert.match(readme, /no daemon/);
    assert.match(readme, /"Trialling a setup change" section of `sops\/model-trials\.md`/);
    assert.match(readme, /CodeGraph in every worktree/);
  });
});

// The real codegraph, where the caller's PATH has one.
const real = spawnSync("sh", ["-c", "command -v codegraph"], { encoding: "utf8" }).stdout.trim();

describe("the codegraph toolkit on the installed codegraph", () => {
  const skip = real ? false : "no codegraph on PATH (CI installs none)";
  // The real CLI's directory and node's, then the hook's tools. The hook runs as it ships, turning
  // telemetry off itself; the test's own calls turn it off here.
  const path = () => [dirname(real), dirname(process.execPath), tools, ...system].join(":");
  const env = { CODEGRAPH_TELEMETRY: "0", DO_NOT_TRACK: "1" };

  test("builds a small project's index, prints the banner, then syncs it", { skip }, () => {
    const dir = project();
    writeFileSync(join(dir, "greet.ts"), "export function hello() {\n  return 1;\n}\nexport function world() {\n  return hello();\n}\n");
    const first = runHook({ cwd: dir, path: path() });
    assert.equal(first.status, 0, first.stderr);
    assertBanner(first.stdout);
    assert.ok(statSync(join(dir, ".codegraph", "codegraph.db")).size > 0, "no index was built");
    const status = JSON.parse(execFileSync(real, ["status", "--json", dir], { encoding: "utf8", env: { ...process.env, ...env } }));
    assert.equal(status.initialized, true);
    assert.equal(status.fileCount, 1);
    const found = execFileSync(real, ["explore", "--path", dir, "world"], { encoding: "utf8", env: { ...process.env, ...env } });
    assert.match(found, /greet\.ts/);
    const second = runHook({ cwd: dir, path: path() });
    assert.equal(second.status, 0, second.stderr);
    assertBanner(second.stdout);
  });

  test("names only subcommands the installed codegraph has", { skip }, () => {
    const help = execFileSync(real, ["--help"], { encoding: "utf8" });
    const commands = new Set([...help.matchAll(/^ {2}([a-z]+)(?:\|[a-z]+)? /gm)].map(([, name]) => name));
    const out = runHook({ cwd: project({ indexed: true }), path: stubPath(stub()) }).stdout;
    const named = [...out.matchAll(/`codegraph ([a-z]+)/g)].map(([, name]) => name);
    assert.deepEqual(named, ["explore", "node", "sync"]);
    // The banner's, and the ones the hook runs itself.
    for (const name of [...named, "status", "init"]) assert.ok(commands.has(name), `codegraph has no ${name} subcommand`);
  });
});
