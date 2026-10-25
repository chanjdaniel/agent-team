---
name: ui-intake
description: Keep what Daniel pointed at for a front-end fix in the task's directory before anything else, with team-ui. Use when Daniel's message is a UI fix about the element they selected or inspected, or comes with a screenshot of the app.
---

# UI intake

A worker starts minutes or hours after Daniel's message, when the Agent Chrome may show something else, and Discord attachments land in the plugin's inbox, which no worker reads.
So keep the pointer at once, before planning.

1. Open the task as usual (or take the task in flight it belongs to).
2. Run `team-ui T<n>` with what the message gives:
   - `--capture` when it is about the selected or inspected element, or "this" in the Agent Chrome: Daniel is at the laptop, and `ui-capture` reads the element selected in DevTools there;
   - `--attach <file>` for each screenshot, after saving it with the Discord plugin's `download_attachment`.
3. When the capture fails, tell Daniel its line in the thread, in one line, with its fix (start the Agent Chrome with `~/agent-team/toolkits/frontend/scripts/agent-chrome`, or right-click the element and Inspect), and go on with the attachment or the words; never wait on it.
4. Write the plan and briefs as usual: `team-brief` names `tasks/T<n>/ui/` in the planner's, builders' and reviewers' briefs, with the rule that a worker checks its fix on its own stack with its own headless browser, never in the Agent Chrome.

## Real data stays off Discord

- Screenshots Daniel posts to Discord leave the laptop, so they come from the local dev stack with fixture data only, never production or a page with applicants' real data.
- When an attachment shows real data (production's address, real names, emails or phone numbers), do not keep it: delete it from `tasks/T<n>/ui/`, and ask Daniel in the thread for one from the dev stack, or for the page's path and the element in words.
- A capture never leaves the team home: a brief points at it, and nothing of it is posted to Discord.
