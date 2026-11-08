// The effect toolkit as team-worker --toolkit effect loads it: its plugin layout and README, and
// its effect-v4 skill, whose limits and order of sections the test holds, and whose trap table it
// checks against the effect package servers/ pins: every name the GA column gives exists there, and
// every name a v3 or early-beta column gives is gone; and its post-edit hook, run as Claude Code runs
// a plugin's on a copy of the fixture project, against the effect-tsgo servers/ pins and stubs.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, test } from "node:test";
import { repoRoot, tempDir, testPath } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "effect");
const skillFile = join(toolkit, "skills", "effect-v4", "SKILL.md");
const skill = readFileSync(skillFile, "utf8");
const readme = readFileSync(join(toolkit, "README.md"), "utf8");
const hooks = JSON.parse(readFileSync(join(toolkit, "hooks", "hooks.json"), "utf8"));
const deadlineSeconds = Number(readme.match(/The hook's deadline is (\d+) s/)?.[1]);

describe("the effect toolkit", () => {
  test("is a plugin named effect with one PostToolUse hook, no MCP server and one skill, effect-v4", () => {
    const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
    assert.equal(manifest.name, "effect");
    assert.equal(manifest.author?.name, "Daniel Chan");
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "evals", "hooks", "scripts", "skills"]);
    assert.deepEqual(readdirSync(join(toolkit, "hooks")), ["hooks.json"]);
    assert.deepEqual(readdirSync(join(toolkit, "scripts")), ["effect-diagnostics.mjs"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills")), ["effect-v4"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills", "effect-v4")), ["SKILL.md"]);
    assert.deepEqual(Object.keys(hooks.hooks), ["PostToolUse"]);
    assert.equal(hooks.hooks.PostToolUse.length, 1);
    assert.equal(hooks.hooks.PostToolUse[0].matcher, "Edit|Write|MultiEdit");
    assert.deepEqual(hooks.hooks.PostToolUse[0].hooks, [{
      type: "command",
      command: 'node "${CLAUDE_PLUGIN_ROOT}/scripts/effect-diagnostics.mjs"',
      timeout: deadlineSeconds + 5,
    }]);
  });

  test("its README records the hook's deadline, between 3 and 15 seconds", () => {
    assert.ok(deadlineSeconds >= 3 && deadlineSeconds <= 15, `the deadline is ${deadlineSeconds} s`);
  });

  test("its README says when the coordinator gives it", () => {
    assert.match(readme, /^## When the coordinator gives it$/m);
    assert.match(readme, /--toolkit effect/);
  });

  // Each case fires the skill or, for a React useEffect question, leaves it alone.
  test("its evals fire the skill on an Effect service and an Effect diff, and not on React's useEffect", () => {
    const evals = join(toolkit, "evals");
    const graded = (name) => readdirSync(join(evals, name, "graders")).sort();
    assert.deepEqual(readdirSync(evals).filter((name) => name !== "results").sort(),
      ["add-a-service", "react-useeffect-question", "review-an-effect-diff"]);
    assert.deepEqual(graded("add-a-service"), ["answer.md", "skill-fired.md"]);
    assert.deepEqual(graded("review-an-effect-diff"), ["answer.md", "skill-fired.md"]);
    assert.deepEqual(graded("react-useeffect-question"), ["skill-not-fired.md"]);
    const grader = (name, file) => readFileSync(join(evals, name, "graders", file), "utf8");
    for (const name of ["add-a-service", "review-an-effect-diff"]) {
      assert.match(grader(name, "skill-fired.md"), /^type: tool_used$/m);
      assert.match(grader(name, "skill-fired.md"), /effect-v4/);
    }
    const notFired = grader("react-useeffect-question", "skill-not-fired.md");
    assert.match(notFired, /effect-v4/);
    assert.match(notFired, /^max: 0$/m);
    assert.match(readFileSync(join(evals, "react-useeffect-question", "prompt.md"), "utf8"), /useEffect/);
  });
});

const frontmatter = skill.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? "";
const field = (name) => frontmatter.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];

// The trap table: each row's cells, and the reference links it cites by label.
const header = "| Topic | v3 | Early beta | GA | Source |";
const tableLines = (() => {
  const lines = skill.split("\n");
  const start = lines.indexOf(header);
  assert.ok(start >= 0, "the skill has no trap table");
  const rows = [];
  for (const line of lines.slice(start + 2)) {
    if (!line.startsWith("|")) break;
    rows.push(line);
  }
  return rows;
})();
const cellsOf = (line) => line.split("|").slice(1, -1).map((cell) => cell.trim());
const links = Object.fromEntries([...skill.matchAll(/^\[([\w-]+)\]: (\S+)$/gm)].map(([, label, url]) => [label, url]));

// The names a cell gives, by the convention the skill states: each code span that starts with a
// capitalized name and a member (`Effect.catchAll`, `Context.Service<Self, Shape>()("Id")`), or is
// a capitalized name alone (`Either`), or is an effect/... import path; a call such as
// `Union(A, B)` is not one.
function names(cell) {
  const out = [];
  for (const [, span] of cell.matchAll(/`([^`]+)`/g)) {
    const path = span.match(/^effect\/[\w/-]+$/);
    if (path) { out.push({ span, path: span }); continue; }
    const member = span.match(/^([A-Z]\w*)\.(\w+)/) ?? span.match(/^([A-Z]\w*)$/);
    if (member) out.push({ span, module: member[1], member: member[2] });
  }
  return out;
}

// What the pinned effect exports: its modules, and whether an import path resolves.
const serversRequire = createRequire(join(repoRoot, "servers", "package.json"));
const effect = await import(pathToFileURL(serversRequire.resolve("effect")).href);
const effectRoot = join(repoRoot, "servers", "node_modules", "effect");
const pinned = JSON.parse(readFileSync(join(repoRoot, "servers", "package.json"), "utf8")).dependencies.effect;

async function exists({ module, member, path }) {
  if (path) {
    try {
      await import(pathToFileURL(serversRequire.resolve(path)).href);
      return true;
    } catch {
      return false;
    }
  }
  if (!Object.hasOwn(effect, module)) return false;
  return member === undefined || member in effect[module];
}

// Each column's verdicts: a name the GA column gives must exist; one a v3 or beta column gives,
// must not.
async function misplaced(rows) {
  const wrong = [];
  for (const row of rows) {
    const [topic, v3, beta, ga] = cellsOf(row);
    for (const [column, cell, want] of [["v3", v3, false], ["beta", beta, false], ["GA", ga, true]]) {
      for (const name of names(cell)) {
        if ((await exists(name)) !== want) wrong.push(`${topic} (${column}): ${name.span}`);
      }
    }
  }
  return wrong;
}

describe("the effect-v4 skill", () => {
  test("is named effect-v4, its description under 250 characters and its whole file under 8 kB", () => {
    assert.equal(field("name"), "effect-v4");
    const description = field("description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /Effect v4/);
    assert.match(description, /Effect-TS/);
    assert.doesNotMatch(description, /React|useEffect/);
    const size = Buffer.byteLength(skill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  // A skill of the same name in another plugin a session loads would bring the skill to a session
  // without the effect toolkit.
  test("is the only skill named effect-v4 in any toolkit or the coordinator's plugin", () => {
    const named = [];
    for (const root of [join(repoRoot, "toolkits"), join(repoRoot, "plugins")]) {
      for (const plugin of readdirSync(root)) {
        const skills = join(root, plugin, "skills");
        if (!existsSync(skills)) continue;
        for (const dir of readdirSync(skills)) {
          const text = readFileSync(join(skills, dir, "SKILL.md"), "utf8");
          if (dir === "effect-v4" || /^name: effect-v4$/m.test(text)) named.push(`${plugin}/${dir}`);
        }
      }
    }
    assert.deepEqual(named, ["effect/effect-v4"]);
  });

  test("holds its steps in the spec's order", () => {
    const steps = [
      "node_modules/effect/package.json",
      "node_modules/effect/AGENTS.md",
      "`ai-docs/`",
      "node_modules/effect/src/",
      "migration/v3-to-v4.md",
      header,
      '"did you mean"',
      "Still type-checks, changes behaviour",
      "node_modules/.bin/effect-tsgo tsc -p tsconfig.json",
      "node_modules/.bin/effect-language-service diagnostics --project tsconfig.json",
      "never install one unasked",
      "`FOLDKIT.md`",
      "`repos/foldkit/skills/audit-program/`",
      "never followed",
    ];
    const at = steps.map((step) => skill.indexOf(step));
    steps.forEach((step, i) => assert.ok(at[i] >= 0, `the skill does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "the skill's steps are out of order");
    assert.match(skill, /effect@<version>\/migration\/v3-to-v4\.md/);
    assert.match(skill, /one symbol per search/);
    assert.match(skill, /Beta names get no `outdatedApi` hint/);
  });

  test("names in its still-type-checks list the changes the spec gives", () => {
    const list = skill.split("## 6. Still type-checks, changes behaviour")[1].split("\n## ")[0];
    for (const name of ["`Schema.Date`", "`Schema.annotate`", "`Equal.equals`", "defect", "`Layer.fresh`", "`Data.TaggedError`"]) {
      assert.ok(list.includes(name), `the list does not name ${name}`);
    }
  });

  test("tests its table against the effect servers/ pins, the version Foldkit's 4.1 line takes", () => {
    assert.match(pinned, /^4\.1\.\d+$/, "servers/ pins effect exactly, on the 4.1 line");
    assert.equal(JSON.parse(readFileSync(join(effectRoot, "package.json"), "utf8")).version, pinned,
      "servers/node_modules holds another effect; run servers/install");
  });

  test("gives in its GA column only names the pinned effect exports, and in its v3 and beta columns only names it does not", async () => {
    assert.ok(tableLines.length >= 18, `the table has ${tableLines.length} rows`);
    const checked = tableLines.flatMap((row) => cellsOf(row).slice(1, 4).flatMap(names));
    assert.ok(checked.length >= 60, `the table names only ${checked.length} checked spans`);
    assert.ok(checked.some(({ path }) => path), "the table names no effect/... import path");
    assert.deepEqual(await misplaced(tableLines), []);
  });

  // The convention has teeth: a GA name moved into a removed column, a removed name moved into the
  // GA column, and a beta import path made GA each fail.
  test("fails a table whose span sits in the wrong column", async () => {
    const swapped = (from, to) => tableLines.map((row) => row.replace(from, to));
    assert.deepEqual(await misplaced(swapped("| `Effect.catchAll`,", "| `Effect.catch`,")), ["Catching (v3): Effect.catch"]);
    assert.deepEqual(await misplaced(swapped("`Effect.forkChild`", "`Effect.fork`")), ["Forking (GA): Effect.fork"]);
    assert.deepEqual(await misplaced(swapped("| `effect/http` |", "| `effect/unstable/http` |")),
      ["Import paths (GA): effect/unstable/http"]);
    assert.deepEqual(await misplaced(swapped("| `ServiceMap.Service` |", "| `Data.TaggedError` |")),
      ["Services (beta): Data.TaggedError"]);
  });

  test("cites for every row a source at Effect's or Foldkit's repository or site", () => {
    const allowed = /^https:\/\/(github\.com\/(Effect-TS|foldkit)\/|effect\.website\/|foldkit\.dev\/)/;
    for (const row of tableLines) {
      const [topic, , , , source] = cellsOf(row);
      const urls = [
        ...[...source.matchAll(/\[([\w-]+)\]/g)].map(([, label]) => links[label]),
        ...[...source.matchAll(/https:\/\/\S+/g)].map(([url]) => url),
      ];
      assert.ok(urls.length > 0, `${topic} cites no source`);
      for (const url of urls) assert.match(url ?? "an undefined link", allowed, topic);
    }
  });
});

// The post-edit hook, run as Claude Code runs a plugin's PostToolUse hook: its command through a
// shell, CLAUDE_PLUGIN_ROOT set to the toolkit, and the event on stdin; against the real
// effect-tsgo servers/ pins, on the fixture project copied to a temporary directory whose
// node_modules is servers/node_modules, and against stub effect-tsgo binaries for the deadline,
// the cap and a failure.
const fixture = join(repoRoot, "tests", "toolkits", "fixtures", "effect-project");
const serversModules = join(repoRoot, "servers", "node_modules");
const hookCommand = hooks.hooks.PostToolUse[0].hooks[0].command;
const checkCommand = skill.match(/`(node_modules\/\.bin\/effect-tsgo tsc -p tsconfig\.json)`/)?.[1];

// A copy of the fixture, its node_modules linked to servers/, under a real path (macOS's tmpdir
// is behind a link, and Claude Code gives the hook real paths).
function project() {
  const dir = realpathSync(tempDir("effect-project"));
  cpSync(fixture, dir, { recursive: true });
  symlinkSync(serversModules, join(dir, "node_modules"));
  return dir;
}

// A worktree whose node_modules/.bin/effect-tsgo is the shell script given, a tsconfig.json and a
// TypeScript file.
function stubbed(script) {
  const dir = realpathSync(tempDir("effect-stub"));
  writeFileSync(join(dir, "tsconfig.json"), "{}\n");
  mkdirSync(join(dir, "node_modules", ".bin"), { recursive: true });
  writeFileSync(join(dir, "node_modules", ".bin", "effect-tsgo"), `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  mkdirSync(join(dir, "src"));
  writeFileSync(join(dir, "src", "app.ts"), "export const x = 1\n");
  return dir;
}

// The hook on an edit of file in a session whose cwd is cwd: its exit code, stdout, stderr and
// time; wrap runs the hook's shell under another command (unshare).
function runHook({ cwd, file, tool = "Edit", env = {}, wrap = [] }) {
  const event = {
    session_id: "5be0c1a2-0000-4000-8000-000000000000",
    hook_event_name: "PostToolUse",
    cwd,
    tool_name: tool,
    tool_input: { file_path: file, old_string: "a", new_string: "b" },
    tool_response: { filePath: file },
  };
  const started = Date.now();
  const run = spawnSync(wrap[0] ?? "sh", [...wrap.slice(1), ...(wrap.length ? ["sh"] : []), "-c", hookCommand], {
    cwd,
    encoding: "utf8",
    input: JSON.stringify(event),
    env: { HOME: cwd, PATH: testPath({ withOp: false }), CLAUDE_PLUGIN_ROOT: toolkit, ...env },
    timeout: 60_000,
  });
  return { status: run.status, stdout: run.stdout, stderr: run.stderr, ms: Date.now() - started };
}

// The hook's additional context, after checking its output is the documented JSON shape.
function context(run) {
  assert.equal(run.status, 0, run.stderr);
  const out = JSON.parse(run.stdout);
  assert.deepEqual(Object.keys(out), ["hookSpecificOutput"]);
  assert.equal(out.hookSpecificOutput.hookEventName, "PostToolUse");
  assert.equal(typeof out.hookSpecificOutput.additionalContext, "string");
  return out.hookSpecificOutput.additionalContext;
}

function silent(run) {
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, "");
}

// Whether a process group still has a member.
function alive(group) {
  try {
    process.kill(-group, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

const findings = (text) => text.split("\n").slice(1);

describe("the effect toolkit's post-edit hook", () => {
  test("names catch for Effect.catchAll and forkChild for Effect.fork, headed by the file's path", () => {
    const cwd = project();
    for (const tool of ["Edit", "Write", "MultiEdit"]) {
      const text = context(runHook({ cwd, file: join(cwd, "src", "v3-habits.ts"), tool }));
      const [head, ...lines] = text.split("\n");
      assert.match(head, /^Effect's language service on src\/v3-habits\.ts:$/);
      assert.ok(lines.some((line) => /catchAll/.test(line) && /Renamed to catch\./.test(line)), text);
      assert.ok(lines.some((line) => /`fork`/.test(line) && /Renamed to forkChild\./.test(line)), text);
      assert.ok(lines.every((line) => line.startsWith("src/v3-habits.ts(")), text);
      assert.ok(!text.includes(cwd), "the findings name the file by its absolute path");
    }
  });

  test("says nothing of a clean v4 file", () => {
    const cwd = project();
    silent(runHook({ cwd, file: join(cwd, "src", "clean.ts") }));
  });

  test("says nothing of a file that is not TypeScript, a declaration file, or one the tsconfig does not include", () => {
    const cwd = project();
    const habit = readFileSync(join(cwd, "src", "v3-habits.ts"), "utf8");
    writeFileSync(join(cwd, "src", "notes.md"), habit);
    writeFileSync(join(cwd, "src", "habits.d.ts"), habit);
    for (const file of ["src/notes.md", "src/habits.d.ts", "scripts/not-included.ts"]) {
      silent(runHook({ cwd, file: join(cwd, file) }));
    }
  });

  // A worktree slot inside an enclosing checkout, as `.claude/worktrees/<n>` sits in the primary
  // one: the enclosing tsconfig includes everything, the slot's only src/.
  function enclosed() {
    const parent = realpathSync(tempDir("effect-enclosing"));
    writeFileSync(join(parent, "tsconfig.json"), JSON.stringify({
      compilerOptions: { strict: true, noEmit: true, moduleResolution: "bundler", module: "ESNext", plugins: [{ name: "@effect/language-service" }] },
      include: ["**/*"],
    }));
    const cwd = join(parent, "slot");
    cpSync(fixture, cwd, { recursive: true });
    symlinkSync(serversModules, join(cwd, "node_modules"));
    return cwd;
  }

  test("says nothing of a file its worktree's tsconfig does not include, whatever a tsconfig above cwd includes", () => {
    const cwd = enclosed();
    silent(runHook({ cwd, file: join(cwd, "scripts", "not-included.ts") }));
    assert.match(context(runHook({ cwd, file: join(cwd, "src", "v3-habits.ts") })), /Renamed to catch\./);
  });

  // The CLI, given no tsconfig between the file and cwd, takes the nearest one above cwd.
  test("says nothing of a file with no tsconfig.json between it and cwd, and never starts effect-tsgo for it", () => {
    const cwd = enclosed();
    rmSync(join(cwd, "tsconfig.json"));
    silent(runHook({ cwd, file: join(cwd, "scripts", "not-included.ts") }));
    const stub = stubbed(`touch "${"$"}{0%/node_modules/*}/started"\necho "$3(1,1): warning effect(outdatedApi): a finding"`);
    rmSync(join(stub, "tsconfig.json"));
    silent(runHook({ cwd: stub, file: join(stub, "src", "app.ts") }));
    assert.ok(!existsSync(join(stub, "started")), "the hook started effect-tsgo with no tsconfig.json under cwd");
  });

  test("says nothing of a file outside cwd or under node_modules", () => {
    // Another worktree's file, beside an effect-tsgo of its own: the hook never reaches it.
    const cwd = project();
    const other = project();
    silent(runHook({ cwd, file: join(other, "src", "v3-habits.ts") }));
    silent(runHook({ cwd, file: join(cwd, "..", "v3-habits.ts") }));
    const vendored = join(cwd, "node_modules", "effect", "src", "Effect.ts");
    assert.ok(existsSync(vendored), "servers/node_modules/effect has no src/Effect.ts");
    silent(runHook({ cwd, file: vendored }));
  });

  // The real CLI is silent on most of those too, so a stub that reports every file it is given
  // shows the hook never starts it for them.
  test("never starts effect-tsgo for a file it skips", () => {
    const cwd = stubbed(`touch "${"$"}{0%/node_modules/*}/started"\necho "$3(1,1): warning effect(outdatedApi): a finding"`);
    const other = stubbed("true");
    mkdirSync(join(cwd, "src", "node_modules", "pkg"), { recursive: true });
    const skipped = ["src/notes.md", "src/app.d.ts", "src/app.d.mts", "src/app.d.css.ts", "src/app.js", "src/node_modules/pkg/index.ts"];
    for (const file of skipped) writeFileSync(join(cwd, file), "export const x = 1\n");
    for (const file of [...skipped.map((file) => join(cwd, file)), join(other, "src", "app.ts")]) {
      silent(runHook({ cwd, file }));
      assert.ok(!existsSync(join(cwd, "started")), `the hook started effect-tsgo for ${file}`);
    }
    assert.match(context(runHook({ cwd, file: join(cwd, "src", "app.ts") })), /a finding/);
    assert.ok(existsSync(join(cwd, "started")));
  });

  // A path inside cwd that resolves outside it is another worktree's file: the hook judges the real
  // path, never the one it was given.
  test("says nothing of a symlinked file or directory inside cwd that resolves outside it", () => {
    const cwd = project();
    const other = project();
    symlinkSync(join(other, "src", "v3-habits.ts"), join(cwd, "src", "link.ts"));
    symlinkSync(join(other, "src"), join(cwd, "linked"));
    for (const file of ["src/link.ts", "linked/v3-habits.ts"]) silent(runHook({ cwd, file: join(cwd, file) }));

    const stub = stubbed(`touch "${"$"}{0%/node_modules/*}/started"\necho "$3(1,1): warning effect(outdatedApi): a finding"`);
    const away = stubbed("true");
    symlinkSync(join(away, "src", "app.ts"), join(stub, "src", "link.ts"));
    symlinkSync(join(away, "src"), join(stub, "linked"));
    for (const file of ["src/link.ts", "linked/app.ts"]) {
      silent(runHook({ cwd: stub, file: join(stub, file) }));
      assert.ok(!existsSync(join(stub, "started")), `the hook started effect-tsgo for ${file}`);
    }
  });

  test("says nothing in a worktree with no effect-tsgo", () => {
    const cwd = realpathSync(tempDir("no-tsgo"));
    cpSync(fixture, cwd, { recursive: true });
    silent(runHook({ cwd, file: join(cwd, "src", "v3-habits.ts") }));
  });

  test("on its deadline kills the language service's process group and gives one line", () => {
    const cwd = stubbed(`echo $$ >"${"$"}{0%/node_modules/*}/group"\nsleep 30 &\nsleep 30\n`);
    const run = runHook({ cwd, file: join(cwd, "src", "app.ts"), env: { EFFECT_DIAGNOSTICS_DEADLINE_MS: "500" } });
    const text = context(run);
    assert.ok(run.ms < 500 + 2500, `the hook took ${run.ms} ms on a 500 ms deadline`);
    assert.equal(text.split("\n").length, 1, text);
    assert.match(text, /src\/app\.ts/);
    assert.match(text, /0\.5 s/);
    assert.ok(text.includes(checkCommand), text);
    const group = Number(readFileSync(join(cwd, "group"), "utf8"));
    assert.ok(group > 1);
    assert.ok(!alive(group), `process group ${group} is still alive`);
  });

  test("keeps the deadline its README records when no seam is set", () => {
    const cwd = stubbed("sleep 60");
    const run = runHook({ cwd, file: join(cwd, "src", "app.ts") });
    const text = context(run);
    assert.ok(run.ms >= deadlineSeconds * 1000, `the hook gave up after ${run.ms} ms`);
    assert.ok(run.ms < (deadlineSeconds + 3) * 1000, `the hook took ${run.ms} ms`);
    assert.match(text, new RegExp(`its ${deadlineSeconds} s deadline`));
  });

  test("cuts a long list of findings at 4,000 characters with a line saying how many it cut", () => {
    const cwd = stubbed(
      `i=1; while [ $i -le 300 ]; do echo "$3($i,1): warning effect(outdatedApi): finding number $i of many"; i=$((i+1)); done\n` +
        `echo "Checked 1 files out of 1 files."\necho "0 errors, 300 warnings and 0 messages."`,
    );
    const text = context(runHook({ cwd, file: join(cwd, "src", "app.ts") }));
    assert.ok(text.length <= 4000, `the context is ${text.length} characters`);
    const lines = text.split("\n");
    const shown = lines.filter((line) => line.startsWith("src/app.ts(")).length;
    assert.ok(shown > 10 && shown < 300, `${shown} findings shown`);
    assert.equal(lines.at(-1), `${300 - shown} more lines cut; run ${checkCommand} from the project's root for all of them.`);
    assert.ok(!text.includes("Checked 1 files"), "the summary lines came through");
  });

  test("gives one line with the exit code and the first line of stderr when the tool fails", () => {
    const cwd = stubbed("echo 'DiscoveryError: no typescript' >&2\necho 'at somewhere' >&2\nexit 3");
    const text = context(runHook({ cwd, file: join(cwd, "src", "app.ts") }));
    assert.equal(text.split("\n").length, 1, text);
    assert.match(text, /src\/app\.ts/);
    assert.match(text, /exit code 3/);
    assert.match(text, /DiscoveryError: no typescript/);
    assert.doesNotMatch(text, /at somewhere/);
  });

  test("cuts the tool's first stderr line at 300 characters", () => {
    const cwd = stubbed(`printf 'Error: %0500d\\n' 0 >&2\nexit 1`);
    const text = context(runHook({ cwd, file: join(cwd, "src", "app.ts") }));
    assert.equal(text.split("\n").length, 1, text);
    assert.ok(text.includes(`Error: ${"0".repeat(293)}... (207 characters cut)`), text);
    assert.ok(text.length < 450, `the line is ${text.length} characters`);
  });

  test("passes the stub the file and no version or tag", () => {
    const cwd = stubbed(`printf '%s\\n' "$@" >"${"$"}{0%/node_modules/*}/args"`);
    silent(runHook({ cwd, file: join(cwd, "src", "app.ts") }));
    assert.deepEqual(readFileSync(join(cwd, "args"), "utf8").trim().split("\n"),
      ["diagnostics", "--file", join(cwd, "src", "app.ts"), "--format", "text"]);
  });

  test("the skill's check command, as the skill writes it, reports the v3 rename on the fixture", () => {
    assert.ok(checkCommand, "the skill names no effect-tsgo check command");
    const cwd = project();
    const run = spawnSync("sh", ["-c", checkCommand], { cwd, encoding: "utf8", env: { HOME: cwd, PATH: testPath({ withOp: false }) } });
    assert.notEqual(run.status, 0, run.stdout);
    assert.match(run.stdout, /Renamed to catch\./);
    assert.match(run.stdout, /Renamed to forkChild\./);
  });

  // unshare -rn makes a user namespace with no network: no interface but a loopback that is down.
  // It needs Linux, and a machine that lets an unprivileged user make one, which CI's Ubuntu
  // runner refuses; the skip says why.
  const probe = process.platform === "linux" ? spawnSync("unshare", ["-rn", "true"], { encoding: "utf8" }) : undefined;
  const noNetwork = !probe
    ? `unshare -rn is Linux's, and this is ${process.platform}`
    : probe.status === 0
      ? false
      : `this machine refuses an unprivileged unshare -rn: ${(probe.error?.message ?? probe.stderr.trim().split("\n")[0]) || `exit code ${probe.status}`}`;
  test("gives the same findings with no network", { skip: noNetwork }, () => {
    const cwd = project();
    const file = join(cwd, "src", "v3-habits.ts");
    const offline = context(runHook({ cwd, file, wrap: ["unshare", "-rn"] }));
    assert.equal(offline, context(runHook({ cwd, file })));
    assert.match(offline, /Renamed to forkChild\./);
  });

  test("pins effect-tsgo, effect and typescript in its fixture as servers/ pins them", () => {
    const pins = JSON.parse(readFileSync(join(repoRoot, "servers", "package.json"), "utf8")).dependencies;
    const wanted = JSON.parse(readFileSync(join(fixture, "package.json"), "utf8")).dependencies;
    for (const [name, version] of Object.entries(wanted)) assert.equal(pins[name], version, name);
    assert.match(pins["@effect/tsgo"], /^\d+\.\d+\.\d+$/);
    assert.match(pins.typescript, /^7\.\d+\.\d+$/);
  });
});
