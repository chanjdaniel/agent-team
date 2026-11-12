// The spec-review toolkit as team-worker --toolkit spec-review loads it: its plugin layout, its two
// read-only reader agents' frontmatter (their read-only tools, omitClaudeMd and model), its
// spec-review skill's name, limits and order of steps, its README's sections in the effect
// toolkit's order, its coordinator section and attribution line, and each eval case's graders.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "spec-review");
const read = (...parts) => readFileSync(join(toolkit, ...parts), "utf8");
const frontmatterOf = (text) => text.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? "";
const fieldOf = (frontmatter, name) => frontmatter.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];

const skillFile = join(toolkit, "skills", "spec-review", "SKILL.md");
const skill = readFileSync(skillFile, "utf8");
const readme = read("README.md");

describe("the spec-review toolkit", () => {
  test("is a plugin named spec-review with two agents and one skill, and no MCP server, hook or script", () => {
    const manifest = JSON.parse(read(".claude-plugin", "plugin.json"));
    assert.equal(manifest.name, "spec-review");
    assert.equal(manifest.author?.name, "Daniel Chan");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "agents", "evals", "skills"]);
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.ok(!existsSync(join(toolkit, "hooks")), "the toolkit has hooks");
    assert.ok(!existsSync(join(toolkit, "scripts")), "the toolkit has scripts");
    assert.deepEqual(readdirSync(join(toolkit, "agents")).sort(), ["spec-paraphrase.md", "spec-readiness.md"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills")), ["spec-review"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills", "spec-review")), ["SKILL.md"]);
  });

  test("its README says when the coordinator gives it", () => {
    assert.match(readme, /^## When the coordinator gives it$/m);
    assert.match(readme, /--toolkit spec-review/);
  });

  test("its README has the effect toolkit's sections, in order", () => {
    const headings = [...readme.matchAll(/^## (.*)$/gm)].map(([, heading]) => heading);
    assert.deepEqual(headings, ["When the coordinator gives it", "What loads", "What it costs", "Credits", "Tests"]);
  });

  test("its README credits elephant-goldfish-model and its licence, and names no copyright holder", () => {
    const credits = readme.split("## Credits\n")[1].split("\n## ")[0];
    const line = "Its method is adapted from google/elephant-goldfish-model (https://github.com/google/elephant-goldfish-model, commit e9e1f06), Apache License 2.0.";
    assert.ok(credits.split("\n").includes(line), "the Credits section lacks the attribution line");
    assert.doesNotMatch(credits, /Copyright \(c\)|Copyright \d/);
  });
});

describe("the reader agents", () => {
  for (const name of ["spec-paraphrase", "spec-readiness"]) {
    const text = read("agents", `${name}.md`);
    const frontmatter = frontmatterOf(text);
    test(`${name} is read-only, omits CLAUDE.md and names a model`, () => {
      assert.equal(fieldOf(frontmatter, "name"), name);
      assert.ok(fieldOf(frontmatter, "description"), `${name} has no description`);
      assert.equal(fieldOf(frontmatter, "tools"), "[Read, Grep, Glob]");
      assert.equal(fieldOf(frontmatter, "omitClaudeMd"), "true");
      assert.match(fieldOf(frontmatter, "model") ?? "", /^(inherit|opus|sonnet|haiku|claude-[\w-]+)$/);
    });

    test(`${name} is told never to read the task directory beyond its inputs`, () => {
      for (const file of ["plan.md", "brief", "interview.md", "memory.md", "handoff.md", "build-notes/", "spec-review.md"]) {
        assert.ok(text.includes(`\`${file}`), `${name} does not forbid ${file}`);
      }
    });
  }

  test("spec-paraphrase returns exactly the spec's three headed parts", () => {
    const text = read("agents", "spec-paraphrase.md");
    for (const part of ["## What this changes", "## How the system works today, per this spec", "## Could not follow"]) {
      assert.ok(text.includes(part), `spec-paraphrase does not return ${part}`);
    }
  });

  test("spec-readiness reads the code root's CLAUDE.md and AGENTS.md first, and returns its findings and what it read", () => {
    const text = read("agents", "spec-readiness.md");
    const order = ["<code root>/CLAUDE.md", "<code root>/AGENTS.md", "<task dir>/spec.md", "<task dir>/scope.txt", "<task dir>/tickets/"];
    const at = order.map((step) => text.indexOf(step));
    order.forEach((step, i) => assert.ok(at[i] >= 0, `spec-readiness does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "spec-readiness reads out of order");
    for (const kind of ["open-decision", "missing", "contradiction", "too-large"]) assert.ok(text.includes(`\`${kind}\``), kind);
    assert.ok(text.includes("- <severity> <kind> <where>: <finding>"));
    assert.ok(text.includes("Left to the builder"));
    assert.ok(text.indexOf("## Findings") < text.indexOf("## Read"));
  });
});

const skillFrontmatter = frontmatterOf(skill);

describe("the spec-review skill", () => {
  test("is named spec-review, its description under 250 characters and its whole file under 8 kB", () => {
    assert.equal(fieldOf(skillFrontmatter, "name"), "spec-review");
    const description = fieldOf(skillFrontmatter, "description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /spec/);
    assert.match(description, /before the plan is approved/);
    assert.match(description, /[Nn]ot for (a )?code review/);
    const size = Buffer.byteLength(skill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  test("takes a task directory, a code root and a model", () => {
    assert.ok(skill.includes("/spec-review [<task dir>] [<code root>] [--model sonnet|opus]"));
  });

  // A skill of the same name in another plugin a session loads would bring the skill to a session
  // without the toolkit.
  test("is the only skill named spec-review in any toolkit or the coordinator's plugin", () => {
    const named = [];
    for (const root of [join(repoRoot, "toolkits"), join(repoRoot, "plugins")]) {
      for (const plugin of readdirSync(root)) {
        const skills = join(root, plugin, "skills");
        if (!existsSync(skills)) continue;
        for (const dir of readdirSync(skills)) {
          const text = readFileSync(join(skills, dir, "SKILL.md"), "utf8");
          if (dir === "spec-review" || /^name: spec-review$/m.test(text)) named.push(`${plugin}/${dir}`);
        }
      }
    }
    assert.deepEqual(named, ["spec-review/spec-review"]);
  });

  test("holds its eight steps in the spec's order", () => {
    const steps = [
      "## 1. Check the inputs",
      "## 2. Dispatch both readers at once",
      "`spec-review:spec-paraphrase`",
      "`spec-review:spec-readiness`",
      "## 3. Retry a failed reader once",
      "not run: <why>",
      "## 4. Write `spec-review.md`",
      "escalated: none",
      "## 5. Stop here on a spec you did not write",
      "## 6. Compare the paraphrase with your plan",
      "`misread`",
      "## 7. Sort every finding",
      "`fix`",
      "`contest`",
      "`escalate`",
      "## 8. Rewrite the table",
    ];
    const at = steps.map((step) => skill.indexOf(step));
    steps.forEach((step, i) => assert.ok(at[i] >= 0, `the skill does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "the skill's steps are out of order");
    assert.ok(skill.includes("| # | Reader | Severity | Kind | Where | Finding | Sort | Evidence |"));
  });
});

// Each case is one case.yaml, its fixture written by its scaffold script, its graders listed in it.
const evals = join(toolkit, "evals");
const caseOf = (name) => read("evals", name, "case.yaml");
// The graders a case.yaml lists, each its own block of lines from "  - name:" on.
const gradersOf = (text) => text.split(/^graders:\n/m)[1].split(/^(?=  - name: )/m).filter((block) => block.trim());

describe("the spec-review evals", () => {
  const cases = ["planner-notes-stay-out", "replay-an-ignored-tree", "review-a-code-diff", "review-a-spec"];

  test("are four cases, each a case.yaml and its scaffold script", () => {
    assert.deepEqual(readdirSync(evals).filter((name) => name !== "results").sort(), cases);
    for (const name of cases) {
      assert.deepEqual(readdirSync(join(evals, name)).sort(), ["case.yaml", "scaffold.sh"]);
      const text = caseOf(name);
      assert.match(text, /^schema_version: "1\.1"$/m);
      assert.match(text, new RegExp(`^name: ${name}$`, "m"));
      assert.match(text, /^ {2}scaffold_script: scaffold\.sh$/m);
      assert.match(text, /^ {2}model: claude-opus-5-5$/m);
      assert.match(text, /^ {2}allowed_tools: \[Read, Glob, Grep, Skill, Agent\]$/m);
      assert.match(text, /^ {2}prompt: \|$/m);
    }
  });

  test("review-a-spec fires the skill, dispatches both readers and grades the two planted faults", () => {
    const graders = gradersOf(caseOf("review-a-spec"));
    const skillFired = graders.find((block) => /tool: Skill/.test(block));
    assert.match(skillFired, /type: tool_used/);
    assert.match(skillFired, /spec-review/);
    for (const agent of ["spec-paraphrase", "spec-readiness"]) {
      const dispatched = graders.find((block) => /tool: Agent/.test(block) && block.includes(agent));
      assert.ok(dispatched, `no grader for ${agent}`);
      assert.match(dispatched, /type: tool_used/);
      assert.match(dispatched, /spec-review:/);
      assert.match(dispatched, /arm: with-only/);
    }
    const judged = graders.find((block) => /type: llm/.test(block));
    assert.match(judged, /open-decision/);
    assert.match(judged, /missing/);
    assert.match(judged, /blocking/);
    assert.equal(graders.length, 4);
  });

  test("planner-notes-stay-out dispatches the readiness reader and fails on the planner's notes in the trace", () => {
    const graders = gradersOf(caseOf("planner-notes-stay-out"));
    assert.equal(graders.length, 2);
    const dispatched = graders.find((block) => /tool: Agent/.test(block));
    assert.match(dispatched, /spec-review:spec-readiness/);
    assert.match(dispatched, /arm: with-only/);
    const unseen = graders.find((block) => /type: regex/.test(block));
    assert.match(unseen, /target: trace/);
    assert.match(unseen, /match: not_contains/);
    // The pattern names the notes' marker and their paths, on a reader's own line of the trace.
    const pattern = unseen.match(/pattern: '([^']+)'/)[1];
    const marker = pattern.match(/^\(([A-Z][A-Z-]+)\|/)[1];
    assert.ok(pattern.includes("(memory|plan)"), "the pattern does not name both notes");
    assert.ok(pattern.endsWith('"parent_tool_use_id":"toolu_'), "the pattern is not held to a reader's lines");
    const scaffold = read("evals", "planner-notes-stay-out", "scaffold.sh");
    for (const note of ["memory.md", "plan.md"]) {
      const body = scaffold.split(`cat >.scratch/task/${note} <<'EOF'\n`)[1].split("\nEOF\n")[0];
      assert.ok(body.includes(marker), `${note} lacks the marker`);
      assert.ok(body.includes("archive_notes"), `${note} lacks the function the spec extends`);
    }
    assert.match(scaffold, /^\.scratch\/$/m);
    assert.match(scaffold, /^git init -q$/m);
  });

  test("replay-an-ignored-tree fires the skill, dispatches the readiness reader and judges the tree's search", () => {
    const graders = gradersOf(caseOf("replay-an-ignored-tree"));
    assert.equal(graders.length, 3);
    assert.match(graders.find((block) => /tool: Skill/.test(block)), /spec-review/);
    assert.match(graders.find((block) => /tool: Agent/.test(block)), /spec-review:spec-readiness/);
    const judged = graders.find((block) => /type: llm/.test(block));
    assert.match(judged, /prune_notes/);
    assert.match(judged, /rotate_notes/);
    const scaffold = read("evals", "replay-an-ignored-tree", "scaffold.sh");
    assert.match(scaffold, /^tree=\.scratch\/task\/replay\/T9\/tree$/m);
    assert.match(scaffold, /^\.scratch\/$/m);
    assert.match(scaffold, /^git init -q$/m);
  });

  test("review-a-code-diff never fires the skill", () => {
    const graders = gradersOf(caseOf("review-a-code-diff"));
    assert.equal(graders.length, 1);
    assert.match(graders[0], /type: tool_used/);
    assert.match(graders[0], /tool: Skill/);
    assert.match(graders[0], /spec-review/);
    assert.match(graders[0], /min: 0/);
    assert.match(graders[0], /max: 0/);
  });
});
