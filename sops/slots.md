# SOP: the machine's task slots

Built by T98 (2026-10-30), to Daniel's 10 slots on home-pc with one kept for agent-team (Discord 1565310488479273061).
`team-slots --help` is the exact reference: its settings, the count, the rule, the readings and the effective cap; this SOP says why they are so and what to do when a task waits.

## Why a cap and a reserved slot

Each project's pool is its own bound, and nothing totals them: Conventioner's treehouse pool, agent-team's git slots and no-mistakes' each fill on their own, and none reads what else the machine is doing.
So the machine has its own cap on task slots, the most task worktrees held at once across every project: 10 on home-pc, and the laptop's own number in its own file.
One slot of the cap is kept for the reserved project, so the team can improve itself even while other projects' work fills the machine.
The reserved project is the registered project whose primary checkout is the code checkout, `agent-team` on Daniel's team; with no such project, nothing is kept, and `team-slots` says so.
The cap is a ceiling, never raised when the machine is idle; while other programs (a game, a browser, a video call) use enough memory or CPU, the effective cap is lower, so Daniel's desktop stays usable.

## What holds a slot

- Each open worktree in the ledger: opened or added, not returned, of a task not closed, across every project and wherever its path was recorded, since every open task runs on the lease holder.
- Each half-open one: a worktree of a registered project's primary checkout whose branch names a task (`<type>/T<n>-<slug>`) with no closed event and no open worktree of that project in the ledger, so a failed open counts until it is finished.
- Not a closed task's worktree kept with `--keep-worktree`, and not a treehouse slot leased to a task but on no branch, which `team-doctor`'s leases line warns on.
- A task in two projects holds two.

## The rule

With `E` the effective cap, `R` the reserved count, `H` every slot held and `O` those held by projects other than the reserved one:

- the reserved project's task may take a slot while `H < E`;
- any other project's task may take a slot while `H < E` and `O < E - R`.

So the reserved project always has `R` slots, held or free, and a slot it already holds counts toward them, so the others are never held back by more than `R`.
The worked example, at cap 10 and reserved 1:

- Conventioner and no-mistakes hold 9: `O` is 9, not below `10 - 1`, so a Conventioner task is refused, naming the slot kept for agent-team; an agent-team task opens, as the tenth.
- Agent-team holds 1 of those 9: `O` is 8, so a Conventioner task opens as the tenth, and the next of any project waits.
- 10 held: every project waits.

Each project's pool stays its own bound, refused as a full pool, whichever the run meets first.
So that the cap governs, each pool should be at least the share the cap lets its project take, the cap less `reserved` for another project and the whole cap for the reserved one; `team-doctor`'s `slots` line notes each smaller pool as a pass's detail.

## The settings

`~/.config/agent-team/slots.json`, beside `stack.json`, is the machine's own and never moved, so it is not in the team home's `machine/`, which holds what every machine shares.
It is one JSON object whose keys are all optional:

| Key | Default | What it sets |
| - | - | - |
| `cap` | 6 | the most task slots held at once on this machine |
| `reserved` | 1 | the slots kept for the reserved project, less than `cap` |
| `dynamic` | true | whether the readings may lower the cap |
| `task_gib` | 1.25 | the memory one more task needs |
| `reserve_gib` | 6 | the memory kept free beyond the tasks |
| `task_cores` | 0.5 | the CPU one more task needs, in cores |
| `reserve_cores` | 2 | the cores kept free beyond the tasks |
| `window_minutes` | 15 | how far back readings count |
| `wait_minutes` | 15 | how long `team-open` waits for another run's slot lock |

- The number is Daniel's: a new machine's setup session asks for it and writes `{"cap": <n>}` (`sops/machine-setup.md`, stage 2); home-pc's file is `{"cap": 10}`.
- The default 6 is for a machine nobody has set up, and `team-doctor`'s `slots` line warns while the file sets no `cap`, naming the command that writes it.
- A file that is not one JSON object, a key of the wrong kind, an unknown key and a `reserved` not less than `cap` are refused naming each, so a typo never silently keeps a default: `team-open`'s check, `team-slots` and the heartbeat's `slots` step exit 1 with the reason, and `team-doctor` warns.
- `"dynamic": false` keeps the effective cap at `cap`, to rule the sizing out when something looks wrong.
- Change the file only on Daniel's word, never to get a waiting task past a refusal.

## The measure

The heartbeat's `slots` step runs `team-slots sample` on the lease holder every run, every 5 minutes, which appends one reading to `~/.local/state/agent-team/slots/readings.jsonl`, kept for 24 hours.
`team-slots status` and `check` take one first when the newest is more than 10 minutes old; `team-doctor`, `team-snapshot` and `team-sweep` read the stored ones only (`team-slots status --stored`), and never take one.

A reading says what the other programs use, not the team:

- Memory: the total less the available less the team's, never below 0; the team's is the resident memory of its processes and the memory of its team and gate stacks (`team-stack ls --json`).
- CPU: the cores busy since the previous reading's snapshot of each process's CPU seconds, when that snapshot is 60 seconds to 15 minutes old, less the team's processes' and stacks'; with no snapshot in that span, the reading has no CPU, and its fit is memory's alone.
- The team's processes are each one whose working directory is a team path or below one, and every descendant of one, so a test run in `/tmp` that a worker started counts: the team home, the code checkout, every registered project's slots, each held worktree, and `~/.no-mistakes` (the gate's).
- Docker not answering leaves the stacks out, so they count as the others' and the reading says `"docker": false`: the error leans toward a lower cap, never a higher one.

A reading's fit is how many tasks the machine carries beside the other programs, the lower of memory's `floor((total - others - reserve_gib) / task_gib)` and the CPU's `floor((cpus - others - reserve_cores) / task_cores)`, never below 0.

The evidence for the defaults, on home-pc on 2026-10-29: 30.6 GiB of memory and 12 cores; at 18:23, 12.0 GiB available, 8.9 GiB of swap in use, a load average of 3.0, 2.3 and 2.0, CPU pressure (`/proc/pressure/cpu`, some avg300) 0.74 % and no memory pressure.
The coordinator's measure that evening: Claude sessions 0.4 to 0.5 GiB each (32 processes, 5.9 GiB, the claude daemon's spare sessions included), a Conventioner stack 0.3 to 0.8 GiB idle (its `mem_limit`s total 2.75 GiB), one heavy run 4 to 6 GiB, the desktop's programs about 8 GiB, and a load average about 2.

- `task_gib` 1.25: a task runs one or two sessions at a time (about 0.9 GiB) and, for Conventioner, a stack that is mostly idle (about 0.5 GiB), where an agent-team task has none; a stack's limits are still `team-stack up`'s admission's business (`sops/docker.md`).
- `reserve_gib` 6: one heavy run, of which `team-heavy` lets one run at a time, the same as `team-stack`'s Linux memory floor.
- With others at that day's 8 to 11 GiB, the memory fit is `floor((30.6 - 11 - 6) / 1.25)`, 10, so home-pc runs its 10; a game or a second browser taking 7 GiB more makes it 5.
- `task_cores` 0.5 and `reserve_cores` 2: the CPU did not bind that day, so with others near 1 core the CPU fit is 18; a program keeping 6 cores busy makes it 8, and one keeping 9 busy makes it 2.
- The claude daemon's spare sessions count as other programs, since their directory is no team path; they were about 3 GiB of those numbers.
- Pressure stall information was not chosen: it cannot tell the team's load from other programs' (the team's own heavy run would lower its cap), and macOS has none.

## How the effective cap avoids flapping

- A reading's confirmed fit is the higher of its fit and the previous reading's, so a lower number holds only once two readings in a row show it; the first reading ever confirms nothing.
- The effective cap is the lowest confirmed fit of the readings in the last `window_minutes`, at most `cap` and never below the slots kept for the reserved project, whose tasks carry no stack.
- So one spike never lowers it, two readings in a row (5 minutes apart with the heartbeat) lower it at once, and it rises back once that pair is older than the window, 15 minutes by default.
- With `dynamic` false, or no reading in the window, it is `cap`.
- Its reason says what lowered it, memory or CPU, with what the other programs use and the readings' times, or what the latest reading saw.

## Where `team-open` checks

- Every form that would take a new slot from a pool: a new task, a half-open re-run whose branch no slot holds yet, and `--add`.
  It runs `team-slots check <project>` right before taking the slot, under the machine's slot lock, `~/.local/state/agent-team/slots.lock`, held until the slot holds the task's branch, so two runs never take the last slot.
- While another run holds the lock, it says once that it waits and for whom, waits up to `wait_minutes`, then exits 75 naming the holder.
- A half-open re-run whose branch a slot already holds takes no new slot and is not checked.
- `--resume` is never refused by the cap, since its task holds its slot in the ledger already; when the machine holds more slots than its effective cap, it says so on one line and carries on.

## When `team-open` exits 75

Exit 75 is a full pool (or a treehouse lease command that failed), no task slot on the machine, or the slot lock still held after `wait_minutes`; the refusal says which, on stderr, prefixed `team-open: `, a refusal for the cap in this shape:

```
team-open: no task slot for conventioner on home-pc: 9 of 10 held, and the last one is kept for agent-team (reserved 1)
team-open: the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: other programs use 9.8 GiB of 30.6 GiB and 1.1 of 12 cores (the reading of 13:10)
team-open: the slots:
  T90 conventioner in ~/.treehouse/Conventioner-d4c77a/1/Conventioner
  ...
```

1. Tell Daniel which tasks hold the slots (the refusal's list, or `team-slots`), and why the cap is what it is: the configured cap, or the effective one lowered by memory or CPU with what the other programs use, or the slot kept for agent-team.
2. Open the task again with the same command once a slot frees: a task closes, or the effective cap rises back, which `team-slots` shows; nothing queues a refused open, so the retry is yours.
3. A refusal naming the slot lock's holder means another `team-open` is running: run it again once that one ends.

`team-sweep` has a `slots` finding while the effective cap is below `cap` or more slots are held than the effective cap, from the stored readings: tell Daniel which tasks wait, as above.
`team-snapshot` says the summary line after the open tasks, and `team-doctor`'s `slots` line the cap, the effective cap and the latest reading, warning when the readings are stale on the lease holder.

## A lower cap never takes a worktree away

- Only new slots are refused: a running task keeps its worktree and its workers, however low the effective cap goes.
- `team-open --resume` and a half-open re-run that a slot already holds are never refused, so a failed open can always be finished.
- A handoff to a machine with a lower cap re-homes every open task anyway, each `team-open --resume` saying the machine is over its effective cap, and no new task opens there until enough close to bring it under (`sops/portability.md`).
