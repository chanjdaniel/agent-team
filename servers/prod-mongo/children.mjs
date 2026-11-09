// How prod-mongo's server starts a child process and what it may say of one: the only way a child
// gets an environment, and the only way a child's error text reaches an answer.
//
//   childEnv(extra)          the environment every child gets: the variables of `passed` that are
//                            set, then `extra`; never process.env whole, so never the secret
//   scrubber(value)          scrubbed(line): `line` with every mongodb:// or mongodb+srv:// token,
//                            `value`, its password and each of its hosts removed, cut at its first
//                            "{" and to at most 200 characters
//   run(command, args, { timeoutMs, onSpawn })
//                            runs a child with childEnv(), stdin ignored, its output captured,
//                            killed at `timeoutMs`; resolves { code, signal, timedOut, stdout,
//                            stderr }, or rejects when the command is not on PATH (code ENOENT)
//   lastLine(text)           the last non-empty line of a child's output, for scrubbed
import { spawn } from "node:child_process";

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

export function run(command, args, { timeoutMs, onSpawn } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: childEnv(), stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
    const timer = timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          child.kill("SIGKILL");
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

export function lastLine(text) {
  return String(text ?? "").split("\n").map((line) => line.trim()).filter(Boolean).at(-1) ?? "";
}
