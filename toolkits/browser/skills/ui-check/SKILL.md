---
name: ui-check
description: Decides from the diff whether a UI change needs a look, then captures the screens it touches and their siblings and judges them against the design document. Use before delivering or approving a change to a UI.
---

# UI check

## Tier

Decide from the diff (`git diff --name-only origin/<base>...HEAD`), never from taste:

- **None**: no changed file renders.
  Components, views, pages, templates, style sheets, design tokens, the router's list of screens, layout primitives, assets shown on screen and logic whose result is shown render; tests, docs, back-end code and build or CI config do not.
  Write one line, `ui-check: none, no file that renders changed`, where the findings go, and stop.
- **Spot check**: each rendering change stays inside one component's box (copy, colour, an icon, a control's look), with no change to size, spacing, position, display, flex or grid, overflow, font size or line height, no element added to or taken out of the flow, and no shared primitive or token.
  One tile per touched state, no siblings, at most 3 tiles.
- **Walk and judge**: anything else, and whenever unsure: the touched states and their direct siblings.

A ticket builder takes at most a spot check, of the states its own commits touch; walk and judge is for the builder who delivers and the reviewer.
A fix round or rereview judges only the states the fixes touched and their siblings.

Name each state before capturing anything.
A touched state is a screen in one state that renders a changed file: a route, an open dialog, menu or drawer, a disabled, empty, loading or error state.
A direct sibling renders the same changed component, class or token in the same frame (page frame, row or list, dialog family): search the source for the changed names.
A token or primitive used on more than 4 screens: take the 3 most different (say a dense table, a form, a row of cards), and list the rest as not judged.

## Budget

A tile costs `ceil(w/28) x ceil(h/28)` image tokens:

| Tile | Viewport | Image | Tokens |
| - | - | - | - |
| Touched state, at the design width (Conventioner: 1920x1080) | `chrome-devtools-axi emulate --viewport "1920x1080x1"` | 1920x1080 | 2,691 |
| Touched state, when the design document gives no width | `chrome-devtools-axi emulate --viewport "1440x900x1"` | 1440x900 | 1,716 |
| Sibling, laid out at the design width, captured at 0.75 scale | `chrome-devtools-axi emulate --viewport "1920x1080x0.75"` | 1440x810 | 1,508 |
| Phone, only for a screen the design document says fits one | `chrome-devtools-axi emulate --viewport "390x844x1,mobile,touch"` | 390x844 | 434 |

A sibling's question is breakage (squeezed, wrapped, cut off, overlapping), not a few pixels.
The phone stays at scale 1: scale 3 makes a 1170x2532 image, about 3.8k tokens.
`emulate --viewport` is the one way to size it (never `resize`).

The cap is 16,000 image tokens per run (5 touched tiles, or 3 touched, 4 sibling and 4 phone tiles).
Above it, judge the touched states first, then siblings by risk, and list every state left out as not judged.

## Capture

The run's directory, `<run>`, is `.scratch/task/ui-check/<role>-<short head>/`; make it first.
When the project's `CLAUDE.md` or `AGENTS.md` names a scripted walk that writes named states as viewport tiles at given sizes, the project's scripted walk captures the states it reaches; axi captures the rest, in this session's own browser (`CHROME_DEVTOOLS_AXI_SESSION`), on the worktree's own stack (`team-stack up`).

Sign in once, as the project's seeded test user:

- `chrome-devtools-axi open <sign-in url>` prints the form's snapshot, with refs such as `@g1:1_3`.
- `chrome-devtools-axi fill @<ref> "<text>"` per field, then `chrome-devtools-axi click @<ref>`; each makes earlier refs stale, so take each ref from the last output.
- `chrome-devtools-axi wait "<text>"` for a text the signed-in page shows.

Then only commands that print a line:

- Navigate: `chrome-devtools-axi eval "() => { location.assign('<path>'); return 'ok' }"`, then `wait`.
- Open a dialog, menu or drawer, or a disabled, empty or error state: `chrome-devtools-axi eval "() => { document.querySelector('<selector>').click(); return 'ok' }"`, then `wait`.
- `chrome-devtools-axi snapshot` only when no selector is known: 1k to 4k tokens on a real screen.
- A tile, the viewport only, named `<state>-<width>x<height>[-<n>].png`: `chrome-devtools-axi screenshot <run>/<state>-<width>x<height>.png`.
- A tall state, a window at a time, only as far as the change reaches: `chrome-devtools-axi eval "() => { scrollBy(0, innerHeight); return scrollY }"`, then the next tile, `-2`.
- One element at scale 1, for a few-pixel doubt, at its own size in the budget: `chrome-devtools-axi screenshot <run>/<state>-<element>.png --uid @<ref>`.

## Cheaper checks first

- The scripted walk's report-only findings for the touched states, if it has them: hints where to look, never verdicts; a spot check with clean ones needs only its tile.
- The phone probe, before any phone tile: overflow in pixels and tap targets under 44px; a phone state asking only those, at 0 and 0, needs no tile.

  ```
  chrome-devtools-axi eval "() => { const small = [...document.querySelectorAll('a, button, input, select, textarea, [role=button]')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && r.height && (r.width < 44 || r.height < 44) }).length; return { overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth, small } }"
  ```

- `chrome-devtools-axi console`, once the touched states are opened: errors and Chrome's issues.

## Judge

The project's design document wins over taste: its `CLAUDE.md` or `AGENTS.md` names it (Conventioner's is `docs/design-system.md`); read only the sections these checks need, by their headings.
On every tile, against its values:

- Every screen of one frame is one width, the frame placed alike on each.
- Content sits on the frame's inset, on one line with its neighbours (Conventioner: `--space-6`, in line with the rail).
- Type and spacing stay on its scales; chips and labels follow its case rule.
- A card ends at its content, and cards in a row line up.
- Nothing is cut off, overlapping, squeezed into a sliver or left as a wide empty band.
- At phone width nothing is wider than the window, and targets are at least 44px.

## Accessibility and load

On each touched state: `chrome-devtools-axi lighthouse --mode snapshot --output-dir <run>/lighthouse/<state>`.
Never read the report; read only the failing accessibility audits and their elements:

```
jq -r '.categories.accessibility.auditRefs[].id as $id | .audits[$id] | select(.score != null and .score < 1) | "\(.id): \(.title) [\([.details.items[]?.node.selector] | join(", "))]"' <run>/lighthouse/<state>/report.json
```

A throttled trace only when the change can affect load (a new route, a new or heavier asset, font or image, a new front-end dependency, data fetched on mount), and last, as only `stop` clears it:

- `chrome-devtools-axi emulate --network "Slow 4G" --cpu 4`
- `chrome-devtools-axi perf-start --no-auto-stop` reloads the page; `wait` for its text.
- `chrome-devtools-axi perf-stop` lists the insight sets, such as `NAVIGATION_0`.
- `chrome-devtools-axi perf-insight <set> LCPBreakdown`: a large load or render delay is where to look.

## Record

`<run>/findings.md`, beside the tiles:

- the tier and why; the design document and the sections read;
- one row per tile: file, state, touched or sibling, viewport, image tokens, verdict;
- the findings, numbered, each with its tile, what is wrong and the check it breaks;
- the states not judged, and why;
- the failing audits, and the LCP breakdown when traced;
- the run's image tokens, the sum of the rows.

The task's archive keeps `findings.md`, never the tiles or reports.

## Stop

`chrome-devtools-axi stop` when done and after every trace: it ends the session's bridge and browser, so no throttling leaks into a later check.

The Lighthouse filtering and the LCP-breakdown steps are adapted from chrome-devtools-mcp 1.12.0's `a11y-debugging` and `debug-optimize-lcp` skills (Apache-2.0).
