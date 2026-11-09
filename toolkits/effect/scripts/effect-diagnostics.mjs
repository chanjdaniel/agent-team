#!/usr/bin/env node
// The effect toolkit's PostToolUse hook: after an Edit, Write or MultiEdit of a TypeScript file,
// Effect's language service's findings for that one file, given back to the session as additional
// context, so a v3 or early-beta habit is named with its v4 replacement at the edit that wrote it.
//
// Usage: node effect-diagnostics.mjs < <PostToolUse event JSON>
// Claude Code runs it from the toolkit's hooks/hooks.json, with the event on stdin; it reads only
// tool_input.file_path and cwd (https://code.claude.com/docs/en/hooks, "PostToolUse input").
// It does nothing (no output, exit 0) unless the file ends in .ts, .tsx, .mts or .cts and is no
// declaration file (.d.ts, .d.mts, .d.cts, .d.<ext>.ts), lies under cwd and outside any
// node_modules, some directory from the file's up to cwd holds node_modules/.bin/effect-tsgo, and
// some directory from the file's up to cwd holds a tsconfig.json: the CLI takes the nearest
// tsconfig.json, wherever it is, so without one under cwd it would judge the file by a checkout
// that encloses the worktree.
// It runs the nearest such effect-tsgo as `diagnostics --file <file> --format text`, with no
// version or tag argument, so it fetches nothing and runs what the project pinned; its working
// directory is the one holding that node_modules, and it runs in a process group of its own. The
// CLI finds the file's tsconfig.json itself, the nearest one only, and skips the file when that one
// does not include it: its --project checks the whole project beside the file, so the hook never
// passes one.
// It prints, as the event's documented JSON output ("PostToolUse decision control",
// hookSpecificOutput with hookEventName "PostToolUse" and additionalContext):
//   - the file's findings, whatever the exit code, under one line naming the file relative to
//     cwd, each finding's path made relative too, the CLI's summary lines left out, cut at 4,000
//     characters with a last line saying how many lines were cut and naming the effect-v4 skill's
//     check, node_modules/.bin/effect-tsgo tsc -p tsconfig.json;
//   - on the deadline, after killing the process group: one line with the file, the deadline and
//     that check, to run before delivering;
//   - on a failure of the tool itself (no findings and a non-zero exit, a signal, or no start):
//     one line with the exit code and the first line of its stderr, or why it could not start,
//     that part cut to 300 characters.
// With no findings it prints nothing, so a file the project's tsconfig does not include (the CLI
// skips it) is silent. It never blocks the edit: it always exits 0, never 2.
// The findings are Effect's rules only, never type errors, which the skill's check gives; a
// project below TypeScript 7 (@effect/language-service only) has no effect-tsgo and gets none.
//
// Environment:
//   EFFECT_DIAGNOSTICS_DEADLINE_MS  the deadline in milliseconds, in place of the default of 3 s
//                                   (the README's "What it costs" says how it was set); the
//                                   test's seam, never set by settings
import { spawn } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

const defaultDeadlineMs = 3000;
const cap = 4000;
// The most characters of the tool's own line (its first stderr line, or why it could not start).
const lineCap = 300;
const check = "node_modules/.bin/effect-tsgo tsc -p tsconfig.json";

// The CLI's summary lines, which say nothing of the file.
const summary = /^(Checked \d+ files? out of \d+ files?\.|Skipped \d+ files? because .*|\d+ errors?, \d+ warnings? and \d+ messages?\.)\s*$/;
// A finding's first line: a path, a line and column, and the rest.
const located = /^(.+?)\((\d+),(\d+)\): (.*)$/;

// The line cut to lineCap characters, saying so when it cut.
function short(line) {
  return line.length <= lineCap ? line : `${line.slice(0, lineCap)}... (${line.length - lineCap} characters cut)`;
}

function give(text) {
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text } })}\n`);
}

function real(path) {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

// The path from base to path, or undefined when path is not under base.
function under(base, path) {
  const rel = relative(base, path);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return undefined;
  return rel;
}

// The nearest directory from the file's up to cwd that holds node_modules/.bin/effect-tsgo.
function nearestTsgo(file, cwd) {
  for (let dir = dirname(file); ; dir = dirname(dir)) {
    const bin = join(dir, "node_modules", ".bin", "effect-tsgo");
    if (existsSync(bin)) return { dir, bin };
    if (dir === cwd || dirname(dir) === dir) return undefined;
  }
}

// Whether some directory from the file's up to cwd holds a tsconfig.json.
function tsconfigUnder(file, cwd) {
  for (let dir = dirname(file); ; dir = dirname(dir)) {
    if (existsSync(join(dir, "tsconfig.json"))) return true;
    if (dir === cwd || dirname(dir) === dir) return false;
  }
}

// The findings in the CLI's stdout, each path given relative to cwd.
function findingsOf(stdout, paths, shown) {
  const lines = stdout.split(/\r?\n/);
  const first = lines.findIndex((line) => located.test(line));
  if (first < 0) return [];
  return lines.slice(first)
    .filter((line) => line.trim() !== "" && !summary.test(line))
    .map((line) => {
      const path = paths.find((p) => line.startsWith(`${p}(`));
      return path ? shown + line.slice(path.length) : line;
    });
}

// The findings under their head, whole lines only, cut to the cap with the cut-lines line.
function capped(head, lines) {
  const whole = [head, ...lines].join("\n");
  if (whole.length <= cap) return whole;
  const cut = (n) => `${n} more lines cut; run ${check} from the project's root for all of them.`;
  let text = head;
  let i = 0;
  while (i < lines.length && `${text}\n${lines[i]}\n${cut(lines.length - i - 1)}`.length <= cap) {
    text += `\n${lines[i]}`;
    i++;
  }
  return `${text}\n${cut(lines.length - i)}`;
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return;
  }
  const given = event?.tool_input?.file_path;
  if (typeof given !== "string" || given === "") return;
  if (!/\.(ts|tsx|mts|cts)$/.test(given) || /\.d(\.[^./\\]+)?\.[mc]?ts$/.test(given)) return;
  const cwd = real(typeof event.cwd === "string" && event.cwd !== "" ? event.cwd : process.cwd());
  const file = real(isAbsolute(given) ? given : resolve(cwd, given));
  const shown = under(cwd, file);
  if (shown === undefined || shown.split(sep).includes("node_modules")) return;
  const tsgo = nearestTsgo(file, cwd);
  if (!tsgo || !tsconfigUnder(file, cwd)) return;

  const seam = Number(process.env.EFFECT_DIAGNOSTICS_DEADLINE_MS);
  const deadlineMs = Number.isFinite(seam) && seam > 0 ? seam : defaultDeadlineMs;
  const child = spawn(tsgo.bin, ["diagnostics", "--file", file, "--format", "text"], {
    cwd: tsgo.dir,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });

  let done = false;
  const finish = (text) => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    if (text) give(text);
    process.exitCode = 0;
  };
  const timer = setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      // The group is gone already.
    }
    finish(`effect-tsgo diagnostics on ${shown} passed its ${deadlineMs / 1000} s deadline and was stopped; run ${check} from the project's root before delivering.`);
    // A child that left the group may hold the pipes open: end now.
    process.stdout.write("", () => process.exit(0));
  }, deadlineMs);

  child.on("error", (error) => {
    finish(`effect-tsgo diagnostics on ${shown} could not start: ${short(error.message)}`);
  });
  child.on("close", (code, signal) => {
    const lines = findingsOf(stdout, [...new Set([file, given])], shown);
    if (lines.length > 0) return finish(capped(`Effect's language service on ${shown}:`, lines));
    if (code === 0) return finish();
    const first = stderr.split(/\r?\n/).find((line) => line.trim() !== "")?.trim() ?? "no stderr";
    const how = signal ? `signal ${signal}` : `exit code ${code}`;
    finish(`effect-tsgo diagnostics on ${shown} failed with ${how}: ${short(first)}`);
  });
}

try {
  main();
} catch {
  process.exitCode = 0;
}
