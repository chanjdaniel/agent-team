// Start the pinned MongoDB MCP server in this process, with a connection string read from
// 1Password: the shared body of each toolkit's scripts/start-server.mjs.
//
//   await startMongodbMcp({ name, reference, settings })
//
// It reads the secret reference with `op read --no-newline` (execFileSync, no shell, stdin
// ignored because stdin is the MCP transport), runs `op signout`, drops every inherited MDB_MCP_*
// variable, sets the connection string, the toolkit's settings and the fixed ones below in its
// own process.env, refuses every child process, then imports the server's entry point. Nothing
// is exec'd and nothing exported, so the string is never in a starting environment: not in this
// process's /proc/<pid>/environ, and not in a child's, since there are none.
// On any failure it exits 1 before the server starts, with one line on stderr that never holds
// the value.
import childProcess from "node:child_process";
import { readFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const serverDir = join(here, "node_modules", "mongodb-mcp-server");

// Settings every toolkit gets, whatever it passes: no telemetry, logs only to stderr (none on
// disk under ~/.mongodb/), no server-side JavaScript, results wrapped as untrusted data.
const fixedSettings = {
  MDB_MCP_TELEMETRY: "disabled",
  DO_NOT_TRACK: "1",
  MDB_MCP_LOGGERS: "stderr",
  MDB_MCP_DISABLE_SERVER_SIDE_JS: "true",
  MDB_MCP_DISABLE_UNTRUSTED_DATA_WARNING: "false",
};

// 1Password gives up on its own prompt after about 60 seconds; this is a backstop, inside the
// session's MCP_TIMEOUT of 120 seconds.
const opTimeoutMs = 90_000;

export async function startMongodbMcp({ name, reference, settings }) {
  let value;
  const fail = (reason) => {
    let line = String(reason).split("\n").map((part) => part.trim()).filter(Boolean).join(" ");
    if (value) line = line.replaceAll(value, "[redacted]");
    process.stderr.write(`${name}: ${line}\n`);
    process.exit(1);
  };
  const op = (args, what) => {
    try {
      return childProcess.execFileSync("op", args, {
        stdio: ["ignore", "pipe", "pipe"],
        encoding: "utf8",
        timeout: opTimeoutMs,
      });
    } catch (error) {
      if (error.code === "ENOENT") fail("op is not on PATH");
      if (error.signal) fail(`${what} did not finish (${error.signal})`);
      fail(`${what} failed: ${error.stderr?.trim().split("\n").at(-1) || `exit ${error.status}`}`);
    }
  };

  if (process.argv.length > 2) fail("takes no arguments");
  let entry;
  try {
    const pkg = JSON.parse(readFileSync(join(serverDir, "package.json"), "utf8"));
    entry = join(serverDir, pkg.bin["mongodb-mcp-server"]);
  } catch {
    fail("the pinned MongoDB MCP server is not installed: run servers/install");
  }

  value = op(["read", "--no-newline", reference], "op read");
  op(["signout"], "op signout");
  if (!value.trim()) fail("op read returned an empty value");
  if (!/^mongodb(\+srv)?:\/\//.test(value)) fail("op read returned something that is not a MongoDB connection string");

  for (const key of Object.keys(process.env)) {
    if (key.startsWith("MDB_MCP_")) delete process.env[key];
  }
  Object.assign(process.env, settings, fixedSettings, { MDB_MCP_CONNECTION_STRING: value });

  // A child would start with this environment, connection string included. The server's only
  // child is node-machine-id's shell for the device id, which falls back to "unknown".
  const refuse = () => {
    throw new Error(`${name}: child processes are disabled`);
  };
  for (const fn of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
    childProcess[fn] = refuse;
  }
  syncBuiltinESMExports();

  await import(pathToFileURL(entry).href);
}
