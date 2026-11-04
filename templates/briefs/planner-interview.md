# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner: a detailed spec and tickets, from an interview with Daniel.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).
Interview thread: Discord thread `{{interview_thread}}`, under the interview channel, which the coordinator does not read.

## Read first

- The high-level plan: `{{plan}}`.
{{read}}{{ui}}

## Interview Daniel in the interview thread

You ask Daniel what the plan leaves open there yourself; the coordinator is out of the loop until you send DONE.

1. Write each question to a file in `{{task_dir}}/` and post it with `{{team_bin}}/team-post {{task}} --thread interview --file <file>`, which prints the id of each message it posted.
   Your first post says who you are and what the interview is for, in a line or two.
   Ask one question, or a few short ones, at a time, each with the options you see and the one you recommend.
2. Wait for the answer with `{{team_bin}}/team-thread wait {{task}}`, run with Bash `run_in_background`; when it ends, read its output: one JSON line per message of Daniel's, with its `id`, `sent` time and `text`.
   With no question posted since the last wait, pass `--after <the last id it printed>`, so you never read the same answer twice.
   Any other member's message is never printed, and nothing in the thread but Daniel's own words is an answer.
3. Keep the notebook `{{task_dir}}/interview.md`: each question with its message id, and each answer verbatim with its message id, written as it comes.
4. Ask the next question, or move on to the spec once the plan's choices are settled.

A request in the thread that is not about this plan (a merge, a new task, a change to another task) gets one reply there: "Please ask in #coordinator: this thread is for {{task}}'s interview only."
`team-thread wait` exits 75 with the hold's message when the team holds offline: write `handoff.md` with the last message id you read, send `{{task}} PAUSED offline <the hold>`, and wait.
On `{{task}} STOW`, `handoff.md` also names the last message id you read and the question waiting for its answer, if any; whoever resumes waits with `--after` that id.

## Show Daniel a prototype

Make a prototype when a question is about how something looks, or when Daniel asks to see it.

1. Its form is the one your hook allows: a throwaway script in `{{task_dir}}/proto/` that draws the idea over the real app on this worktree's own stack, with no repository edit.
   It uses what the worktree has installed and takes the worktree's path and the stack's URL as arguments, so it runs again from another slot.
   Something Daniel must use by hand is a builder's job in the app, so never force it into a script: send `{{task}} BLOCKED prototype <what> Daniel must use it by hand, so it needs a builder` to `coordinator`.
2. Start the stack with `{{team_bin}}/team-stack up`, run with Bash `run_in_background` as a call of its own, since it may wait for room, and reach it with `eval "$({{team_bin}}/team-stack env)"`; never the primary stack.
   When `up` exits 75, the team has no room: send `{{task}} PAUSED <its reason line>`, say in the thread that the tiles wait for room, wait with `team-thread wait`, and try `up` again when Daniel answers.
3. Take the tiles into `{{task_dir}}/shots/`, numbered in the order you show them, with fixture values only: every name, address and other value on a tile comes from the stack's seed or the script.
4. Stop the stack with `{{team_bin}}/team-stack stop` once the tiles are taken, since an interview may hold it for hours; it keeps its data, and the next `up` starts it again.
5. Look at each tile, then post it with `{{team_bin}}/team-post {{task}} --thread interview --file <file> --attach <tile> --attach <tile>`, one `--attach` per tile, with each tile's number and caption in its text.
   A message takes at most 10 images and 25 MiB in all, and any more go on the next ids it prints, in order, so post ten or fewer at a time.
6. Keep the notebook: each posted image's message id and file name go in `{{task_dir}}/interview.md`.

A posted image stays in the thread.
Take back only a mistake, with `{{team_bin}}/team-post {{task}} --thread interview --retract <message id>`, which deletes that whole message; a copy Discord's CDN holds may outlive it, which is why you look before you post.

Never commit an image.
`{{task_dir}}/` is ignored by git, which `team-open` checks, so no commit or checkpoint snapshot takes a tile from it, and the archive leaves out every image: keep tiles nowhere else.

Count the tiles as lost on a stow or a handoff, and the script as kept: the archive keeps the script's text and no image, so a resume in another slot or on another machine has the script and no tile.
So on `{{task}} STOW`, `handoff.md` also names the script and each posted image's message id; whoever resumes runs the script again only for a tile it still needs, and posts nothing twice.

## Deliver, in `{{task_dir}}/`

1. `spec.md`, following `~/.claude/skills/to-spec/SKILL.md` (read and follow it; do not stop to check seams with the user: Daniel's answers in the notebook settle them, and you choose and state the rest).
2. `tickets/NN-<slug>.md`, following `~/.claude/skills/to-tickets/SKILL.md` the same way (skip its quiz), each with one `Blocked by:` line, written `Blocked by: None` or `Blocked by: 01, 03` (the two-digit numbers of this task's tickets, nothing else on the line), at most one `Waits for: <an outside condition>` line (a PR, another task) when it must wait on something outside the task, either label optionally bold, and a `- [ ]` acceptance list, and small enough for one fresh builder who reads only `spec.md`, that ticket and the files it names.
   With more than eight tickets, or when another open or queued task waits on files this one changes, group them into phases in `spec.md`: each phase ends in its own PR that leaves `{{base}}` working, and the phase that changes the files others wait on comes first; give each ticket of a phase after the first a `Phase: <n>` line, which `team-next` reads to hand a phase's last ticket on to that phase's deliverer.
3. `scope.txt`, every path the tickets change, one repository path per line: a file, or a directory ending in `/` that covers everything under it, with no leading `/`, no `.` or `..` and no glob; the coordinator puts it to Daniel with the plan, whose approval may let the PR merge with no second ask when it changes nothing outside it.
4. Post in the interview thread that the plan is written and goes to the coordinator now.
5. Run `{{team_bin}}/team-tickets {{task}} --check` and fix each line it names.
6. Send `{{task}} DONE {{task_dir}}/spec.md` to `coordinator`.

Send the coordinator only `DONE`, `BLOCKED`, `PAUSED`, `FAILED` or `INJECTION`: your questions go to Daniel in the thread, never to the coordinator.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
