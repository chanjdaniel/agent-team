// @hono/node-server as servers/ installs it for its two parents: @modelcontextprotocol/sdk (the
// top-level dependency) and @modelcontextprotocol/node (under mongodb-mcp-server's HTTP runners,
// which its CLI imports on every start, stdio included). Each must resolve 2.1.3 or later
// (tests/repo.bats holds the lock to it), and each parent's Streamable HTTP server transport,
// whose constructor builds its Node request listener with @hono/node-server's getRequestListener,
// must still load and construct on it. No server is started and nothing listens.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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

const modules = join(repoRoot, "servers/node_modules");
const sdk = resolvePackage("@modelcontextprotocol/sdk", pathToFileURL(join(repoRoot, "servers/package.json")));
const node = resolvePackage("@modelcontextprotocol/node", pathToFileURL(join(modules, "@mongodb-js/mcp-http-runners/dist/legacyMcpHttpHandler.js")));
const sdkEntry = join(sdk.dir, "dist/esm/server/streamableHttp.js");
const nodeEntry = join(node.dir, node.pkg.exports["."].import.default);

const atLeast = (version, floor) => {
  const [a, b] = [version, floor].map((v) => v.split(".").map(Number));
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return true;
};

test("@modelcontextprotocol/sdk and @modelcontextprotocol/node resolve @hono/node-server 2.1.3 or later", () => {
  for (const [parent, entry] of [["sdk", sdkEntry], ["node", nodeEntry]]) {
    const { version } = resolvePackage("@hono/node-server", pathToFileURL(entry)).pkg;
    assert.ok(atLeast(version, "2.1.3"), `${parent}: @hono/node-server ${version}`);
  }
});

test("@modelcontextprotocol/sdk's Streamable HTTP server transport builds its request listener", async () => {
  const { StreamableHTTPServerTransport } = await import(pathToFileURL(sdkEntry).href);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  assert.equal(typeof transport._requestListener, "function");
});

test("@modelcontextprotocol/node's Streamable HTTP server transport builds its request listener", async () => {
  const { NodeStreamableHTTPServerTransport } = await import(pathToFileURL(nodeEntry).href);
  const transport = new NodeStreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  assert.equal(typeof transport._requestListener, "function");
});
