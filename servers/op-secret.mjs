// Read secrets from 1Password for a toolkit's MCP server, and keep this process from starting a
// child that would inherit them: the shared part of each server body (mongodb-mcp.mjs and
// vercel-mcp.mjs).
//
//   const [first, second] = readSecrets(name, [reference, ...], (value, reference) => reason)
//   refuseChildProcesses(name)
//
// readSecrets runs `op read --no-newline <reference>` for each reference in turn, then one
// `op signout` (each execFileSync, no shell, stdin ignored because stdin is the MCP transport,
// with a 90-second backstop), so 1Password authorizes the reads once. Each value must be
// non-empty, and `validate` may return a reason to refuse it, or nothing. It returns the values
// in the order of their references. On any failure it exits 1 with one `<name>: <reason>` line on
// stderr, from which every value read so far is redacted, so the line never holds one.
// refuseChildProcesses replaces every child_process function with one that throws, and syncs the
// ESM exports, so a child can never start with this process's environment.
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";

// 1Password gives up on its own prompt after about 60 seconds; this is a backstop, inside the
// session's MCP_TIMEOUT of 120 seconds.
const opTimeoutMs = 90_000;

export function readSecrets(name, references, validate) {
  const values = [];
  const fail = (reason) => {
    let line = String(reason).split("\n").map((part) => part.trim()).filter(Boolean).join(" ");
    for (const value of values) {
      if (value) line = line.replaceAll(value, "[redacted]");
    }
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

  for (const reference of references) values.push(op(["read", "--no-newline", reference], "op read"));
  op(["signout"], "op signout");
  references.forEach((reference, index) => {
    const value = values[index];
    if (!value.trim()) fail("op read returned an empty value");
    const reason = validate(value, reference);
    if (reason) fail(reason);
  });
  return values;
}

export function refuseChildProcesses(name) {
  const refuse = () => {
    throw new Error(`${name}: child processes are disabled`);
  };
  for (const fn of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
    childProcess[fn] = refuse;
  }
  syncBuiltinESMExports();
}
