---
name: ui-intake
description: Keep what Daniel pointed at for a front-end fix in the task's directory before anything else, and follow Daniel's manual QC walk, with team-ui. Use when Daniel's message is a UI fix about the element they selected or inspected, comes with a screenshot of the app, asks to check, look at or capture the page, starts or stops a manual QC walk, or is a walk note in a task whose walk is on.
---

# UI intake

A worker starts minutes or hours after Daniel's message, when the Agent Chrome may show something else, and Discord attachments land in the plugin's inbox, which no worker reads.
So keep the pointer at once, before planning.

## The words

- A **manual QC walk** is a state of one task, on only between Daniel's start and stop, recorded by `team-ui T<n> --walk` in the ledger, so a restarted or compacted coordinator still knows it.
- A **walk note** is a message from Daniel in the walk's task thread while that task's walk is on.
- A **page capture** is what `team-ui --capture` gives when nothing is selected in the Agent Chrome's DevTools: the page Daniel is on, without an element.
  With an element selected, it gives an element and page capture.

## A fix or a request

1. Open the task as usual (or take the task in flight it belongs to).
2. Run `team-ui T<n>` with what the message gives:
   - `--capture` when Daniel asks to check, look at or capture the page, or the message is about the selected or inspected element, or "this" in the Agent Chrome: Daniel is at the laptop, and `ui-capture` takes the page they are on there, with the element selected in DevTools when there is one;
   - `--attach <file>` for each screenshot, after saving it with the Discord plugin's `download_attachment`.

   Outside a walk, capture only on such a request, never for an ordinary message about a task.
   It prints `ui-capture`'s line, which names the `capture-<k>/` it wrote, then `captured: page` or `captured: element and page`, then every file `tasks/T<n>/ui/` holds.
3. When the capture fails, tell Daniel its line in the thread, in one line, with its fix, and go on with the attachment or the words; never wait on it:
   - no Agent Chrome answers: start it with `~/agent-team/toolkits/frontend/scripts/agent-chrome`;
   - no localhost page open: open the dev site's page in the Agent Chrome;
   - no Vue source data on the selected element: the page is not the dev server's, so select it on the dev server's page;
   - no answer in 30 s, or the server never attached: the machine is busy or the page hung, so reload it or try again later.
4. Read the capture (below), so a "what is wrong here" note is answered from it before planning.
   A fix about the inspected element that gets `captured: page` had nothing selected: say so in one line and go on with the page and the words.
5. Write the plan and briefs as usual: `team-brief` names `tasks/T<n>/ui/` and each capture in it in the planner's, builders' and reviewers' briefs, with the rule that a worker checks its fix on its own stack with its own headless browser, never in the Agent Chrome.

## A manual QC walk

- Daniel starts and stops a walk by saying so, in the task's thread or in `#coordinator` naming the task: run `team-ui T<n> --walk start` or `team-ui T<n> --walk stop` at once, then say in the thread that the walk is on and each message there is captured until Daniel ends it, or that it is off.
- Never start a walk on your own judgement: when Daniel seems to be walking the app with no walk on, you may ask once whether to start one, and leave it at their answer.
- Before treating a message in a task's thread as a walk note, check `team-ui T<n> --walk status` (or `team-state`, whose line shows `| walk on since <ts>`); a walk on one task makes nothing in another task's thread a walk note.
- For each walk note, run `team-ui T<n> --capture --note '<the note>'` before answering it, with Daniel's words as they posted them, then read the capture and answer the note.
- A failed capture is one line to Daniel in the thread with its fix, as step 3 says, and never holds the note up: answer it from its words.
- When Daniel's last walk note has been dealt with and they say the walk is done, stop it.
- After a restart or a compaction, `team-state` names any walk still on: ask Daniel in that thread whether it is still going, rather than stopping it unasked.

## Reading a capture

Read the files of the `tasks/T<n>/ui/capture-<k>/` that `ui-capture`'s line names, in this order:

1. `ui-page.md`: the page, its route and title, why that page was taken (when it is not the page Daniel meant, say so in one line), the Vue route's components and their files, and the page's console problems and failed requests since it last loaded.
2. `page.png`, with Read: what Daniel saw; a tab that was not visible has none, and `ui-page.md` says so.
3. `ui-pick.md` and `element.png`, when the capture took an element: its source file and line, components, HTML and matched CSS.

`page-snapshot.txt` is the page's accessibility snapshot, for finding an element Daniel describes in words, and `note.md`, when there is one, holds the words Daniel posted with the capture, such as a walk note.

## Real data stays off Discord

- Screenshots Daniel posts to Discord leave the laptop, so they come from the local dev stack with fixture data only, never production or a page with applicants' real data.
- When an attachment shows real data (production's address, real names, emails or phone numbers), do not keep it: delete it from `tasks/T<n>/ui/`, and ask Daniel in the thread for one from the dev stack, or for the page's path and the element in words.
- A capture stays on the machine that took it: the team home's git ignores `tasks/*/ui/`, so no checkpoint, records commit or handoff carries it, and `team-close` removes it when the task closes.
  A worker on another machine after a handoff has no capture: give it the page and the element in words.
- Nothing of a capture is posted to Discord, a walk's captures included; a brief points at it.
