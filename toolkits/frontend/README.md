# frontend

Front-end fixes on the element Daniel points at: Daniel right-clicks it in the Agent Chrome and picks Inspect, and the agent gets its page, HTML, matched CSS, Vue source file and line, and screenshots.
For Daniel's own Claude Code session, and for the coordinator's intake of a fix sent from Discord; build workers read the coordinator's capture, never the Agent Chrome.

## What it can see

- The Agent Chrome only: a Chrome window with its own profile (`~/.local/share/agent-team/agent-chrome`), started by `scripts/agent-chrome` with remote debugging on `127.0.0.1:9222`.
  Daniel's everyday Chrome, with its mail and any production tab, is a different browser that nothing here attaches to.
- Its `http://localhost:*` and `http://127.0.0.1:*` pages only: the server runs with an allowlist of those two and DevTools' own frontend (`devtools://devtools/*`, where the Elements panel's selection is read), so any other tab is neither listed nor read, and a navigation elsewhere is refused.
- Use it for the local dev site with fixture data, logged in with a fixture account.
  Never open production or real applicant data there: anything a capture holds can end up in a Discord thread or a task directory, and remote debugging on port 9222 lets any local process drive that window.
- Google's usage statistics, CrUX lookups and the server's update checks are off.

## What it runs

- `scripts/agent-chrome [--port <port>] [<url>]`: starts the Agent Chrome at the dev server (default `http://localhost:5173`), or says one already answers on the port.
- `scripts/ui-capture [--browser-url <url>] <out-dir>`: finds the element selected in DevTools' Elements panel on a localhost page of the Agent Chrome and writes `<out-dir>/ui-pick.md` (page, route, snapshot line, the `vite-plugin-vue-inspector` source chain such as `src/views/LoginView.vue:369:11`, the component chain, its HTML and every matched CSS rule) with `element.png` and `page.png`.
  It fails in one line, exit 1, when no Agent Chrome answers, no localhost page has DevTools open, nothing is selected, or the page carries no Vue source data (a production build).
  Each script's header is its `--help`.
- Both speak to the pinned `chrome-devtools-mcp` in `servers/` (installed by `servers/install`, checked by `team-doctor`'s `servers` line).

## Tests

`tests/run toolkits` runs `tests/toolkits/frontend.test.mjs`: a headless Chrome stands in for the Agent Chrome, a local fixture page shaped like Conventioner's dev build stands in for the app, and the test opens DevTools and selects an element in the Elements panel exactly as a click there does (`tests/toolkits/helpers/chrome.mjs`).
It checks each capture and each refusal, that a page off localhost is never read, and that `agent-chrome` starts Chrome with its own profile and port.
