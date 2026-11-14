// Checks every toolkit server test makes, whichever toolkit it starts.
//
//   assertNoLeak(server, { marker, home })     after every run: the secret never got out
//   launcherRefusalTests(toolkit, context, { reads, notTheSecret, path })
//                                              inside a describe(): one test per launcher refusal;
//                                              context() gives { value, home, marker } at run time;
//                                              `reads`, the op reads a launch makes (1),
//                                              `notTheSecret`, { what, reason } of the value that
//                                              is not the toolkit's secret (a MongoDB connection
//                                              string's by default), and `path`, the server's
//                                              PATH given testPath's options (testPath itself by
//                                              default), for a server that needs a tool on it
//   evalMockTools(toolkit, server)             the tools/list a toolkit's eval mocks give the server
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { opStub, repoRoot, startToolkitServer, testPath } from "./mcp.mjs";

// The marker (the test user's password) is never printed, the server wrote nothing under
// HOME/.mongodb/ and it ran no child process.
export function assertNoLeak(server, { marker, home }) {
  assert.ok(!server.stdout.includes(marker), "the password marker is on stdout");
  assert.ok(!server.stderr.includes(marker), "the password marker is on stderr");
  assert.ok(!existsSync(join(home, ".mongodb")), "the server wrote under HOME/.mongodb/");
  assert.deepEqual(server.spied(), [], "the server started a child process");
}

// Each case exits 1 before the server starts, with nothing on stdout and one line on stderr.
// `calls`: the op commands the case runs; every value read is signed out, even a bad one, and the
// first read that fails ends the reads.
const notAConnectionString = { what: "when the value is not a connection string", reason: /is not a MongoDB connection string$/ };

export function launcherRefusalTests(toolkit, context, { reads = 1, notTheSecret = notAConnectionString, path: serverPath = testPath } = {}) {
  const read = Array(reads).fill("read");
  const cases = [
    { what: "when op is not on PATH", path: () => serverPath({ withOp: false }), calls: [], reason: /^op is not on PATH$/ },
    { what: "when op read fails", mode: "fail", calls: ["read"], reason: /^op read failed: .*authorization prompt dismissed/ },
    { what: "when op read returns nothing", value: () => "", calls: [...read, "signout"], reason: /^op read returned an empty value$/ },
    { what: notTheSecret.what, value: ({ marker }) => `${marker}\n`, calls: [...read, "signout"], reason: notTheSecret.reason },
    { what: "when op signout fails", mode: "signout-fail", calls: [...read, "signout"], reason: /^op signout failed: / },
    { what: "when given an argument", args: ["--readOnly=false"], calls: [], reason: /^takes no arguments$/ },
  ];
  for (const { what, path, mode, value, args, calls, reason } of cases) {
    test(what, async () => {
      const run = context();
      const op = opStub({ value: value ? value(run) : run.value, mode });
      const server = startToolkitServer(toolkit, { home: run.home, opDir: op.dir, path: path ? path() : serverPath(), args });
      try {
        await assert.rejects(server.initialize(), /server exited \(1\)/);
      } finally {
        await server.close();
      }
      assert.equal((await server.exited).code, 1);
      assert.equal(server.stdout, "");
      const lines = server.stderr.split("\n").filter(Boolean);
      assert.equal(lines.length, 1, server.stderr);
      assert.ok(lines[0].startsWith(`${toolkit}: `), lines[0]);
      assert.match(lines[0].slice(toolkit.length + 2), reason);
      assert.deepEqual(op.calls().map((call) => call.split(" ")[0]), calls);
      assertNoLeak(server, run);
    });
  }
}

// The skills' evals answer from mocks, never the real server; their saved tools/list
// (evals/mocks/<server>/_tools.json) gives the mocked tools the real names, descriptions and
// schemas, so it must stay the server's own.
export function evalMockTools(toolkit, server) {
  const path = join(repoRoot, "toolkits", toolkit, "evals", "mocks", server, "_tools.json");
  return JSON.parse(readFileSync(path, "utf8")).tools;
}
