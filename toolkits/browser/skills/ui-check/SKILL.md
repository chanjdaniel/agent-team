---
name: ui-check
description: Captures the screens a UI change touches as viewport tiles with chrome-devtools-axi, runs the cheap text checks, and judges each tile. Use before delivering or approving a change to a UI.
---

# UI check

Every `chrome-devtools-axi` command here runs in this session's own browser (`CHROME_DEVTOOLS_AXI_SESSION` names it for your task and role), so no prefix is needed.
Work on the worktree's own stack (`team-stack up`), never Daniel's.
The run's directory, `<run>`, is `.scratch/task/ui-check/<role>-<short head>/`; make it first.

## Capture

When the project's `CLAUDE.md` or `AGENTS.md` names a scripted walk that writes named states as viewport tiles at given sizes, the project's scripted walk captures the states it reaches; axi captures the rest, as below.

Sign in once, as the project's seeded test user:

- `chrome-devtools-axi open <sign-in url>` prints the form's snapshot, with refs such as `@g1:1_3`.
- `chrome-devtools-axi fill @<ref> "<text>"` for each field, then `chrome-devtools-axi click @<ref>` on the button.
  Each prints a new snapshot and makes the refs before it stale, so take each ref from the last output.
- `chrome-devtools-axi wait "<text>"` for a text the signed-in page shows.

From then on, use only commands that print a line:

- Navigate: `chrome-devtools-axi eval "() => { location.assign('<path>'); return 'ok' }"`, then `chrome-devtools-axi wait "<text>"`.
- Open a dialog, menu or drawer, or reach a disabled, empty or error state, by its selector: `chrome-devtools-axi eval "() => { document.querySelector('<selector>').click(); return 'ok' }"`, then `wait` for its text.
- `chrome-devtools-axi snapshot` only when no selector is known: it costs 1k to 4k tokens on a real screen.

Size the viewport with `emulate --viewport`, the one way to (never `resize`):

| Tile | Viewport | Image |
| - | - | - |
| Touched state, desktop, at the design width | `chrome-devtools-axi emulate --viewport "1920x1080x1"` | 1920x1080 |
| Sibling, laid out at the design width, captured at 0.75 scale | `chrome-devtools-axi emulate --viewport "1920x1080x0.75"` | 1440x810 |
| Phone, only for a screen the design document says fits one | `chrome-devtools-axi emulate --viewport "390x844x1,mobile,touch"` | 390x844 |

The phone viewport stays at scale 1: scale 3 makes a 1170x2532 image, about 3.8k tokens.

- A tile: `chrome-devtools-axi screenshot <run>/<state>-<width>x<height>.png`, the viewport only.
- A tall state, one window at a time, only as far as the change reaches: `chrome-devtools-axi eval "() => { scrollBy(0, innerHeight); return scrollY }"`, then the next tile, `-2`, `-3` on its name.
- One element at scale 1, to settle a few-pixel doubt a tile leaves: `chrome-devtools-axi screenshot <run>/<state>-<element>.png --uid @<ref>`, its ref from a `snapshot`.

## Cheaper checks first

- The phone probe, at the phone viewport, before any phone tile: it returns the page's horizontal overflow in pixels and the count of visible tap targets under 44px.
  A phone state whose only question is overflow or target size, and whose probe returns 0 and 0, needs no phone tile.

  ```
  chrome-devtools-axi eval "() => { const small = [...document.querySelectorAll('a, button, input, select, textarea, [role=button]')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && r.height && (r.width < 44 || r.height < 44) }).length; return { overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth, small } }"
  ```

- `chrome-devtools-axi console`, once the touched states have been opened: the page's errors and Chrome's issues, as text.

## Accessibility and load

On each touched state, Lighthouse's accessibility audit, in snapshot mode so it audits the state as it stands: `chrome-devtools-axi lighthouse --mode snapshot --output-dir <run>/lighthouse/<state>`.
Never read its report; read only the failing accessibility audits and the elements they name:

```
jq -r '.categories.accessibility.auditRefs[].id as $id | .audits[$id] | select(.score != null and .score < 1) | "\(.id): \(.title) [\([.details.items[]?.node.selector] | join(", "))]"' <run>/lighthouse/<state>/report.json
```

A throttled trace only when the change can affect page load (a new route or page, a new or heavier asset, font or image, a new front-end dependency, data fetched on mount), and last, since nothing clears the network throttling but `stop`:

- `chrome-devtools-axi emulate --network "Slow 4G" --cpu 4`
- `chrome-devtools-axi perf-start --no-auto-stop`, which reloads the page, then `wait` for its text.
- `chrome-devtools-axi perf-stop` lists the insight sets, such as `NAVIGATION_0`.
- `chrome-devtools-axi perf-insight <set> LCPBreakdown`: the LCP's subparts; a large load delay or render delay is the first place to look.

## Stop

`chrome-devtools-axi stop` when the run is done, and after every trace: it ends the session's bridge and its browser, so no browser stays running and no throttling leaks into a later check.

The Lighthouse filtering and the LCP-breakdown steps are adapted from chrome-devtools-mcp 1.12.0's `a11y-debugging` and `debug-optimize-lcp` skills (Apache-2.0).
