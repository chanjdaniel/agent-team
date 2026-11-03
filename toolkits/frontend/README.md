# frontend

Front-end fixes on the element Daniel points at: Daniel right-clicks it in the Agent Chrome and picks Inspect, and the agent gets its HTML, matched CSS, Vue source file and line, and screenshot, with a capture of the page it is on.
For Daniel's own Claude Code session, and for the coordinator's intake of a fix sent from Discord; workers read the coordinator's capture, never the Agent Chrome, and `team-worker` refuses them the toolkit.

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
- A capture stays on the machine that took it: Daniel's session writes it to `.scratch/ui` in its checkout (git-ignored, and outside a task's `.scratch/task/`, which archives carry; an archive leaves out a `ui/` there anyway, and every image anywhere in it), and the coordinator's intake (`team-ui`) to the team home's `tasks/T<n>/ui/`, which the team home's git ignores, so no checkpoint or handoff carries it; `team-close` removes it with the task, and `team-doctor`'s `captures` line reports one left behind.

## What it runs

- `scripts/agent-chrome [--port <port>] [<url>]`: starts the Agent Chrome at the dev server (default `http://localhost:5173`), or says one already answers on the port.
- `scripts/ui-capture [--browser-url <url>] <out-dir>`: writes a page capture of the localhost page of the Agent Chrome that Daniel is on, and an element capture too when an element is selected in DevTools' Elements panel there.
  The page capture is `<out-dir>/ui-page.md` (the page's URL, route and title, why that page was taken, the other localhost tabs, the Vue route's matched records with their components and files, or "(no Vue router found)", and the page's console problems and failed requests since it last loaded), `page.png` (the viewport) and `page-snapshot.txt` (the page's accessibility snapshot).
  The element capture adds `ui-pick.md` (page, route, a pointer to `ui-page.md` for the page's state, snapshot line, the `vite-plugin-vue-inspector` source chain such as `src/views/LoginView.vue:369:11`, the component chain, its HTML and every matched CSS rule) and `element.png`, and `ui-page.md` lists them under its files.
  With nothing selected, it writes the page capture alone and exits 0.
  The page is, the first that applies: the localhost page with an element selected, "the selected element's page"; else a localhost page with DevTools open and nothing selected (DevTools' default `<body>`, or `<html>`); else the visible localhost tab, among several windows the one whose document has focus, else the most recently active; else, when no localhost tab is visible, the most recently active localhost tab.
  A capture of a tab that is not visible has no `page.png`, and its `ui-page.md` says so: Chrome paints no hidden tab, so a screenshot of one never comes, and bringing the tab to the front would change what Daniel sees.
  Recency is the order of Chrome's `/json/list`, most recently active first.
  Visibility and focus are read before the server selects any page, over one short DevTools protocol session per localhost tab that evaluates `document.visibilityState` and `document.hasFocus()` and nothing else: the pinned server (1.12.0) turns on focus emulation for each page it selects, under which every page reads visible and focused, so its `evaluate_script` cannot tell (checked on Chrome 156, 2026-11-03).
  The console problems are the console's errors, warnings and failed asserts, uncaught exceptions, unhandled rejections and the browser's own errors and warnings; the failed requests are those that ended in a status of 400 or more or a network error; each section lists them in order, the last 50, one line each trimmed to 500 characters inside a fence longer than any backtick run in them.
  They include what happened before `ui-capture` started, which the server cannot give: it is started anew for each capture, and its `list_console_messages` and `list_network_requests` report nothing from before it attached (checked on the pinned 1.12.0, 2026-11-03).
  So `ui-capture` opens one more short DevTools protocol session of its own, on the chosen localhost page alone, whose `Runtime.enable` and `Log.enable` replay every stored console call, exception and browser log entry since the page's last load before they answer, then sends `Runtime.disable` and `Log.disable` and closes.
  It cannot see a request still pending or any request's method, a reload starts the history anew, and with no session or no answer in 10 s the capture is still written, its two sections saying the history could not be read and why.
  Those two short sessions, the visibility read and this one, are the only times it speaks the protocol to a page without the server, and neither changes the page.
  No tab off localhost is ever attached to, by the server or by either read.
  While another session's `frontend` server (Daniel's own, say) has a page selected, that page too reads visible.
  It owns those five file names in `<out-dir>`: a capture removes the ones it did not write, so no file of an earlier capture is left beside it, and a failed capture writes and removes nothing.
  It fails in one line, exit 1, when no Agent Chrome answers, the Agent Chrome has no localhost page open, the selected element carries no Vue source data (a production build), the server never attached to a tab Chrome has open, or a page does not answer within 30 s; the last two name a busy machine as a cause.
  Each script's header is its `--help`.
- The MCP server `frontend` (`.mcp.json`): the same pinned server with the same flags, so the agent can look again after a capture (`take_snapshot`, `take_screenshot`, `get_css_styles` and the rest of Chrome DevTools MCP's tools).
  Its path uses `${CLAUDE_PLUGIN_ROOT}`, which Claude Code fills in for `--plugin-dir` and not under `team-worker`'s `--mcp-config`.
  The toolkit is not for workers: every session with it shares Daniel's one Agent Chrome window, so `team-worker --toolkit frontend` is refused as a usage error, for every role and for the load check, and workers read captures instead.
- The skill `fixing-the-selected-element` (`skills/`): when Daniel's message is about the selected element, capture it, read the capture, fix the `.vue` file it names and capture again to check.
- All of them speak to the pinned `chrome-devtools-mcp` in `servers/` (installed by `servers/install`, checked by `team-doctor`'s `servers` line).

## Tests

`tests/run toolkits` runs `tests/toolkits/frontend.test.mjs`: a headless Chrome stands in for the Agent Chrome, a local fixture page shaped like Conventioner's dev build stands in for the app, and the test opens DevTools and selects an element in the Elements panel exactly as a click there does (`tests/toolkits/helpers/chrome.mjs`).
That Chrome runs off the record, so no page waits for a fresh profile's cookie database, and a Chrome too old for `open_devtools` fails the test at once.
It checks each capture (the element with its page's capture, and the page with nothing selected, with a Vue router and without, with DevTools open and closed, and which tab is taken as tabs are brought to the front), the page's console problems and failed requests from before the capture, kept to the last 50 and fenced, the commands `ui-capture` sends a page over its own sessions (through a relay of the debugging address), the history it cannot read, and each refusal, that a page off localhost is never read or attached to, that the MCP server `.mcp.json` declares lists localhost pages only and sees the selection, and that `agent-chrome` starts Chrome with its own profile and port.

`evals/` holds the skill's eval cases (`claude plugin eval ~/agent-team/toolkits/frontend`): it fires on a fix about the selected element and leaves a general front-end question alone.
Every `frontend` call there is answered by an agent mock of a Conventioner page (`evals/mocks/frontend/_server.md`), whose `_tools.json` is the server's own `tools/list`, which the toolkit test keeps in step.
Results go to `evals/results/`, which is gitignored.
