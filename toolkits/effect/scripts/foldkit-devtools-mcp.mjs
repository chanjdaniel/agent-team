#!/usr/bin/env node
// Foldkit's DevTools MCP server, as Claude Code starts it from ../.mcp.json, confined to the
// session's worktree: the pinned @foldkit/devtools-mcp (servers/), which reads the running Foldkit
// app's Models, Message history and Command arguments, replays it, and dispatches Messages.
//
// Usage: FOLDKIT_PROJECT_ROOT=<worktree> node foldkit-devtools-mcp.mjs
// team-worker fills the worktree in for .mcp.json's @WORKTREE@. It takes no arguments, so the
// server's `init` (which writes a project's .mcp.json) never runs.
// It refuses to start (exit 1, one line on stderr, the server never started) when given an
// argument, when FOLDKIT_PROJECT_ROOT is unset, not an absolute path (an unfilled @WORKTREE@
// among them) or no directory, when the platform is Windows, or when servers/ has no server.
//
// Why a wrapper: the server finds a dev server through the relay registry every Foldkit Vite dev
// server of the user writes to (FOLDKIT_DEVTOOLS_RELAY_DIRECTORY, else XDG_RUNTIME_DIR's, else
// ~/.cache's foldkit-devtools-relays/). It takes the dev servers whose root lies under its project
// root, and when none does, the nearest one whose root encloses it; a worktree sits inside its
// project's primary checkout (.claude/worktrees/N), so a slot with no dev server running would
// reach Daniel's own app, or another slot's when slots nest.
// So the server never reads that registry: it gets a private one of its own (a fresh directory
// under the temporary directory, mode 0700, removed when it exits), and before each message from
// the client reaches it, the wrapper copies there every record of the real registry whose root,
// by its real path, lies under the worktree's real path, and removes every other entry. The
// server reads the registry only while it handles a message, so it only ever sees this worktree's
// dev servers, and with none it says it is not connected.
// The real registry is read only when it passes the server's own trust check, the same rules
// (@foldkit/devtools-mcp's relayRegistryTrust): a directory, no symlink, owned by the user and
// shared with no one (mode 077 clear), each directory above it owned by the user or root and
// writable by no one else unless sticky, and on macOS no ACL entry allowing anyone access. One it
// refuses is ignored, as the server would, with one line on stderr saying why.
// FOLDKIT_DEVTOOLS_MCP_PORT and FOLDKIT_DEVTOOLS_MCP_HOST, which skip the registry for a fixed
// relay anyone on the network may run, never reach the server: one set is named on stderr and
// dropped. Its stdout is the server's own (the MCP stream), and its exit the server's.
import { execFileSync, spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const NAME = "foldkit-devtools";
const REGISTRY_NAME = "foldkit-devtools-relays";
const FIXED_RELAY_VARIABLES = ["FOLDKIT_DEVTOOLS_MCP_PORT", "FOLDKIT_DEVTOOLS_MCP_HOST"];
const server = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "servers", "node_modules",
  "@foldkit", "devtools-mcp", "dist", "server.js");

function refuse(reason) {
  process.stderr.write(`${NAME}: ${reason}\n`);
  process.exit(1);
}

if (process.argv.length > 2) refuse("takes no arguments");
if (process.platform === "win32") refuse("runs on Linux and macOS only");
const root = process.env.FOLDKIT_PROJECT_ROOT;
if (!root) refuse("FOLDKIT_PROJECT_ROOT is not set");
if (!isAbsolute(root)) refuse(`FOLDKIT_PROJECT_ROOT is not an absolute path: ${root}`);
let worktree;
try {
  worktree = realpathSync(root);
  if (!statSync(worktree).isDirectory()) throw new Error();
} catch {
  refuse(`FOLDKIT_PROJECT_ROOT is not a directory: ${root}`);
}
if (!existsSync(server)) refuse(`no server at ${server}: run servers/install`);

const registry = process.env.FOLDKIT_DEVTOOLS_RELAY_DIRECTORY
  || join(process.env.XDG_RUNTIME_DIR || join(homedir(), ".cache"), REGISTRY_NAME);

// Whether `candidate` is `base` or lies under it, as the server's isWithinRoot reads it.
function within(base, candidate) {
  const path = relative(base, candidate);
  return path === "" || (path !== ".." && !path.startsWith(`..${sep}`) && !isAbsolute(path));
}

const realOr = (path) => {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
};

// Why the server would refuse the registry at `directory`, or null when it would trust it.
function refusal(directory) {
  const me = process.getuid();
  const entry = lstatSync(directory);
  if (entry.isSymbolicLink() || !entry.isDirectory()) return "is not a regular directory";
  const canonical = realpathSync(directory);
  const chain = [];
  for (let at = canonical; ; at = dirname(at)) {
    chain.unshift(at);
    if (dirname(at) === at) break;
  }
  for (const at of chain) {
    const info = lstatSync(at);
    if (info.isSymbolicLink() || !info.isDirectory()) return "has ownership that cannot be verified";
    if (at === canonical) {
      if (info.uid !== me) return "is owned by another user";
      if ((info.mode & 0o077) !== 0) return "is readable or writable by other users";
    } else {
      if (info.uid !== me && info.uid !== 0) return "has a parent directory that another user can replace";
      if ((info.mode & 0o022) !== 0 && (info.mode & 0o1000) === 0) return "has a parent directory that another user can replace";
    }
    if (process.platform === "darwin") {
      const listing = execFileSync("/bin/ls", ["-l", "-d", "-e", "-P", "-b", "--", at], {
        encoding: "utf8",
        env: { ...process.env, LC_ALL: "C" },
        stdio: ["ignore", "pipe", "ignore"],
      });
      if (listing.split("\n").slice(1).some((line) => /^\s*\d+:\s+.+\sallow\s+\S+/.test(line))) {
        return at === canonical ? "is readable or writable by other users" : "has a parent directory that another user can replace";
      }
    }
  }
  return null;
}

const reported = new Set();
function report(line) {
  if (reported.has(line)) return;
  reported.add(line);
  process.stderr.write(`${NAME}: ${line}\n`);
}

// The records of the real registry whose root lies under the worktree, by file name.
function wantedRecords() {
  const wanted = new Map();
  if (!existsSync(registry)) return wanted;
  let why;
  try {
    why = refusal(registry);
  } catch {
    why = "has ownership that cannot be verified";
  }
  if (why) {
    report(`ignoring the relay registry at ${registry}: it ${why}`);
    return wanted;
  }
  let names = [];
  try {
    names = readdirSync(registry);
  } catch {
    return wanted;
  }
  for (const name of names.filter((n) => n.endsWith(".json"))) {
    const path = join(registry, name);
    try {
      if (!lstatSync(path).isFile()) continue;
      const text = readFileSync(path, "utf8");
      const record = JSON.parse(text);
      if (typeof record?.root !== "string" || !isAbsolute(record.root)) continue;
      if (within(worktree, realOr(record.root))) wanted.set(name, text);
    } catch {
      // A record being written, retired or malformed: the server would skip it too.
    }
  }
  return wanted;
}

const mirror = mkdtempSync(join(tmpdir(), `${NAME}-`));
const cleanUp = () => rmSync(mirror, { recursive: true, force: true });
process.on("exit", cleanUp);

// The mirror only ever holds records under the worktree, so a sync that fails part way leaves it
// confined, and the next message tries again.
function sync() {
  try {
    copyWanted();
  } catch (error) {
    report(`could not update its relay registry: ${error.message}`);
  }
}

function copyWanted() {
  const wanted = wantedRecords();
  for (const name of readdirSync(mirror)) {
    if (!wanted.has(name)) rmSync(join(mirror, name), { recursive: true, force: true });
  }
  for (const [name, text] of wanted) {
    const path = join(mirror, name);
    let current = null;
    try {
      current = readFileSync(path, "utf8");
    } catch {
      // Not copied yet.
    }
    if (current === text) continue;
    writeFileSync(`${path}.pending`, text, { mode: 0o600 });
    renameSync(`${path}.pending`, path);
  }
}

const env = { ...process.env, FOLDKIT_PROJECT_ROOT: worktree, FOLDKIT_DEVTOOLS_RELAY_DIRECTORY: mirror };
for (const variable of FIXED_RELAY_VARIABLES) {
  if (variable in env) {
    report(`ignoring ${variable}: the server finds only this worktree's dev servers`);
    delete env[variable];
  }
}

sync();
const child = spawn(process.execPath, [server], { env, stdio: ["pipe", "inherit", "inherit"] });
child.on("error", (error) => {
  cleanUp();
  refuse(`could not start the server: ${error.message}`);
});
child.stdin.on("error", () => {});
process.stdin.on("data", (chunk) => {
  sync();
  if (!child.stdin.write(chunk)) {
    process.stdin.pause();
    child.stdin.once("drain", () => process.stdin.resume());
  }
});
process.stdin.on("end", () => child.stdin.end());
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => child.kill(signal));
child.on("exit", (code, signal) => {
  cleanUp();
  if (signal) {
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
  }
  process.exit(code ?? 1);
});
