// @hono/node-server as servers/ installs it for its two parents: @modelcontextprotocol/sdk (the
// top-level dependency) and @modelcontextprotocol/node (under mongodb-mcp-server's HTTP runners,
// which its CLI imports on every start, stdio included). Each must resolve 2.1.3 or later
// (tests/repo.bats holds the lock to it), and each parent's Streamable HTTP server transport,
// which turns Node's request into a web one and back with @hono/node-server's getRequestListener,
// must still answer an MCP initialize request on it: the test serves the transport's handler on
// the loopback, POSTs a JSON-RPC initialize and reads the server's result.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { findPackageJSON } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

// A package's directory and package.json as an importer at `from` (a file URL) resolves it.
const resolvePackage = (name, from) => {
  const file = findPackageJSON(name, from);
  return { dir: dirname(file), pkg: JSON.parse(readFileSync(file, "utf8")) };
};
const esmEntry = ({ dir, pkg }) => join(dir, pkg.exports["."].import.default);

const modules = join(repoRoot, "servers/node_modules");
const fromRunners = pathToFileURL(join(modules, "@mongodb-js/mcp-http-runners/dist/legacyMcpHttpHandler.js"));
const sdk = resolvePackage("@modelcontextprotocol/sdk", pathToFileURL(join(repoRoot, "servers/package.json")));
const sdkTransportEntry = join(sdk.dir, "dist/esm/server/streamableHttp.js");
const sdkServerEntry = join(sdk.dir, "dist/esm/server/mcp.js");
const nodeEntry = esmEntry(resolvePackage("@modelcontextprotocol/node", fromRunners));
const serverEntry = esmEntry(resolvePackage("@modelcontextprotocol/server", fromRunners));

const atLeast = (version, floor) => {
  const [a, b] = [version, floor].map((v) => v.split(".").map(Number));
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return true;
};

const protocolVersion = "2025-06-18";

// Serves `transport` (connected to an McpServer named `name`) on the loopback, POSTs an MCP
// initialize to it and returns the HTTP status and the JSON-RPC message it answered with, read
// from the body as JSON or from its first server-sent event.
const initializeOver = async (t, { McpServer, transport, name }) => {
  const mcp = new McpServer({ name, version: "1.0.0" });
  await mcp.connect(transport);
  const http = createServer((req, res) => {
    transport.handleRequest(req, res).catch((error) => {
      res.statusCode = 500;
      res.end(String(error));
    });
  });
  await new Promise((resolve) => http.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    http.closeAllConnections();
    await new Promise((resolve) => http.close(resolve));
    await mcp.close();
  });

  const response = await fetch(`http://127.0.0.1:${http.address().port}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion, capabilities: {}, clientInfo: { name: "servers-hono-test", version: "1.0.0" } },
    }),
  });
  const type = response.headers.get("content-type") ?? "";
  if (!type.startsWith("text/event-stream")) return { status: response.status, type, message: await response.json() };
  // The stream may stay open after its one event, so read only up to the end of the first one.
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let text = "";
  while (!/\n\n/.test(text)) {
    const { value, done } = await reader.read();
    if (done) break;
    text += value;
  }
  await reader.cancel();
  const data = text.split("\n\n")[0].split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5)).join("\n");
  return { status: response.status, type, message: JSON.parse(data) };
};

const assertInitialized = ({ status, type, message }, name) => {
  assert.equal(status, 200, `${type}: ${JSON.stringify(message)}`);
  assert.equal(message.jsonrpc, "2.0");
  assert.equal(message.id, 1);
  assert.equal(message.error, undefined);
  assert.equal(message.result.protocolVersion, protocolVersion);
  assert.deepEqual(message.result.serverInfo, { name, version: "1.0.0" });
};

test("@modelcontextprotocol/sdk and @modelcontextprotocol/node resolve @hono/node-server 2.1.3 or later", () => {
  for (const [parent, entry] of [["sdk", sdkTransportEntry], ["node", nodeEntry]]) {
    const { version } = resolvePackage("@hono/node-server", pathToFileURL(entry)).pkg;
    assert.ok(atLeast(version, "2.1.3"), `${parent}: @hono/node-server ${version}`);
  }
});

test("@modelcontextprotocol/sdk's Streamable HTTP server transport answers an initialize request", async (t) => {
  const { StreamableHTTPServerTransport } = await import(pathToFileURL(sdkTransportEntry).href);
  const { McpServer } = await import(pathToFileURL(sdkServerEntry).href);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  assertInitialized(await initializeOver(t, { McpServer, transport, name: "sdk-test" }), "sdk-test");
});

test("@modelcontextprotocol/node's Streamable HTTP server transport answers an initialize request", async (t) => {
  const { NodeStreamableHTTPServerTransport } = await import(pathToFileURL(nodeEntry).href);
  const { McpServer } = await import(pathToFileURL(serverEntry).href);
  const transport = new NodeStreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  assertInitialized(await initializeOver(t, { McpServer, transport, name: "node-test" }), "node-test");
});
