// A toolkit's MCP server started exactly as its .mcp.json declares, with @TEAM_HOME@ resolved to
// this checkout (what team-worker does), spoken to over stdio by a minimal MCP client.
//
//   const server = startToolkitServer("prod-read", { home, opDir, env, path });
//   await server.initialize();
//   const tools = await server.listTools();
//   const result = await server.callTool("find", { database, collection, filter });
//   await server.close();
//   server.stdout, server.stderr   everything the server printed, for leak checks
//   server.pid, server.exited      the server process, and a promise of { code, signal }
//   server.spied()                 the spied commands the server ran (see spyDir)
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
export const stubDir = dirname(fileURLToPath(import.meta.url));

// Every directory a test makes lives under one root per test file, removed when it exits.
const tempRoot = mkdtempSync(join(tmpdir(), "toolkit-test-"));
process.on("exit", () => rmSync(tempRoot, { recursive: true, force: true }));
export const tempDir = (prefix) => mkdtempSync(join(tempRoot, `${prefix}-`));

// The toolkit's server entry from its MCP config, as Claude Code would read it.
export function serverConfig(toolkit) {
  const text = readFileSync(join(repoRoot, "toolkits", toolkit, ".mcp.json"), "utf8");
  const config = JSON.parse(text.replaceAll("@TEAM_HOME@", repoRoot));
  return config.mcpServers[toolkit];
}

// A directory driving the op stub (helpers/op): its value, its mode, and the calls it logs.
export function opStub({ value, mode = "ok" }) {
  const dir = tempDir("op-stub");
  if (value !== undefined) writeFileSync(join(dir, "value"), value);
  writeFileSync(join(dir, "mode"), mode);
  return {
    dir,
    calls: () => {
      try {
        return readFileSync(join(dir, "calls"), "utf8").trim().split("\n").filter(Boolean);
      } catch {
        return [];
      }
    },
  };
}

// The test's PATH: node's directory and the system's, with the op stub first unless `withOp` is
// false. It refuses a PATH where a real op could be found, so no test ever reaches 1Password.
export function testPath({ withOp = true } = {}) {
  const dirs = [dirname(process.execPath), "/usr/bin", "/bin"];
  for (const dir of dirs) {
    try {
      accessSync(join(dir, "op"), constants.X_OK);
    } catch {
      continue;
    }
    throw new Error(`a real op is on the test PATH, in ${dir}`);
  }
  return (withOp ? [stubDir, ...dirs] : dirs).join(":");
}

// Spies first on PATH for the commands of the one child the pinned server is known to try,
// node-machine-id's device-id shell (`cat ... || hostname | head`): each logs its name to `runs`,
// then runs the real command. A child is too short-lived to catch in /proc; these are not.
function spyDir() {
  const dir = tempDir("spies");
  for (const name of ["cat", "head", "hostname"]) {
    writeFileSync(join(dir, name), `#!/bin/sh\necho ${name} >>'${dir}/runs'\nexec /usr/bin/${name} "$@"\n`, { mode: 0o755 });
  }
  return {
    dir,
    runs: () => (existsSync(join(dir, "runs")) ? readFileSync(join(dir, "runs"), "utf8").split("\n").filter(Boolean) : []),
  };
}

// Start the server with a small, explicit environment: HOME, PATH (the spies, then testPath()
// unless `path` replaces it), OP_STUB_DIR, plus `env`.
export function startToolkitServer(toolkit, { home, opDir, env = {}, path = testPath(), args = [] }) {
  const { command, args: configArgs = [], env: configEnv = {} } = serverConfig(toolkit);
  const spies = spyDir();
  const child = spawn(command, [...configArgs, ...args], {
    env: {
      HOME: home,
      PATH: `${spies.dir}:${path}`,
      OP_STUB_DIR: opDir,
      ...configEnv,
      ...env,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const connection = new McpConnection(child);
  connection.spied = spies.runs;
  return connection;
}

class McpConnection {
  constructor(child) {
    this.child = child;
    this.pid = child.pid;
    this.stdout = "";
    this.stderr = "";
    this.nextId = 1;
    this.pending = new Map();
    let buffer = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      this.stdout += chunk;
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) this.receive(JSON.parse(line));
      }
    });
    child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
    });
    child.stdin.on("error", () => {});
    this.exited = new Promise((resolve) => {
      child.on("exit", (code, signal) => {
        for (const { reject } of this.pending.values()) {
          reject(new Error(`server exited (${code ?? signal}) before answering; stderr: ${this.stderr}`));
        }
        this.pending.clear();
        resolve({ code, signal });
      });
    });
  }

  receive(message) {
    if (message.id === undefined || !this.pending.has(message.id)) {
      // A request or notification from the server; elicitation would arrive here.
      (this.fromServer ??= []).push(message);
      return;
    }
    const { resolve, reject } = this.pending.get(message.id);
    this.pending.delete(message.id);
    if (message.error) reject(Object.assign(new Error(message.error.message), { rpc: message.error }));
    else resolve(message.result);
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  }

  request(method, params = {}, timeoutMs = 30_000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out; stderr: ${this.stderr}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => (clearTimeout(timer), resolve(value)),
        reject: (error) => (clearTimeout(timer), reject(error)),
      });
      this.send({ id, method, params });
    });
  }

  async initialize() {
    const result = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "toolkit-test", version: "1.0.0" },
    });
    this.send({ method: "notifications/initialized" });
    return result;
  }

  async listTools() {
    const tools = [];
    let cursor;
    do {
      const page = await this.request("tools/list", cursor ? { cursor } : {});
      tools.push(...page.tools);
      cursor = page.nextCursor;
    } while (cursor);
    return tools;
  }

  // A tool's result, with its text joined as `text`; isError is the tool's own refusal.
  async callTool(name, args) {
    const result = await this.request("tools/call", { name, arguments: args });
    const text = (result.content ?? []).map((part) => part.text ?? "").join("\n");
    return { ...result, text };
  }

  async close() {
    if (this.child.exitCode === null && this.child.signalCode === null) {
      this.child.stdin.end();
      const timer = setTimeout(() => this.child.kill("SIGKILL"), 5_000);
      await this.exited;
      clearTimeout(timer);
    }
    return this.exited;
  }
}
