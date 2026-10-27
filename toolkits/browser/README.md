# browser

The `chrome-devtools-axi` banner for a worker whose task drives a browser, and the `ui-check` skill, which captures and checks the screens a UI change touches.
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
- The skill `skills/ui-check/SKILL.md`: its description in the session's starting context, its body only when the session invokes it.
  It captures each state with `chrome-devtools-axi` in the session's own axi session, using commands that print a line rather than an accessibility snapshot: viewport tiles at the design width, a sibling's at 0.75 scale and a phone's at scale 1, never a full-page capture.
  Before any image it runs the cheaper text checks: the phone probe (horizontal overflow and small targets as numbers), `console`, and Lighthouse's accessibility audit in snapshot mode with only the failing audits read through `jq`; a throttled trace with its LCP breakdown runs only when the change can affect page load, and `stop` ends the session's browser.
  Its Lighthouse filtering and LCP-breakdown steps are adapted from chrome-devtools-mcp 1.12.0's `a11y-debugging` and `debug-optimize-lcp` skills (Apache-2.0).
- No MCP server (no `.mcp.json`).

## Tests

`tests/toolkits/browser.test.mjs` checks the plugin's layout (its manifest, its one hook, no `.mcp.json` and one skill, `ui-check`, the only skill of that name in any toolkit or the coordinator's plugin) and runs the hook's command as Claude Code would, with `CLAUDE_PLUGIN_ROOT` set and a stub `chrome-devtools-axi`, under user settings that still print the banner and under the guarded ones.
It holds the skill's description under 250 characters and its file under 8 kB, and runs every `chrome-devtools-axi` command and flag the skill names, its evals and its `jq` filter as written, on the client `servers/` pins (`servers/node_modules/.bin/chrome-devtools-axi`), in a named session of its own and a temporary HOME, headless on the machine's Chrome, against a fixture site served on localhost: it fails when the skill names a command or flag it has not run.
It checks what they produce: the three viewports' tile sizes, an element tile, the phone probe's counts, the fixture's accessibility fault among the failing audits, the trace's LCP breakdown, `console` and `stop`.
`tests/axi-banner.bats` tests the hook itself, and `tests/team-worker.bats` that `--toolkit browser` adds the plugin directory and no MCP server, and that a launched builder's and reviewer's settings name their session `T<n>-<role>`.
`tests/repo.bats` holds the worker settings' session name to `@TASK@-@ROLE@` and the coordinator's settings to none, and the `chrome-devtools-axi` that `servers/` pins to the version `bin/lib/tools.lock` pins.
