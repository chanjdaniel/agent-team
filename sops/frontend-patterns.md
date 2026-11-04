# SOP: frontend patterns

Read this before a UI task plans or builds a reusable component, a long list, a dialog or a prototype's data.
Each rule held up on a real product, under review and at real sizes, and says why it holds.
The examples come from a Vue and Vite app, and the rules hold on any stack; numbers and paths are examples to start from.
A project's own design document decides how things look, and wins where it disagrees.

## A dev-only component library

- Make the library a route of the app itself, one address per entry, never a static page or a Storybook.
  Why: only the app renders its own components, styles and tokens faithfully, and once merged the route is on every local stack with no sign-in and no seeded data.
- Register its routes only inside a dev-only branch, each a lazy import, such as `if (import.meta.env.DEV) { router.addRoute(...) }`.
  Why: a production build drops the block and its imports.
- Refuse a static import of the dev folder with a lint rule that matches any path through it, such as the regex `^(@/|(\.{1,2}/)+(.+/)?)dev(/|$)` in ESLint's `no-restricted-imports`.
  Why: a rule on the alias alone misses `../dev/...`, and a shipped file can then import the library's data.
- Fail every production build on any module under the dev folder, with a bundler plugin over each emitted chunk's module ids that names the chunk and the module.
  Why: it catches what the lint cannot, a dynamic import or the block kept alive, and a scan of the output for a marker string catches only the modules that carry the marker, so the page's data ships unseen.
- Compare those module ids against the folder resolved as the bundler resolves it, in Vite `normalizePath(realpathSync(...))`.
  Why: the ids are real paths with `/` separators, while a path built from `import.meta.url` keeps its links and separators, so the guard fails open on a linked checkout or on Windows.
- Test the plugin through a real build with the project's own config (`loadConfigFromFile`, then `build` with `write: false`), with `NODE_ENV=production` set around it.
  Why: Vitest runs under `NODE_ENV=test`, which Vite does not read as production, so a guard on `isProduction` skips and keeps the library.
- Make each entry one file found by a glob (`import.meta.glob`), write the index's list whole once, and list an unbuilt entry as "coming".
  Why: later work adds only its own file and spec.
- Put a read-out line under each live demo, and end each entry with a "Choices for you" note.
  Why: a session critiquing the library ends in answers.

## A combobox grown by opt-in props

- Add a cap, several choices or typed text as opt-in props on the one picker, and append their tests to its old test file only.
  Why: the old behaviour's tests, unchanged, prove the growth is additive.
- Type the props as a union, such as `{ multiple?: false; modelValue: string } | { multiple: true; modelValue: string[] }`.
  Why: a caller's mismatch becomes a type error.
- Under a cap, draw at most N matches across the groups in order, then a line "N more, type to narrow" that is no option, kept in view (`position: sticky` with a matching `scroll-padding-bottom`) and named by the field's `aria-describedby`.
  Why: the keys never land on it, and a screen reader stays on the field under `aria-activedescendant`, so only the field can say it.
- When the current choice is past the cap, name it in the field or its chip, leave no row active, and let Enter keep it.
  Why: otherwise Enter swaps the choice for the first row.
- Leave out a group that the cap alone empties.
  Why: its "None match" would be false.
- With several choices, keep a chosen row in place and ticked, and keep the list and the words, selected, after each choice.
  Why: rows never move under the pointer.
- Let a held Backspace take no chip (`event.repeat`).
  Why: clearing the words then stops at the field.
- Use `mousedown.prevent` on the chips, and move the focus to the next chip only when it is already on a chip's button.
  Why: removing a chip by pointer keeps the field's focus, words and list.
- Offer typed text as `Use "<words>"`, leading the list outside the cap, only when the words are exactly no option, and have each screen decide what words not chosen mean before it converts them.
  Why: the keys reach it first, it never competes with an option of the same name, and words not chosen are no value.

## A frame for a large list

- For a list of up to a few hundred rows already in memory, use one frame: a find field past a threshold (12 rows), the screen's filters, a count line, the first page (50 rows) and "Show N more".
  Why: it held at that size with no new request, so virtual scrolling and numbered pages would add machinery the list does not need.
- Tell a re-read of the same rows from a change by a row key, and go back to one page on a change of words or rows.
  Why: a refresh never folds what was unfolded.
- Do not remove the find field as the focus leaves it: keep it while it holds words, or once focused until the rows next change with the focus elsewhere.
  Why: on a phone its leaving moved the filters under the press that took the focus, and the press was lost.
- Make Enter in the find field do nothing.
  Why: the rows narrow as it is typed in, and in a dialog's form Enter would otherwise save what the person was only looking through.
- Move the focus to the first new row after "Show N more".
  Why: the button goes with the last page, and the focus would go with it.
- Write the words to the address with `router.replace` as they are typed, spaces included, and find with them trimmed.
  Why: trimming what is written would stop a second word from being typed.
- In a filter toggle, wrap the label and the count in spans, and give each `font-weight: inherit` under a global `*` weight reset.
  Why: an inline flex button makes two children lose the space a screen reader needs, and the reset takes a pressed toggle's weight.

## Dialog sizes and the pinned body

- Give dialogs a few named widths, each `min(100% - 2 * gutter, step)`, such as 26rem for two controls, 38rem for a list and 60rem for a list beside what it gathers.
  Why: a step fits what the dialog holds, where a percentage of the window changes with the window.
- Offer an opt-in mode where only a box between a pinned title and pinned actions scrolls.
  Why: a whole window that scrolls loses its title and Save, and its scroll bar squares the rounded corners and takes width from content laid out without it.
- Keep the body, the error and the actions in one `<form>` when pinning them.
  Why: Enter still submits.
- When one dynamic component replaces a form branch and a div branch, bind `submit` only on the form, and diff each branch's listeners as well as its markup.
  Why: on the div every nested form's bubbling submit reaches the listener, and a markup snapshot cannot see a listener.
- Walk every kind of control when a dialog's filter must not submit on Enter, not only the text fields.
  Why: in Chromium Enter on a focused checkbox submits its form, while on a native select it did not.
- Draw edge shades at the scroller's top and bottom only while there is more that way, measured on `scroll` and by a `ResizeObserver` on the scroller and its content, with `pointer-events: none`.
  Why: the content can grow with no scroll event, and a shade must never take a press.
- Pin a tray for what the dialog has gathered between the body and the actions, `flex: none` with its own `max-height` (40dvh) and its own scroll.
  Why: with `flex-shrink` it collapsed with the body and lost its contents.
- On a phone, make a body-scroll dialog the window's height less the gutter in `dvh`.
  Why: otherwise the browser bar covers the pinned actions.
- Give the scroller block padding (8px) and an inset halo on `:focus-visible`.
  Why: a focus halo at its edge is otherwise clipped.
- Put no `tabindex` and no `scrollbar-gutter: stable` on the scroller.
  Why: Chrome already makes a scroller with nothing focusable a tab stop, and the gutter unbalances the padding of a body that does not scroll.
- Make each new option opt-in and pin the old markup with inline snapshots, then move dialogs over one by one and delete the old mode when none uses it.
  Why: each step is proved to leave the dialogs not yet moved as they were.

## A realistic fixture derived by the product's own readers

- Derive the data for a prototype, demo page or visual test from committed synthetic exports, made by a seeded generator and read by the product's own parsers, never type it.
  Why: no real person's data enters the repository, every label, group and count is what the product would make, and a typed fixture drifts from that.
- Deal what no file holds (statuses, roles, seats) from a seeded generator, with the counts stated in the deriver.
  Why: the same seed gives the same data, and the counts are the sizes being judged.
- Write one JSON file that the front end imports, the same bytes every run, never hand-edited, with the formatter kept off it (`.prettierignore`).
  Why: anything else breaks the byte comparison below.
- Have a test regenerate the file, fail on any byte of difference, and pin every count.
  Why: the realistic sizes are what make a choice on that data meaningful.
- Find columns by the product's own classification, not by header text.
  Why: a real export can repeat a header.

## Measuring bundle growth by building both

- To judge a bundle budget, build the base and the head the same way in a clean tree with CI's variables, and compare the delta (the base from `git archive` into a scratch directory, `node_modules` linked).
  Why: a git-ignored local `.env` inlines `VITE_` values, and moved an entry chunk by about 250 B against CI, so a budget that passes locally can fail in CI.
- Measure each entry chunk with the budget script's own reader, and attribute the growth by which chunk changed, then by swapping one changed file at a time into the base build.
  Why: this says whose growth it is before a limit is raised or blamed.
- Judge a new ceiling against the CI-like total.
  Why: absolute totals differ by environment, and CI's is the one that gates.
- Write the builds to a temporary directory with `--outDir`, never to the worktree's `dist/`.
  Why: the measure then leaves the worktree as it was.
