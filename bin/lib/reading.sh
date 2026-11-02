# One reading of the machine's load, as team-capacity sample takes it: the memory, the processes
# with their working directories, the team's processes by directory and descent, and the team's
# stacks (team-capacity --help says what it reads and writes).
# Sourced after the library: source "$TEAM_LIB/reading.sh". It provides:
#   reading_context   sets CODE (the code checkout, or the primary checkout of the one it is a
#                     linked worktree of), projects (the registered projects, one per line),
#                     worktrees (every registered project's linked worktrees, a JSON array of
#                     {project, branch, worktree}) and ledger (the ledger, or /dev/null)
#   READING_HELD      the jq program of the worktrees held, from the ledger as raw lines,
#                     $worktrees and $home (held_worktrees in capacity.jq)
#   take_reading <dir> <build>
#                     takes the reading into <dir>/readings.jsonl (kept to the last 24 hours, a
#                     broken line dropped), its CPU snapshot <dir>/procs.tsv and its lock
#                     <dir>/sample.lock, as the headers say; within 60 seconds of the newest
#                     reading it appends nothing. <build> is a function that prints the line to
#                     append, called with $work holding in.json (machine_reading's input) and
#                     held.json (the worktrees held, each resolved), and $now the time.
# Test seams: TEAM_MEMINFO, TEAM_READING_PROCS (its lines may carry a sixth column, the process's
# cgroup v2 path), TEAM_READING_CPUS and TEAM_READING_DOCKER_SECONDS, as team-capacity --help
# says.
# shellcheck shell=bash

READING_HELD='include "ledger"; include "capacity"; include "stack"; ledger_events as $events | ($events | by_task) as $tasks
  | held_worktrees($tasks; [open_worktrees($events[] | select($tasks[.task] | is_open); $home)]; $worktrees)'

reading_context() {
  local common project primary
  CODE=$(dirname "$(dirname "$TEAM_LIB")")
  if common=$(git -C "$CODE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    [[ $(basename "$common") == .git ]]; then
    CODE=$(dirname "$common")
  fi
  projects=$(team_project --list)
  # Every registered project's linked worktrees, but its primary checkout, each {project, branch,
  # worktree} (branch "" when detached), from its git worktree list; a primary checkout that is
  # not a git checkout has none.
  worktrees=$(
    while IFS= read -r project; do
      [[ -n $project ]] || continue
      primary=$(team_project "$project" path)
      git -C "$primary" worktree list --porcelain 2>/dev/null | awk -v project="$project" '
        function out() { if (n++ > 0) printf "%s\t%s\t%s\n", project, branch, path }
        /^worktree / { if (path != "") out(); path = substr($0, 10); branch = "" }
        /^branch refs\/heads\// { branch = substr($0, 19) }
        END { if (path != "") out() }' || true
    done <<<"$projects" | jq -Rn '[inputs | split("\t") | {project: .[0], branch: .[1], worktree: .[2]}]'
  )
  ledger=$TEAM_HOME/ledger.jsonl
  [[ -e $ledger ]] || ledger=/dev/null
}

# The last line <command> said on stderr ($work/err), or "no reason given".
said() {
  grep . "$work/err" 2>/dev/null | tail -n 1 | grep . || echo "no reason given"
}

# The processes as TEAM_READING_PROCS gives them, one per line, tab-separated: pid, parent pid,
# resident KiB, cumulative CPU seconds, working directory (empty when it cannot be read) and
# cgroup (empty when not read), from ps, the working directories in $work/cwds and the cgroups in
# $work/cgroups, one "<pid><TAB><value>" per line each.
ps_procs() {
  ps -A -o pid=,ppid=,rss=,time= 2>"$work/err" >"$work/ps" || die "ps -A -o pid=,ppid=,rss=,time= failed: $(said)"
  awk -F '\t' -v cwds="$work/cwds" -v cgroups="$work/cgroups" '
    # ps time, [[dd-]hh:]mm:ss[.ff] (macOS: mm:ss.ff, its minutes past 59), in whole seconds.
    function seconds(time,   days, n, part, i, total) {
      days = 0
      if (index(time, "-")) { days = substr(time, 1, index(time, "-") - 1); time = substr(time, index(time, "-") + 1) }
      n = split(time, part, ":")
      total = 0
      for (i = 1; i <= n; i++) total = total * 60 + part[i]
      return int(days * 86400 + total)
    }
    FILENAME == cwds { cwd[$1] = $2; next }
    FILENAME == cgroups { cgroup[$1] = $2; next }
    {
      n = split($0, f, " ")
      if (n != 4 || f[1] !~ /^[0-9]+$/ || f[2] !~ /^[0-9]+$/ || f[3] !~ /^[0-9]+$/ || f[4] !~ /^([0-9]+-)?[0-9:.]+$/) {
        line = $0; sub(/^ +/, "", line); print line > "/dev/stderr"; exit 1
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], seconds(f[4]), cwd[f[1]], cgroup[f[1]]
    }' "$work/cwds" "$work/cgroups" "$work/ps" 2>"$work/err" ||
    die "ps -A -o pid=,ppid=,rss=,time= printed a line that is no process: $(said)"
}

# The working directories and cgroups on Linux, from /proc/<pid>/cwd and /proc/<pid>/cgroup's
# cgroup v2 line (empty when they cannot be read).
linux_cwds() {
  find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%h\t%l\n' 2>/dev/null | sed 's#^/proc/##' >"$work/cwds" || true
  grep -s -H '^0::' /proc/[0-9]*/cgroup 2>/dev/null | sed -E 's#^/proc/([0-9]+)/cgroup:0::#\1\t#' >"$work/cgroups" || true
}

# The working directories on macOS, from lsof's p (pid) and n (name) fields; a process lsof
# cannot read is not listed, and a name that is no absolute path is no directory. macOS has no
# cgroups.
macos_cwds() {
  : >"$work/cgroups"
  lsof -a -d cwd -Fpn 2>"$work/err" >"$work/lsof" || die "lsof -a -d cwd -Fpn failed: $(said)"
  awk '
    /^p[0-9]+$/ { pid = substr($0, 2); next }
    /^f/ && pid != "" { next }
    /^n/ && pid != "" { if (substr($0, 2, 1) == "/") printf "%s\t%s\n", pid, substr($0, 2); next }
    { print > "/dev/stderr"; exit 1 }' "$work/lsof" >"$work/cwds" 2>"$work/err" ||
    die "lsof -a -d cwd -Fpn printed a line that is no process or directory: $(said)"
}

# The memory on macOS, "<total> <available>" in bytes: sysctl's hw.memsize, and vm_stat's free,
# inactive, speculative and purgeable pages times its page size.
macos_memory() {
  local total available
  total=$(sysctl -n hw.memsize 2>"$work/err") || die "sysctl -n hw.memsize failed: $(said)"
  [[ $total =~ ^[0-9]+$ ]] || die "sysctl -n hw.memsize printed no memory size: $total"
  vm_stat 2>"$work/err" >"$work/vm_stat" || die "vm_stat failed: $(said)"
  available=$(awk '
    /^Mach Virtual Memory Statistics: \(page size of [0-9]+ bytes\)/ { match($0, /[0-9]+/); size = substr($0, RSTART, RLENGTH) }
    /^Pages (free|inactive|speculative|purgeable):/ {
      count = $NF; sub(/\.$/, "", count)
      if (count !~ /^[0-9]+$/) { bad = 1; exit }
      pages += count; if (!($2 in seen)) { seen[$2]; kinds++ }
    }
    END { if (bad || size == "" || kinds != 4) exit 1; printf "%.0f\n", pages * size }' "$work/vm_stat") ||
    die "vm_stat printed no page size and free, inactive, speculative and purgeable pages"
  echo "$total $available"
}

# Take one reading of the machine's load into <dir>, its line printed by <build>, as the header
# says: take_reading <dir> <build>
take_reading() {
  local dir=$1 build=$2 readings=$1/readings.jsonl snapshot=$1/procs.tsv
  local os meminfo memory total available cpus age previous=null stacks=null line facts project
  local -a registered
  mkdir -p "$dir"
  exec {sample_fd}>>"$dir/sample.lock"
  flock -w 60 "$sample_fd" || die "another reading is still being taken after 60 seconds"
  now=$(date +%s)
  if [[ -e $readings ]] && jq -Rne -L "$TEAM_LIB" --argjson now "$now" \
    'include "capacity"; include "stack"; [inputs] | stored_readings | .readings[-1].at // empty | fromdateiso8601 > $now - 60' \
    "$readings" >/dev/null; then
    return 0
  fi
  case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "no reading of the machine's load on $(uname -s)" ;;
  esac
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [[ $os == linux || -n ${TEAM_MEMINFO:-} ]]; then
    meminfo=${TEAM_MEMINFO:-/proc/meminfo}
    read -r total available < <(awk '$1 == "MemTotal:" { total = $2 * 1024 } $1 == "MemAvailable:" { available = $2 * 1024 }
      END { if (total == "" || available == "") exit 1; printf "%.0f %.0f\n", total, available }' "$meminfo" 2>/dev/null) ||
      die "no MemTotal and MemAvailable in $meminfo"
  else
    memory=$(macos_memory) || exit 1
    read -r total available <<<"$memory"
  fi
  cpus=${TEAM_READING_CPUS:-$(nproc)}

  if [[ -n ${TEAM_READING_PROCS:-} ]]; then
    cp "$TEAM_READING_PROCS" "$work/procs"
  else
    "${os}_cwds"
    ps_procs >"$work/procs"
  fi
  jq -Rn '[inputs | select(test("\\S")) | split("\t")
    | {pid: (.[0] | tonumber), ppid: (.[1] | tonumber), rss: (.[2] | tonumber), seconds: (.[3] | tonumber), cwd: (.[4] // ""),
       cgroup: (.[5] // "")}]' \
    "$work/procs" >"$work/procs.json" 2>"$work/err" ||
    die "the processes are malformed: $(grep -m1 . "$work/err" || echo "jq could not read them")"

  # The worktrees held, each resolved.
  jq -nR -L "$TEAM_LIB" --arg home "$HOME" --argjson worktrees "$worktrees" "$READING_HELD" "$ledger" >"$work/held-given.json"
  jq -r '.[].worktree' "$work/held-given.json" | while IFS= read -r path; do realpath -m -- "$path"; done |
    jq -Rn '[inputs]' >"$work/held-paths.json"
  jq -c --slurpfile paths "$work/held-paths.json" '[to_entries[] | .value + {worktree: $paths[0][.key]}]' \
    "$work/held-given.json" >"$work/held.json"

  # The team paths: the team home, the code checkout, every registered project's slots, each
  # held worktree, and the gate's ~/.no-mistakes.
  {
    printf '%s\n' "$TEAM_HOME" "$(dirname "$TEAM_LIB")/.." "$CODE" "$HOME/.no-mistakes"
    while IFS= read -r project; do
      [[ -n $project ]] || continue
      facts=$(team_project "$project")
      mapfile -t registered < <(jq -r '.pool.slots[]' <<<"$facts")
      if [[ $(jq -r .pool.provider <<<"$facts") == treehouse ]]; then
        treehouse_slots "${registered[@]}"
      else
        printf '%s\n' "${registered[@]}"
      fi
    done <<<"$projects"
    jq -r '.[].worktree' "$work/held.json"
  } | while IFS= read -r path; do
    [[ -z $path ]] || realpath -m -- "$path"
  done | jq -Rn '[inputs | select(. != "/")] | unique' >"$work/paths.json"

  # The team and gate stacks, from team-stack; Docker not answering in time leaves them out.
  # timeout runs it in a process group of its own, so a signal that stops this run (the
  # heartbeat's own time limit) is passed on to it, and through it to what it started.
  TEAM_HOME=$TEAM_HOME timeout --kill-after=5 "${TEAM_READING_DOCKER_SECONDS:-30}" \
    "$(dirname "$TEAM_LIB")/team-stack" ls --json >"$work/stacks.json" 2>/dev/null &
  stack_pid=$!
  trap 'kill -TERM "$stack_pid" 2>/dev/null; exit 143' TERM INT HUP
  if wait "$stack_pid"; then stacks=$(jq -c . "$work/stacks.json"); fi
  trap - TERM INT HUP

  # The previous snapshot of the processes' CPU, when it is 60 seconds to 15 minutes old.
  if [[ -e $snapshot ]]; then
    age=$((now - $(date -r "$snapshot" +%s)))
    if ((age >= 60 && age <= 900)); then
      previous=$(jq -Rnc --argjson seconds "$age" \
        '{seconds: $seconds, procs: ([inputs | split("\t") | select(length >= 2) | {key: .[0], value: (.[1] | tonumber)}] | from_entries)}' \
        "$snapshot")
    fi
  fi

  jq -nc --arg at "$(date -u -d "@$now" +%FT%TZ)" --argjson total "$total" \
    --argjson available "$available" --argjson cpus "$cpus" --slurpfile procs "$work/procs.json" \
    --slurpfile paths "$work/paths.json" --argjson stacks "$stacks" --argjson previous "$previous" --arg os "$os" \
    '{at: $at, os: $os, total: $total, available: $available, cpus: $cpus, procs: $procs[0], paths: $paths[0],
      stacks: $stacks, previous: $previous}' >"$work/in.json"
  line=$("$build") || exit 1
  {
    [[ ! -e $readings ]] || jq -Rc -L "$TEAM_LIB" --argjson since $((now - 86400)) \
      'include "capacity"; include "stack"; try fromjson catch null | select(well_formed_reading and (.at | fromdateiso8601) >= $since)' "$readings"
    printf '%s\n' "$line"
  } >"$readings.$$"
  mv -f "$readings.$$" "$readings"
  awk -F '\t' 'NF >= 4 { print $1 "\t" $4 }' "$work/procs" >"$snapshot.$$"
  mv -f "$snapshot.$$" "$snapshot"
}
