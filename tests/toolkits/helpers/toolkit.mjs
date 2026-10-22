// Checks every toolkit server test makes, whichever toolkit it starts.
//
//   assertNoLeak(server, { marker, home })     after every run: the secret never got out
//   launcherRefusalTests(toolkit, context)     inside a describe(): one test per launcher refusal;
//                                              context() gives { value, home, marker } at run time
//   children(pid)                              the pids of a process's children
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { opStub, startToolkitServer, testPath } from "./mcp.mjs";

// The marker (the test user's password) is never printed, the server wrote nothing under
// HOME/.mongodb/ and it ran no child process.
export function assertNoLeak(server, { marker, home }) {
  assert.ok(!server.stdout.includes(marker), "the password marker is on stdout");
  assert.ok(!server.stderr.includes(marker), "the password marker is on stderr");
  assert.ok(!existsSync(join(home, ".mongodb")), "the server wrote under HOME/.mongodb/");
  assert.deepEqual(server.spied(), [], "the server started a child process");
}

// Each case exits 1 before the server starts, with nothing on stdout and one line on stderr.
// `calls`: the op commands the case runs; a value read is always signed out, even a bad one.
export function launcherRefusalTests(toolkit, context) {
  const cases = [
    { what: "when op is not on PATH", path: () => testPath({ withOp: false }), calls: [], reason: /^op is not on PATH$/ },
    { what: "when op read fails", mode: "fail", calls: ["read"], reason: /^op read failed: .*authorization prompt dismissed/ },
    { what: "when op read returns nothing", value: () => "", calls: ["read", "signout"], reason: /^op read returned an empty value$/ },
    { what: "when the value is not a connection string", value: ({ marker }) => `${marker}\n`, calls: ["read", "signout"], reason: /is not a MongoDB connection string$/ },
    { what: "when op signout fails", mode: "signout-fail", calls: ["read", "signout"], reason: /^op signout failed: / },
    { what: "when given an argument", args: ["--readOnly=false"], calls: [], reason: /^takes no arguments$/ },
  ];
  for (const { what, path, mode, value, args, calls, reason } of cases) {
    test(what, async () => {
      const run = context();
      const op = opStub({ value: value ? value(run) : run.value, mode });
      const server = startToolkitServer(toolkit, { home: run.home, opDir: op.dir, path: path?.(), args });
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

// The pids of a process's children, across all its threads.
export function children(pid) {
  return readdirSync(`/proc/${pid}/task`).flatMap((task) =>
    readFileSync(`/proc/${pid}/task/${task}/children`, "utf8").split(" ").filter(Boolean));
}
