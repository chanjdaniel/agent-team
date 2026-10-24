// The throwaway MongoDB's own wait (helpers/mongo.mjs): a start that never comes ready fails with
// how long it waited and what the container last logged, so a slow Docker reads apart from a
// broken one.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { after, before, test } from "node:test";
import { connectWhenReady, mongoImage } from "./helpers/mongo.mjs";

const docker = (...args) => execFileSync("docker", args, { encoding: "utf8" }).trim();
const name = `toolkit-test-${randomBytes(4).toString("hex")}`;

// The image's entrypoint runs any command that is not mongod as given: this one only logs.
before(() => {
  docker(
    "run", "--detach", "--rm", "--name", name, "--label", "agent-team-test=toolkits",
    mongoImage, "sh", "-c", "echo still starting up; sleep 120",
  );
});

after(() => {
  docker("rm", "--force", name);
});

test("past its deadline, the wait names the time it waited and the container's last log lines", async () => {
  await assert.rejects(
    // Nothing listens on port 1, as nothing answers while mongod has not started.
    connectWhenReady("mongodb://root:x@127.0.0.1:1/?authSource=admin", name, 2_000),
    (error) => {
      assert.match(error.message, /^MongoDB in container toolkit-test-[0-9a-f]{8} was not ready after \d+ s:/);
      assert.match(error.message, /docker logs --tail 20 toolkit-test-[0-9a-f]{8}:\n.*still starting up/s);
      return true;
    },
  );
});
