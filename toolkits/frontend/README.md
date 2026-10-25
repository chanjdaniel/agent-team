# frontend

Front-end fixes on the element Daniel points at: Daniel right-clicks it in the Agent Chrome and picks Inspect, and the agent gets its page, HTML, matched CSS, Vue source file and line, and screenshots.
For Daniel's own Claude Code session, and for the coordinator's intake of a fix sent from Discord; build workers read the coordinator's capture, never the Agent Chrome.

## Use it

At the laptop, in Conventioner's checkout:

1. Start the dev server as usual, then the Agent Chrome once per login: `~/agent-team/toolkits/frontend/scripts/agent-chrome` (or `agent-chrome http://localhost:<port>/<path>` for another page), and log in there with a fixture account.
2. Start the session with the toolkit: `claude --plugin-dir ~/agent-team/toolkits/frontend`.
3. For each fix: right-click the element in the Agent Chrome, pick Inspect, and type the fix, for example "the selected element: give it the same height as Import responses".
   The skill captures the element, opens its `.vue` file at the line and makes the change; the dev server reloads it in the Agent Chrome.

## What it can see

- The Agent Chrome only: a Chrome window with its own profile (`~/.local/share/agent-team/agent-chrome`), started by `scripts/agent-chrome` with remote debugging on `127.0.0.1:9222`.
  Daniel's everyday Chrome, with its mail and any production tab, is a different browser that nothing here attaches to.
- Its `http://localhost:*` and `http://127.0.0.1:*` pages only: the server runs with an allowlist of those two and DevTools' own frontend (`devtools://devtools/*`, where the Elements panel's selection is read), so any other tab is neither listed nor read, and a navigation elsewhere is refused.
- Use it for the local dev site with fixture data, logged in with a fixture account.
  Never open production or real applicant data there: anything a capture holds can end up in a Discord thread or a task directory, and remote debugging on port 9222 lets any local process drive that window.
- Google's usage statistics, CrUX lookups and the server's update checks are off.
- The Agent Chrome runs with the mock keychain and the basic password store, so it never reads or adds a "Chrome Safe Storage" item in Daniel's login keychain, and no keychain prompt appears for a Chrome a test starts.
- A capture stays on the machine that took it: Daniel's session writes it to `.scratch/ui` in its checkout (git-ignored, and outside a task's `.scratch/task/`, which archives carry; an archive leaves out a `ui/` there anyway), and the coordinator's intake (`team-ui`) to the team home's `tasks/T<n>/ui/`, which the team home's git ignores, so no checkpoint or handoff carries it; `team-close` removes it with the task, and `team-doctor`'s `captures` line reports one left behind.

## What it runs

- `scripts/agent-chrome [--port <port>] [<url>]`: starts the Agent Chrome at the dev server (default `http://localhost:5173`), or says one already answers on the port.
- `scripts/ui-capture [--browser-url <url>] <out-dir>`: finds the element selected in DevTools' Elements panel on a localhost page of the Agent Chrome and writes `<out-dir>/ui-pick.md` (page, route, snapshot line, the `vite-plugin-vue-inspector` source chain such as `src/views/LoginView.vue:369:11`, the component chain, its HTML and every matched CSS rule) with `element.png` and `page.png`.
  It fails in one line, exit 1, when no Agent Chrome answers, no localhost page has DevTools open, nothing is selected, or the page carries no Vue source data (a production build).
  Each script's header is its `--help`.
- The MCP server `frontend` (`.mcp.json`): the same pinned server with the same flags, so the agent can look again after a capture (`take_snapshot`, `take_screenshot`, `get_css_styles` and the rest of Chrome DevTools MCP's tools).
  Its path uses `${CLAUDE_PLUGIN_ROOT}`, which Claude Code fills in for `--plugin-dir` and not under `team-worker`'s `--mcp-config`: the toolkit is not for `team-worker --toolkit`, since workers read captures and never attach to Daniel's window.
- The skill `fixing-the-selected-element` (`skills/`): when Daniel's message is about the selected element, capture it, read the capture, fix the `.vue` file it names and capture again to check.
- All of them speak to the pinned `chrome-devtools-mcp` in `servers/` (installed by `servers/install`, checked by `team-doctor`'s `servers` line).

## Tests

`tests/run toolkits` runs `tests/toolkits/frontend.test.mjs`: a headless Chrome stands in for the Agent Chrome, a local fixture page shaped like Conventioner's dev build stands in for the app, and the test opens DevTools and selects an element in the Elements panel exactly as a click there does (`tests/toolkits/helpers/chrome.mjs`).
It checks each capture and each refusal, that a page off localhost is never read, that the MCP server `.mcp.json` declares lists localhost pages only and sees the selection, and that `agent-chrome` starts Chrome with its own profile and port.

`evals/` holds the skill's eval cases (`claude plugin eval ~/agent-team/toolkits/frontend`): it fires on a fix about the selected element and leaves a general front-end question alone.
Every `frontend` call there is answered by an agent mock of a Conventioner page (`evals/mocks/frontend/_server.md`), whose `_tools.json` is the server's own `tools/list`, which the toolkit test keeps in step.
Results go to `evals/results/`, which is gitignored.
