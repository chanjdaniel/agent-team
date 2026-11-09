// How prod-mongo's server starts a child process and what it may say of one: the only way a child
// gets an environment, and the only way a child's error text reaches an answer.
//
//   childEnv(extra)          the environment every child gets: the variables of `passed` that are
//                            set, then `extra`; never process.env whole, so never the secret
//   scrubber(value)          scrubbed(line): `line` with every mongodb:// or mongodb+srv:// token,
//                            `value`, its password and each of its hosts removed, cut at its first
//                            "{" and to at most 200 characters
//   run(command, args, { timeoutMs, onSpawn, env, killSignal })
//                            runs a child with childEnv() (or `env`), stdin ignored, its output
//                            captured, sent `killSignal` (SIGKILL) at `timeoutMs`; resolves
//                            { code, signal, timedOut, stdout, stderr }, or rejects when the
//                            command is not on PATH (code ENOENT)
//   runWithConfig(command, argsOf, { fifo, config, timeoutMs })
//                            run(command, argsOf(fifo)) for a Database Tool that takes its secret
//                            as `--config=<fifo>`: makes the FIFO with mkfifo -m 600 (at a path in
//                            the caller's own 0700 directory), writes `config` into it once the
//                            child opens its end, and unlinks it then and again when the child
//                            ends; resolves run's result with `fedError`, the Error of a feed that
//                            failed (the child is killed then), or rejects as run does, or with an
//                            Error whose `mkfifo` is true
//   yamlConfig(key, value)   one YAML line `<key>: '<value>'`, the value a single-quoted scalar
//   lastLine(text)           the last non-empty line of a child's output, for scrubbed
//
// Node's stdio "pipe" is a socketpair on Linux, which a child cannot open as /dev/stdin, so a
// secret goes to a Database Tool through a FIFO it opens by path.
import { spawn, spawnSync } from "node:child_process";
import { closeSync, constants, openSync, rmSync, unlinkSync, writeSync } from "node:fs";

// TEAM_HEAVY_HELD passes through, since a nested team-heavy under a held lock would wait for
// itself (tests/run toolkits holds it).
const passed = ["PATH", "HOME", "LANG", "AGENT_TEAM_TASK", "TEAM_HEAVY_HELD", "DOCKER_HOST", "DOCKER_CONTEXT"];

export function childEnv(extra = {}) {
  const env = {};
  for (const key of passed) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  return { ...env, ...extra };
}

const maxLine = 200;

export function scrubber(value) {
  const secrets = [value];
  const parsed = parseConnectionString(value);
  if (parsed.password) secrets.push(parsed.password, encodeURIComponent(parsed.password));
  secrets.push(...parsed.hosts);
  // Longest first, so a host that is part of the value never leaves the rest behind.
  const parts = [...new Set(secrets.filter((part) => part && part.length >= 3))].sort((a, b) => b.length - a.length);
  return function scrubbed(line) {
    let text = String(line ?? "");
    const brace = text.indexOf("{");
    if (brace >= 0) text = text.slice(0, brace);
    text = text.replace(/mongodb(\+srv)?:\/\/\S*/g, "[uri]");
    for (const part of parts) text = text.replaceAll(part, "[redacted]");
    text = text.replace(/\s+/g, " ").trim();
    return text.length > maxLine ? `${text.slice(0, maxLine - 3)}...` : text;
  };
}

// The password and the hosts (with and without their ports) of a connection string, read by hand
// so a malformed one still gives what it holds.
function parseConnectionString(value) {
  const match = /^mongodb(?:\+srv)?:\/\/(?:([^@/]*)@)?([^/?]*)/.exec(value);
  if (!match) return { hosts: [] };
  const [, credentials = "", hostList] = match;
  const colon = credentials.indexOf(":");
  let password = colon >= 0 ? credentials.slice(colon + 1) : "";
  try {
    password = decodeURIComponent(password);
  } catch {
    // Keep it as written.
  }
  const hosts = [];
  for (const host of hostList.split(",").filter(Boolean)) {
    hosts.push(host, host.replace(/:\d+$/, ""));
  }
  return { password, hosts };
}

export function run(command, args, { timeoutMs, onSpawn, env = childEnv(), killSignal = "SIGKILL" } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
    const timer = timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          child.kill(killSignal);
        }, timeoutMs)
      : null;
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, timedOut, stdout, stderr });
    });
    onSpawn?.(child);
  });
}

const fifoOpenTimeoutMs = 30_000;

export function yamlConfig(key, value) {
  return `${key}: '${String(value).replaceAll("'", "''")}'\n`;
}

export async function runWithConfig(command, argsOf, { fifo, config, timeoutMs }) {
  const made = spawnSync("mkfifo", ["-m", "600", fifo], { env: childEnv(), stdio: ["ignore", "ignore", "pipe"], encoding: "utf8" });
  if (made.error || made.status !== 0) {
    throw Object.assign(new Error(lastLine(made.stderr) || made.error?.message || `mkfifo exited ${made.status}`), { mkfifo: true });
  }
  let fed;
  let result;
  try {
    result = await run(command, argsOf(fifo), {
      timeoutMs,
      onSpawn: (child) => {
        fed = feed(fifo, config, child).finally(() => rmSync(fifo, { force: true }));
        fed.catch(() => child.kill("SIGKILL"));
      },
    });
  } finally {
    rmSync(fifo, { force: true });
  }
  let fedError;
  try {
    await fed;
  } catch (error) {
    fedError = error;
  }
  return { ...result, fedError };
}

// Open the FIFO for writing without blocking, which fails with ENXIO until the child opens its
// end: retry every 10 ms until it does, it exits, or 30 seconds pass.
async function feed(fifo, text, child) {
  const start = Date.now();
  for (;;) {
    let fd;
    try {
      fd = openSync(fifo, constants.O_WRONLY | constants.O_NONBLOCK);
    } catch (error) {
      if (error.code !== "ENXIO") throw error;
      if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) throw new Error(`${child.spawnfile} exited first`);
      if (Date.now() - start > fifoOpenTimeoutMs) throw new Error(`not opened in ${fifoOpenTimeoutMs / 1000} s`);
      await new Promise((resolve) => setTimeout(resolve, 10));
      continue;
    }
    try {
      writeSync(fd, text);
    } finally {
      closeSync(fd);
      unlinkSync(fifo);
    }
    return;
  }
}

export function lastLine(text) {
  return String(text ?? "").split("\n").map((line) => line.trim()).filter(Boolean).at(-1) ?? "";
}
