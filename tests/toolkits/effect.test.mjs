// The effect toolkit as team-worker --toolkit effect loads it: its plugin layout and README, and
// its effect-v4 skill, whose limits and order of sections the test holds, and whose trap table it
// checks against the effect package servers/ pins: every name the GA column gives exists there, and
// every name a v3 or early-beta column gives is gone.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "effect");
const skillFile = join(toolkit, "skills", "effect-v4", "SKILL.md");
const skill = readFileSync(skillFile, "utf8");

describe("the effect toolkit", () => {
  test("is a plugin named effect with no hook, no MCP server and one skill, effect-v4", () => {
    const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
    assert.equal(manifest.name, "effect");
    assert.equal(manifest.author?.name, "Daniel Chan");
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.ok(!existsSync(join(toolkit, "hooks")), "the toolkit declares a hook");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "evals", "skills"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills")), ["effect-v4"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills", "effect-v4")), ["SKILL.md"]);
  });

  test("its README says when the coordinator gives it", () => {
    const readme = readFileSync(join(toolkit, "README.md"), "utf8");
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
