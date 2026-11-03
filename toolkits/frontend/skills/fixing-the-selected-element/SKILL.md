---
name: fixing-the-selected-element
description: Fixes a front-end issue on the element Daniel selected in the Agent Chrome's DevTools, by capturing it with ui-capture (its page, HTML, matched CSS, Vue source file and line, and screenshots) and editing the .vue file the capture names. Use when Daniel's message is about "the selected element", "this element", "the one I inspected" or what they are pointing at in the Agent Chrome, before looking for the element any other way.
---

# Fixing the selected element

Daniel has right-clicked an element in the Agent Chrome (the Chrome window `scripts/agent-chrome` started, for the local dev site only) and picked Inspect, so DevTools' Elements panel holds it.
Their message says what to change; the capture says what and where the element is.

## 1. Capture it

Run, from the session's working directory:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/ui-capture .scratch/ui
```

Always `.scratch/ui`, never inside `.scratch/task/`, whose contents a task's archive and checkpoints carry off the machine; git ignores `.scratch/` in the team's projects.
A capture stays on this machine: never commit it, attach it or post it, and delete the directory once the fix is done.
With an element selected, it writes the element capture, `ui-pick.md` and `element.png`, and the page capture of its page, `ui-page.md`, `page.png` and `page-snapshot.txt`, and prints one line naming the element, its source and its page.
With nothing selected, it writes the page capture alone, exits 0 and prints a line saying no element was selected.

When the directory holds no `ui-pick.md`, nothing was selected: tell Daniel so and ask them to right-click the element and pick Inspect (or click it in the Elements panel), then capture again; never guess the element from the page capture.

When it exits 1, its one line says why; tell Daniel that line and the step that fixes it, and wait, rather than guessing which element they meant:

- no Agent Chrome answers: Daniel runs `~/agent-team/toolkits/frontend/scripts/agent-chrome`, opens the page there and inspects the element;
- no localhost page open: Daniel opens the dev server's page in the Agent Chrome and inspects the element;
- no Vue source data: the page is not the Vite dev server (a production build or another site), so ask for the dev server's page;
- no answer in 30 s, or the server never attached to a tab: the machine is busy or the page hung, so Daniel reloads it, or you wait and capture again.

## 2. Read it

Read `ui-pick.md` whole, then `ui-page.md`, and look at both screenshots with Read (a tab that is not visible has no `page.png`, and `ui-page.md` says so).

- **Source**: the first line of the source chain is the element itself, `<tag> src/...vue:<line>:<column>`, relative to the front end's root (Conventioner's `front-end/`); the lines after it are its parents, outward.
- **Components**: the component chain, innermost first, says which component renders it, which matters when the element comes from a slot or a child component.
- **CSS**: every matched rule in cascade order, overridden declarations marked `[overloaded]`.
  A rule's location there is the dev server's injected `<style>` tag, not a file line: a selector with a `[data-v-...]` attribute lives in the `<style scoped>` of the component whose elements carry that attribute; any other selector lives in a global stylesheet, found by searching for it.
- **The page** (`ui-page.md`): its route's Vue components and files, and its console problems and failed requests since it last loaded.
  Use those when they bear on the element, an error from its component or a failed request behind a button that does nothing, say, and start the fix from them.

## 3. Fix it

- Open the `.vue` file at the line the capture names, in this session's own checkout, and make the change there.
- Keep to the project's own styles: its tokens and variables (`var(--space-4)`), its shared classes, and the component's existing rules, rather than new values.
- When the fix is "like another element" (the same height as a button beside it), read that element's rules too: ask Daniel to inspect it and capture again into another directory, or find it in the same file.

## 4. Check it

The dev server reloads the change on its own.
Capture again into the same directory and compare the new `element.png` and the CSS with the old ones; if the selection was lost in the reload, ask Daniel to inspect the element again.
The frontend MCP tools (`take_snapshot`, `take_screenshot`, `get_css_styles`) give a closer look at the same page without a new capture.

## Rules

- Stay on Daniel's page: never navigate the Agent Chrome elsewhere, open another page, click or type into it unless Daniel asks, and say so before anything that changes what they see.
- Localhost only: the tools see no other page and refuse to navigate off localhost; never try another way round.
- Fixture data only: never log in with a real account or load real applicant data there, and never put a capture of a page with real data into a message.
