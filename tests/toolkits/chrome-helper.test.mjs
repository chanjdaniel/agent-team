// The tests' stand-in Chrome (helpers/chrome.mjs) on a Chrome too old for open_devtools, which
// inspect drives: startChrome fails at once, naming the Chrome and what it lacks, where each
// inspect would otherwise only time out after 180 s.
import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { startChrome } from "./helpers/chrome.mjs";
import { stubDir } from "./helpers/mcp.mjs";

test("a Chrome without open_devtools' protocol methods fails at once, naming itself and what it lacks", async () => {
  process.env.TEAM_CHROME = join(stubDir, "old-chrome");
  const start = Date.now();
  await assert.rejects(startChrome(["data:text/html,<title>Page</title>"]), {
    message:
      "Chrome/138.0.7204.183 has no Target.openDevTools or Target.getDevToolsTarget, which open_devtools needs: " +
      "update Chrome, or set TEAM_CHROME to a current one",
  });
  assert.ok(Date.now() - start < 20_000, "it fails before any wait for the tabs");
});
