# browser

The `chrome-devtools-axi` banner for a worker whose task drives a browser, and the `ui-check` skill, which decides whether a UI change needs a look, then captures the screens it touches and their siblings and judges them against the project's design document.
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
The builder and reviewer roles name `ui-check` for a session that lists it, so a session with the toolkit runs it and one without reads the line and does nothing: a ticket builder spot-checks its ticket's states, the builder who delivers runs it on the whole change and puts a "UI check" section in the PR body, a fix round rechecks what the fix touched and its siblings, and the reviewer runs it on the head under review and writes each finding into `review.md` with its tile.

## What loads

- The hook `hooks/hooks.json`: at session start, `bin/hooks/axi-banner chrome-devtools-axi`, reached from the toolkit as `${CLAUDE_PLUGIN_ROOT}/../../bin/hooks/axi-banner`, since `--plugin-dir` loads the toolkit in place in the code checkout.
  It prints the banner once: nothing while the user settings still print it in every session, and the banner once Daniel's guard makes those print it only outside the team (`bin/hooks/axi-banner`'s header).
- The skill `skills/ui-check/SKILL.md`: its description in the session's starting context, its body only when the session invokes it.
  It first decides from the diff whether the change needs a look: none (no file that renders changed), a spot check (one tile per touched state, no siblings, for a change inside one component's box), or walk and judge (the touched states and their direct siblings, found by searching the source for the changed names).
  It captures each state with the project's scripted walk when the project's `CLAUDE.md` or `AGENTS.md` names one, and otherwise with `chrome-devtools-axi` in the session's own axi session, using commands that print a line rather than an accessibility snapshot: viewport tiles at the design width (1440x900 when the design document gives none), a sibling's at 0.75 scale and a phone's at scale 1, never a full-page capture, within a cap of 16,000 image tokens per run, the states left out named as not judged.
  It judges every tile against a rubric drawn from the project's design document, and writes `findings.md` beside its tiles in `.scratch/task/ui-check/<role>-<short head>/`, with the run's image tokens; a task's archive keeps `findings.md` and leaves out the tiles and the Lighthouse reports (`archive_left_out` in `bin/lib/team.sh`).
  Before any image it runs the cheaper text checks: the phone probe (horizontal overflow and small targets as numbers), `console`, and Lighthouse's accessibility audit in snapshot mode with only the failing audits read through `jq`; a throttled trace with its LCP breakdown runs only when the change can affect page load, and `stop` ends the session's browser.
  Its Lighthouse filtering and LCP-breakdown steps are adapted from chrome-devtools-mcp 1.12.0's `a11y-debugging` and `debug-optimize-lcp` skills (Apache-2.0).
- No MCP server (no `.mcp.json`).

## What a run costs

Estimates from the skill's budget table and the trial's output sizes; each run records its own image tokens in its `findings.md`.

| Change | Tiles | Image tokens | Run total |
| - | - | - | - |
| No file that renders | 0 | 0 | 0 (the skill is not invoked; the session writes one line) |
| Spot check, one desktop state | 1 | 2.7k | about 5k |
| Typical walk: 2 touched states and 2 siblings on desktop, plus one phone state with 2 tiles | 6 | 9.3k | about 16k |
| At the cap | up to the cap | 16k | about 23k |

The run total adds the skill's body (about 2k tokens), the design document's sections the rubric reads (about 2k), axi's one-line outputs and the one sign-in snapshot (about 2k), Lighthouse's failing audits (about 0.5k per touched state) and about 150 written tokens per verdict.
A typical UI change runs it twice, for the builder who delivers and for the reviewer, so about 32k tokens; a ticket builder's spot check and a rereview's partial run add about 5k each.

## Tests

`tests/toolkits/browser.test.mjs` checks the plugin's layout (its manifest, its one hook, no `.mcp.json` and one skill, `ui-check`, the only skill of that name in any toolkit or the coordinator's plugin) and runs the hook's command as Claude Code would, with `CLAUDE_PLUGIN_ROOT` set and a stub `chrome-devtools-axi`, under user settings that still print the banner and under the guarded ones.
It holds the skill's description under 250 characters and its file under 8 kB, and runs every `chrome-devtools-axi` command and flag the skill names, its evals and its `jq` filter as written, on the client `servers/` pins (`servers/node_modules/.bin/chrome-devtools-axi`), in a named session of its own and a temporary HOME, headless on the machine's Chrome, against a fixture site served on localhost: it fails when the skill names a command or flag it has not run.
It checks what they produce: each viewport's tile size, an element tile, the phone probe's counts, the fixture's accessibility fault among the failing audits, the trace's LCP breakdown, `console` and `stop`; and that each token figure in the skill's budget table is `ceil(w/28) x ceil(h/28)` of the image beside it.
`tests/axi-banner.bats` tests the hook itself, and `tests/team-worker.bats` that `--toolkit browser` adds the plugin directory and no MCP server, and that a launched builder's and reviewer's settings name their session `T<n>-<role>`.
`tests/repo.bats` holds the worker settings' session name to `@TASK@-@ROLE@` and the coordinator's settings to none, the `chrome-devtools-axi` that `servers/` pins to the version `bin/lib/tools.lock` pins, and the builder and reviewer roles to naming `ui-check` and where its record goes.
