# A task's tickets for the tests of team-tickets: load it with `load helpers/tickets` after
# `load helpers/common`, and call `tickets_sandbox` from `setup` after `sandbox`.
#
# tickets_sandbox writes a registry of two projects, proj (task_dir .scratch/task) and other
# (task_dir .work/task), and opens T172 on proj ("toil") in the worktree $wt, whose task directory
# is $task_dir and ticket directory $tickets, made empty; the helpers below write its tickets and
# its ledger.
# shellcheck shell=bash

tickets_sandbox() {
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["projects/proj-slots/1"]

[other]
repo = "owner/other"
path = "projects/other"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".work/task"
docs = []
toolkits = []

[other.pool]
provider = "git"
slots = ["projects/other-slots/1"]
TOML
  wt=$BATS_TEST_TMPDIR/wt
  task_dir=$wt/.scratch/task
  tickets=$task_dir/tickets
  mkdir -p "$tickets"
  event T172 opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "toil",
    branch: "feat/T172-toil", base: "dev", base_sha: "aba9d074", worktree: $wt}')"
}

# event <task> <kind> '<jq object of the other fields>' [<ts>]: append one ledger line, at <ts>
# when given, else at 2026-11-01T10:00:00Z.
event() {
  jq -cn --arg task "$1" --arg event "$2" --arg ts "${4:-2026-11-01T10:00:00Z}" \
    "{ts: \$ts, task: \$task, event: \$event} + $3" >>"$TEAM_HOME/ledger.jsonl"
}

# ticket_done [--at <ts>] <NN>...: a ticket-done of each, at <ts> when given.
ticket_done() {
  local n at=''
  if [[ ${1:-} == --at ]]; then at=$2; shift 2; fi
  for n in "$@"; do
    event T172 ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["1f2f4a1"]}')" "$at"
  done
}

# build_launch <NN> <session> [<ts>]: a builder's launch on brief-build-<NN>, at <ts> when given.
build_launch() {
  event T172 launch "$(jq -cn --arg b "brief-build-$1" --arg s "$2" --arg wt "$wt" \
    '{role: "builder", session: $s, worktree: $wt, toolkits: [], brief: $b}')" "${3:-}"
}

# ticket <NN-slug> <lines>...: write a ticket file of those lines under a title.
ticket() {
  printf '%s\n' "# ${1%%-*}: ${1#*-}" "" "${@:2}" "" "- [ ] it works" >"$tickets/$1.md"
}

# A fresh ticket set of the given files only.
fresh_tickets() {
  rm -f "$tickets"/*.md
}
