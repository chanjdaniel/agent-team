---
name: ui-intake
description: Keep what Daniel pointed at for a front-end fix in the task's directory before anything else, and follow Daniel's manual QC walk, with team-ui. Use when Daniel's message is a UI fix about the element they selected or inspected, comes with a screenshot of the app, asks to check, look at or capture the page, starts or stops a manual QC walk, in the task's thread or an interview thread, or is a walk note in a task whose walk is on, or team-sweep finds walk-stale.
---

# UI intake

A worker starts minutes or hours after Daniel's message, when the Agent Chrome may show something else, and Discord attachments land in the plugin's inbox, which no worker reads.
So keep the pointer at once, before planning.

## The words

- A **manual QC walk** is a state of one task, on only between Daniel's start and stop, recorded by `team-ui T<n> --walk` in the ledger, so a restarted or compacted coordinator still knows it.
- A **walk note** is a message from Daniel in the walk's task thread while that task's walk is on; in an interview walk, the notes are its planner's, and you never see them.
- An **interview walk** is a walk that runs in the task's interview thread (`--in interview`), which its planner follows on its own, with no relay through you.
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
5. Write the plan and briefs as usual: `team-brief` names `tasks/T<n>/ui/`, each capture in it with a note or an element, and counts the others, in the planner's, builders' and reviewers' briefs, with the rule that a worker checks its fix on its own stack with its own headless browser, never in the Agent Chrome.

## A manual QC walk

- Daniel starts and stops a walk by saying so, in the task's thread or in `#coordinator` naming the task: run `team-ui T<n> --walk start` or `team-ui T<n> --walk stop` at once, then say in the thread that the walk is on and each message there is captured until Daniel ends it, or that it is off.
- Never start a walk on your own judgement: when Daniel seems to be walking the app with no walk on, you may ask once whether to start one, and leave it at their answer.
- Before treating a message in a task's thread as a walk note, check `team-ui T<n> --walk status` (or `team-state`, whose line shows `| walk on since <ts>`); a walk on one task makes nothing in another task's thread a walk note.
- For each walk note, before answering it, write Daniel's words as they posted them with the Write tool to `tasks/T<n>/ui/.note-<its message id>` in the team home, never on the command line, then run `team-ui T<n> --capture --note-file <that file>`, read the capture and answer the note.
- A failed capture is one line to Daniel in the thread with its fix, as step 3 says, and never holds the note up: answer it from its words.
- When Daniel's last walk note has been dealt with and they say the walk is done, stop it.
- After a restart or a compaction, `team-state` names any walk still on: ask Daniel in that thread whether it is still going, rather than stopping it unasked.
- A note reaches the clock only through `--note-file` here: a message you answer with no capture does not keep the walk counting.

## A walk in an interview thread

A walk belongs to its planner when Daniel asks for it in an interview thread, or asks to see snapshots of it there; a walk in the task's own thread stays yours, as above.
It leaves you out of each note, and only one runs at a time, since Daniel has one Agent Chrome window.

1. On Daniel's word, open the thread with `team-thread T<n> --interview`, which prints its id; a task of its own for the walk is a `research` one, since its planner delivers a report and a fix plan.
2. Start the walk with `team-ui T<n> --walk start --in interview`, which refuses a second one and names the walk on.
   It runs on the task's own seeded stack, whose captures may leave.
   Only when Daniel says, in a message naming its port, that the primary stack was just reseeded, and wants to walk there, add `--reseeded <its message id>`: it reads that message back, and it must be theirs, within the hour, and say so; it clears only the port it names, and a walk already on must stop first.
3. Write the brief with `team-brief T<n> planner-walk --set-file read=<file>`, the file naming the walk's stops, and launch it with `team-worker T<n> planner <worktree> -- "Read your brief at <path>"`.
   `team-worker` still refuses it this toolkit: it reads the window only by `team-ui T<n> --capture`.
4. Log `team-log T<n> waiting on=Daniel reason="walk in <#id>"`, post `<#id>` in the task's thread and `#coordinator`, and run `team-inbox`, which lists it under Walks under way.
5. A message of Daniel's in the task's thread during it is no walk note: point them at `<#id>`, unless it is the stop.
6. Stop it with `team-ui T<n> --walk stop` on Daniel's word in the task's thread or `#coordinator`, or on the planner's `DONE`, whichever comes first, since it holds the window's one walk until then, and with it stopped the planner's captures refuse.
7. `team-sweep`'s `walk-stale` finding, for either kind of walk, says a walk has had no message from Daniel in 4 hours, so it no longer keeps its stack up or stows last.
   Ask Daniel in the task's thread whether it goes on: if not, `team-ui T<n> --walk stop`; if so, stop it and start it again in the form the finding names, `--in interview` included, with a new word when it used `--reseeded`.
   A stopped stack is the planner's to start again; a later message of Daniel's in an interview walk also makes it count again.

## Reading a capture

Read the files of the `tasks/T<n>/ui/capture-<k>/` that `ui-capture`'s line names, in this order:

1. `ui-page.md`: the page, its route and title, why that page was taken (when it is not the page Daniel meant, say so in one line), the Vue route's components and their files, and the page's console problems and failed requests since it last loaded.
2. `page.png`, with Read: what Daniel saw; a tab that was not visible has none, and `ui-page.md` says so.
3. `ui-pick.md` and `element.png`, when the capture took an element: its source file and line, components, HTML and matched CSS; an element on a tab that was not visible has no `element.png`, and `ui-pick.md` says so.

`page-snapshot.txt` is the page's accessibility snapshot, for finding an element Daniel describes in words, and `note.md`, when there is one, holds the words Daniel posted with the capture, such as a walk note.

## Real data stays off Discord

- Screenshots Daniel posts to Discord leave the laptop, so they come from the local dev stack with fixture data only, never production or a page with applicants' real data.
- When an attachment shows real data (production's address, real names, emails or phone numbers), do not keep it: delete it from `tasks/T<n>/ui/`, and ask Daniel in the thread for one from the dev stack, or for the page's path and the element in words.
- A capture's files stay on the machine that took it: the team home's git ignores `tasks/*/ui/`, so no checkpoint, records commit or handoff carries one, and `team-close` removes it when the task closes.
  A worker on another machine after a handoff has no capture: give it the page and the element in words.
- You never post a capture.
  A walk's planner, in its interview thread, posts only `page.png` and `element.png` of a capture, images and never a capture's text, by Daniel's decision (T222's D2), under `team-post`'s guards: the page's port is one of the task's own stack, or the one named by Daniel's word, at the walk's start, that the primary was just reseeded, and no file of the capture holds an address outside the fixture domains.
  Each posted image stays in that thread, and is retracted only for a mistake.
  Anywhere else, a brief points at a capture.
