# browser

The `chrome-devtools-axi` banner for a worker whose task drives a browser.
`chrome-devtools-axi` is already on the machine (`bin/lib/tools.lock`), with the pinned `chrome-devtools-mcp` in `servers/` behind it (`CHROME_DEVTOOLS_AXI_MCP_PATH` in the worker settings); the banner is what tells a session it is there and how to start.

## Each worker's own session

Every worker's `chrome-devtools-axi` commands run in an axi session named for its task and role, such as `T71-builder` (`CHROME_DEVTOOLS_AXI_SESSION` in the worker settings, which `team-worker` fills in), with no prefix on each command.
Each session has a bridge and a Chrome of its own, so two UI workers on one machine never share a browser.
The bridge outlives the commands that start it: `chrome-devtools-axi stop` ends the session's bridge and its Chrome, which a worker runs once it is done with the browser.
The coordinator's settings name no session, so its own commands run in axi's default one.

## When the coordinator gives it

To the builder and the reviewer of a task that changes a UI, who open the page to check the change, as Daniel's rule on pixel perfection asks: `team-worker T<n> builder <worktree> --toolkit browser -- ...`, and the same for the reviewer.
A project whose tasks mostly change a UI lists it in its `toolkits` in `projects.toml` (Conventioner does), so a worker that asks with `NEED toolkit browser` is relaunched with it at once.
A planner, a task with no UI, and ops never get it.

## What loads

- The hook `hooks/hooks.json`: at session start, `bin/hooks/axi-banner chrome-devtools-axi`, reached from the toolkit as `${CLAUDE_PLUGIN_ROOT}/../../bin/hooks/axi-banner`, since `--plugin-dir` loads the toolkit in place in the code checkout.
  It prints the banner once: nothing while the user settings still print it in every session, and the banner once Daniel's guard makes those print it only outside the team (`bin/hooks/axi-banner`'s header).
- No MCP server (no `.mcp.json`) and no skill.

## Tests

`tests/toolkits/browser.test.mjs` checks the plugin's layout (its manifest, its one hook, no `.mcp.json` and no skills) and runs the hook's command as Claude Code would, with `CLAUDE_PLUGIN_ROOT` set and a stub `chrome-devtools-axi`, under user settings that still print the banner and under the guarded ones.
`tests/axi-banner.bats` tests the hook itself, and `tests/team-worker.bats` that `--toolkit browser` adds the plugin directory and no MCP server, and that a launched builder's and reviewer's settings name their session `T<n>-<role>`.
`tests/repo.bats` holds the worker settings' session name to `@TASK@-@ROLE@` and the coordinator's settings to none.
