#!/usr/bin/env bats
# hooks/command-guard's kill rows (bin/lib/kill_rules.py): a kill by name or pattern, tmux's
# kill-*, a kill of PIDs read from input, of a PID the guard cannot read before it runs, and of a
# process group, every process or PID 0 or 1 are refused wherever a command runs (behind a
# wrapper, in a string a shell or eval runs, in a heredoc or here-string a shell reads, piped into
# a shell), each naming its allowed way with a worker's suffix or a gate agent's; the session's own
# jobs, signal 0, kill -l and the reads, commits and data that only name a kill pass; and a literal
# PID passes only when its process is gone, or is the user's, is not the hook's own session or an
# ancestor of it, and works inside the worktree or the job's tmp, each proven on real processes.

load helpers/common

# Each test's worktree (CLAUDE_PROJECT_DIR), job tmp ($CLAUDE_JOB_DIR/tmp), a directory outside
# both and a sibling of the worktree whose name starts with the worktree's, and the PIDs it started.
setup() {
  sandbox
  WT=$BATS_TEST_TMPDIR/worktree JOB=$BATS_TEST_TMPDIR/job OUT=$BATS_TEST_TMPDIR/outside
  mkdir -p "$WT/src" "$JOB/tmp" "$OUT" "$WT-other"
  export CLAUDE_PROJECT_DIR=$WT CLAUDE_JOB_DIR=$JOB
  PIDS=()
}

# Each process a test started, killed by the PID it noted.
teardown() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}

# Start <program> (sleep by default) for 300 seconds with <dir> as its working directory, its
# output and bats' fd 3 closed, noting its PID as STARTED and in PIDS: started <dir> [<program>]
started() {
  local here=$PWD
  cd -- "$1" || return
  "${2:-sleep}" 300 </dev/null >/dev/null 2>&1 3>&- &
  STARTED=$!
  PIDS+=("$STARTED")
  cd -- "$here" || return
}

# The PID of a process that has ended, as GONE.
ended() {
  (exit 0) &
  GONE=$!
  wait "$GONE"
}

KILL_WAY="find your own process's PID (pgrep -af <pattern>, or the \$! you noted when you started it) and kill that literal PID in a call of its own, which passes when the process is yours and its working directory is inside your worktree or your job's tmp"
READ_WAY="read the PID first (pgrep -af, ps -o pid,args), then kill that literal PID in a call of its own; your own jobs (\$!, %1, \$(jobs -p)) pass as they are"
BY_NAME="which reaches every task's processes and the team's own sessions"
UNREAD="a PID the guard cannot read before it runs (a variable or a substitution)"
GROUP="a process group, every process or PID 0 or 1"

# The hook on a Bash call of <command>, as Claude Code sends it: guard <status> <command>
guard() {
  run_bin "$1" --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$2" \
    '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: "Bash", tool_input: {command: $c}}')"
}

# The hook refuses each <command> with <reason> and <allowed> way, as a gate agent sees it (no
# AGENT_TEAM_ROLE): refuses <reason> <allowed> <command>...
refuses() {
  local reason=$1 allowed=$2 command
  shift 2
  for command; do
    guard -2 "$command"
    [[ $stderr == "Blocked by command-guard: $reason; the allowed way: $allowed. A guardrail: do not reach it another way." ]] ||
      { printf 'not refused with: %s\ncommand: %s\nstderr: %s\n' "$reason" "$command" "$stderr" >&2; return 1; }
  done
}

# Neither the hook nor the worker deny list refuses each <command>: passes <command>...
passes() {
  local command
  for command; do
    guard -0 "$command"
    [[ -z $stderr ]] || { printf 'stderr for %s: %s\n' "$command" "$stderr" >&2; return 1; }
    if denied_in "$REPO_ROOT/settings/worker.json" "$command"; then echo "settings/worker.json denies: $command" >&2; return 1; fi
  done
}

# Each form of a simple <command> (holding no single quote) the hook must read alike: itself, in a
# shell's -c string, eval's string, a heredoc and a here-string a shell reads, piped into a shell,
# and behind sudo, env and nohup, one per line of FORMS: wrapped <command>
wrapped() {
  FORMS=("$1" "bash -c '$1'" "eval '$1'" $'bash <<\'EOF\'\n'"$1"$'\nEOF' "bash <<< '$1'" "echo '$1' | bash"
    "sudo $1" "env A=1 $1" "nohup $1")
}

# The hook refuses <command> in each of its wrapped forms: refuses_wrapped <reason> <allowed> <command>
refuses_wrapped() {
  wrapped "$3"
  refuses "$1" "$2" "${FORMS[@]}"
}

@test "a kill by name or pattern is refused, by any path, quoted, behind a wrapper or in a string a shell runs" {
  local name
  for name in pkill killall killall5 skill; do
    refuses_wrapped "a kill by name or pattern ($name), $BY_NAME" "$KILL_WAY" "$name -f vite"
  done
  refuses "a kill by name or pattern (pkill), $BY_NAME" "$KILL_WAY" "/usr/bin/pkill -f claude" '"pkill" -f bats-core' \
    "'pkill' -f x" "timeout 5 pkill x" "xargs -r pkill < names" "command pkill x"
  refuses "a kill by name or pattern (killall), $BY_NAME" "$KILL_WAY" "killall node" "/usr/bin/killall -9 node"
  # A line the code text adds with an open quote hides no line a shell reads after it.
  refuses "a kill by name or pattern (pkill), $BY_NAME" "$KILL_WAY" "bash <<< \"echo it's\"; bash <<< 'pkill x'" \
    "bash <<< 'pkill x; find . -exec true {} +'"
  refuses_wrapped "a kill by name or pattern (fuser -k), $BY_NAME" "$KILL_WAY" "fuser -k 5173/tcp"
  refuses "a kill by name or pattern (fuser -k), $BY_NAME" "$KILL_WAY" "fuser --kill 5173/tcp" "fuser -km /mnt" \
    "fuser -v -k -n tcp 8080"
}

@test "tmux's kill-* is refused, with or without -L or -S" {
  local word
  for word in kill-server kill-session kill-window kill-pane; do
    refuses_wrapped "tmux $word, which reaches other sessions' terminals and the team's own" "$KILL_WAY" "tmux $word"
    refuses "tmux $word, which reaches other sessions' terminals and the team's own" "$KILL_WAY" \
      "tmux -L work $word" "tmux -S /tmp/sock $word -t x"
  done
  refuses "tmux killp, which reaches other sessions' terminals and the team's own" "$KILL_WAY" "tmux killp -t 1"
  refuses "tmux killw, which reaches other sessions' terminals and the team's own" "$KILL_WAY" "tmux killw"
}

@test "a kill of PIDs read from input is refused: xargs kill, parallel kill and find -exec kill" {
  refuses_wrapped "a kill of PIDs read from input (xargs kill), which the guard cannot read before it runs" "$READ_WAY" \
    "xargs kill < pids"
  refuses "a kill of PIDs read from input (xargs kill), which the guard cannot read before it runs" "$READ_WAY" \
    'pgrep -f "vite preview --outDir" | xargs -r kill' "pgrep x | xargs -r kill" "pgrep x | xargs -I{} kill -9 {}" \
    "pgrep x | xargs sudo kill" "pgrep x | xargs sh -c 'kill \$1' _" "ps -o pid= | xargs -n1 kill -TERM"
  refuses_wrapped "a kill of PIDs read from input (parallel kill), which the guard cannot read before it runs" "$READ_WAY" \
    "parallel kill ::: 1 2"
  refuses_wrapped "a kill of PIDs read from input (find -exec kill), which the guard cannot read before it runs" "$READ_WAY" \
    "find /proc -maxdepth 1 -name 1 -exec kill {} +"
  refuses "a kill of PIDs read from input (find -exec kill), which the guard cannot read before it runs" "$READ_WAY" \
    "find . -name pid -execdir kill {} \\;" "find . -okdir kill {} \\;"
}

@test "a kill of a PID the guard cannot read is refused: a substitution or a variable not set from \$!" {
  refuses_wrapped "a kill of \$(pgrep -f x), $UNREAD" "$READ_WAY" "kill \$(pgrep -f x)"
  refuses_wrapped "a kill of \`pgrep x\`, $UNREAD" "$READ_WAY" "kill \`pgrep x\`"
  refuses_wrapped "a kill of \$PID, $UNREAD" "$READ_WAY" "kill \$PID"
  refuses "a kill of \$(pgrep -f x), $UNREAD" "$READ_WAY" 'kill -9 "$(pgrep -f x)"' "builtin kill \$(pgrep -f x)" \
    "command kill -s TERM \$(pgrep -f x)"
  refuses "a kill of \$P, $UNREAD" "$READ_WAY" "P=5; kill \$P" "kill \$P; sleep 9 & P=\$!" "P=\$!; read P; kill \$P" \
    "P=\$!; P+=1; kill \$P" "for P in 1 2; do kill \$P; done" "P=\$!; : \${P:=1}; kill \$P" "P='\$!'; kill \$P"
  refuses "a kill of \${P}, $UNREAD" "$READ_WAY" "kill \${P}"
}

@test "a kill of a process group, every process or PID 0 or 1 is refused" {
  refuses_wrapped "a kill of -123, $GROUP" "$KILL_WAY" "kill -9 -- -123"
  refuses_wrapped "a kill of -123, $GROUP" "$KILL_WAY" "kill -TERM -123"
  refuses_wrapped "a kill of 0, $GROUP" "$KILL_WAY" "kill 0"
  refuses_wrapped "a kill of -1, $GROUP" "$KILL_WAY" "kill -1"
  refuses_wrapped "a kill of 1, $GROUP" "$KILL_WAY" "kill 1"
  refuses "a kill of -1, $GROUP" "$KILL_WAY" "kill -9 -1" "kill -s KILL -1" "kill -- -1" "/bin/kill -9 -1"
  refuses "a kill of 1, $GROUP" "$KILL_WAY" "kill -9 4242 1"
}

@test "the session's own jobs, signal 0, kill -l and an ended PID pass, and so does what only names a kill" {
  ended
  passes "kill \$!" "kill -9 \${!}" "kill \"\$!\"" "P=\$!; kill \$P" "sleep 300 & P=\"\$!\"; kill \"\${P}\"" \
    "sleep 1 & local P=\$!; kill -TERM \$P" "kill %1" "kill -9 %%" "kill \$(jobs -p)" "kill -- \"\$(jobs -p)\"" \
    "kill \`jobs -p\`" "kill \$\$" "kill -0 \$X" "kill -0 1" "kill -s 0 \$(pgrep x)" "kill -n 0 -1" "kill -l" "kill -l 9" \
    "kill -L" "kill $GONE" "kill -9 $GONE" "kill -s TERM -- $GONE" "kill" "kill -TERM"
  passes "pgrep -af vite" "ps -o pid,args" "tmux ls" "tmux new-session -d -s work" "fuser 5173/tcp" \
    "fuser -v -n tcp 8080" "git rm -r old" "rm -f x"
  passes 'git commit -m "fix: refuse pkill -f and kill -9 -1"' "grep -rn 'pkill -f' docs" \
    "git log -S'xargs kill' --oneline" $'cat > notes.md <<\'EOF\'\npkill -f x\nkill -9 -1\ntmux kill-server\nEOF' \
    "echo 'killall node' > notes.md" "rg -n 'kill \$(pgrep' ."
}

@test "a refusal with an allowed way tells a worker to report it and go on by it, and a gate agent not to reach it another way" {
  AGENT_TEAM_ROLE=builder guard -2 "pkill -f vite"
  assert_equal "$stderr" "Blocked by command-guard: a kill by name or pattern (pkill), $BY_NAME; the allowed way: $KILL_WAY. A guardrail: report it as BLOCKED, saying you took the allowed way, and go on only by that way."
  guard -2 "pkill -f vite"
  assert_equal "$stderr" "Blocked by command-guard: a kill by name or pattern (pkill), $BY_NAME; the allowed way: $KILL_WAY. A guardrail: do not reach it another way."
  # A row with no allowed way keeps its suffix, with a role or without.
  local today="Blocked by command-guard: the coordinator's commands (team-ask, team-answer, team-inbox, team-thread T<n> and team-run-approved); a guardrail, so report it as BLOCKED and do not reach it another way."
  AGENT_TEAM_ROLE=builder guard -2 "team-inbox"
  assert_equal "$stderr" "$today"
  guard -2 "team-inbox"
  assert_equal "$stderr" "$today"
}

@test "a kill comes after the existing rows, so a call with both names the earlier row" {
  guard -2 "pkill -f x; team-inbox"
  assert_equal "$stderr" "Blocked by command-guard: the coordinator's commands (team-ask, team-answer, team-inbox, team-thread T<n> and team-run-approved); a guardrail, so report it as BLOCKED and do not reach it another way."
  guard -2 "kill \$P; pkill x"
  assert_equal "$stderr" "Blocked by command-guard: a kill by name or pattern (pkill), $BY_NAME; the allowed way: $KILL_WAY. A guardrail: do not reach it another way."
}

NOT_YOURS="which is not yours to stop"
LITERAL_WAY="kill only a process you started whose working directory is inside your worktree or your job's tmp, and leave the rest to their owner"
UNPROVEN="its owner or working directory cannot be read, so it is not proven yours"

@test "a literal PID passes when its process works inside the worktree or the job's tmp, or has ended" {
  started "$WT"
  local root=$STARTED
  started "$WT/src"
  local sub=$STARTED
  started "$JOB/tmp"
  local job=$STARTED
  ended
  passes "kill $root" "kill -9 $sub" "kill -TERM $job" "kill -s KILL -- $root $sub $job" "kill $GONE" \
    "sleep 1; kill $sub" "bash -c 'kill $job'" "kill -9 0$root"
}

@test "a literal PID whose process works outside the worktree and the job's tmp is refused, naming its directory" {
  started "$OUT"
  local out=$STARTED
  started "$WT-other"
  local sibling=$STARTED
  started "$WT"
  refuses_wrapped "a kill of PID $out, $NOT_YOURS: its working directory, $OUT, is outside your worktree and your job's tmp" \
    "$LITERAL_WAY" "kill $out"
  refuses "a kill of PID $out, $NOT_YOURS: its working directory, $OUT, is outside your worktree and your job's tmp" \
    "$LITERAL_WAY" "kill $STARTED $out" "kill -9 -- $out" "/bin/kill -s TERM $out"
  refuses "a kill of PID $sibling, $NOT_YOURS: its working directory, $WT-other, is outside your worktree and your job's tmp" \
    "$LITERAL_WAY" "kill $sibling"
  AGENT_TEAM_ROLE=builder guard -2 "kill $out"
  assert_equal "$stderr" "Blocked by command-guard: a kill of PID $out, $NOT_YOURS: its working directory, $OUT, is outside your worktree and your job's tmp; the allowed way: $LITERAL_WAY. A guardrail: report it as BLOCKED, saying you took the allowed way, and go on only by that way."
}

@test "with no worktree and no job tmp, a live literal PID of the user's is refused as outside" {
  unset CLAUDE_PROJECT_DIR CLAUDE_JOB_DIR
  started "$WT"
  refuses "a kill of PID $STARTED, $NOT_YOURS: its working directory, $WT, is outside your worktree and your job's tmp" \
    "$LITERAL_WAY" "kill $STARTED"
}

@test "the hook's own session and the shells it runs in are refused, wherever they work" {
  cd -- "$WT"
  refuses "a kill of PID $$, $NOT_YOURS: your own session or its shell" "$LITERAL_WAY" "kill $$" "kill -9 $$"
  refuses "a kill of PID $BASHPID, $NOT_YOURS: your own session or its shell" "$LITERAL_WAY" "kill $BASHPID"
  refuses "a kill of PID $PPID, $NOT_YOURS: your own session or its shell" "$LITERAL_WAY" "kill $PPID"
}

@test "another user's process is refused, and PID 1 as PID 1" {
  refuses "a kill of 1, a process group, every process or PID 0 or 1" \
    "find your own process's PID (pgrep -af <pattern>, or the \$! you noted when you started it) and kill that literal PID in a call of its own, which passes when the process is yours and its working directory is inside your worktree or your job's tmp" \
    "kill 1" "kill -9 -- 1"
  [[ $(id -u) != 0 ]] || skip "run as root, every process is the user's"
  local root
  root=$(ps -A -o pid=,uid= | awk '$2 == 0 && $1 > 1 { print $1; exit }')
  [[ -n $root ]] || skip "no process of root's but PID 1 to try"
  refuses "a kill of PID $root, $NOT_YOURS: another user's" "$LITERAL_WAY" "kill $root" "kill -TERM $root"
}

@test "a PID too large for a process id is refused as unproven" {
  refuses "a kill of PID 4294967297, $NOT_YOURS: $UNPROVEN" "$LITERAL_WAY" "kill 4294967297" "/bin/kill -9 4294967297"
  refuses "a kill of PID 2147483648, $NOT_YOURS: $UNPROVEN" "$LITERAL_WAY" "kill 2147483648"
}

@test "on Linux, a process whose working directory cannot be read is refused as unproven" {
  [[ $(uname) == Linux ]] || skip "Linux reads /proc; the macOS case is lsof's"
  # A program the user may run but not read makes its process undumpable, so its /proc/<pid>/cwd
  # is the kernel's to read, not the user's.
  mkdir "$BATS_TEST_TMPDIR/bin"
  cp "$(command -v sleep)" "$BATS_TEST_TMPDIR/bin/sleep"
  chmod 111 "$BATS_TEST_TMPDIR/bin/sleep"
  started "$WT" "$BATS_TEST_TMPDIR/bin/sleep"
  local tries=0
  while readlink "/proc/$STARTED/cwd" >/dev/null 2>&1 && ((tries++ < 100)); do sleep 0.05; done
  refuses "a kill of PID $STARTED, $NOT_YOURS: $UNPROVEN" "$LITERAL_WAY" "kill $STARTED"
}

@test "on macOS, a process lsof cannot read the working directory of is refused as unproven" {
  [[ $(uname) == Darwin ]] || skip "macOS reads a working directory with lsof; Linux reads /proc"
  started "$WT"
  stub_command lsof
  stub_reply lsof "" 1
  refuses "a kill of PID $STARTED, $NOT_YOURS: $UNPROVEN" "$LITERAL_WAY" "kill $STARTED"
}

# kill_rules.proof(<pid>, the worktree and job tmp) as macOS reads it (ps and lsof), on any OS,
# with PATH holding only the machine's ps and <dir>: proof_as_macos <pid> <dir>
proof_as_macos() {
  run --separate-stderr env PATH="$2" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import kill_rules
kill_rules.PLATFORM = "darwin"
print(kill_rules.proof(int(sys.argv[2]), (sys.argv[3], sys.argv[4])))
' "$REPO_ROOT/bin/lib" "$1" "$WT" "$JOB/tmp"
}

@test "macOS's reading, ps and lsof, proves a process inside, refuses one outside and one lsof cannot read, on any OS" {
  local bin=$BATS_TEST_TMPDIR/macos-bin
  mkdir "$bin"
  ln -s "$(command -v ps)" "$bin/ps"
  ln -s "$(command -v python3)" "$bin/python3"
  started "$OUT"
  local out=$STARTED
  started "$WT/src"
  # lsof's -Fn fields for the asked PID: p<pid>, fcwd, n<directory>, the directory each test's
  # started process has, by its PID.
  printf '%s\n' "#!$BASH" 'pid=${3:?}' 'echo "p$pid"' 'echo fcwd' \
    "[[ \$pid == $out ]] && echo n$OUT || echo n$WT/src" >"$bin/lsof"
  chmod +x "$bin/lsof"
  proof_as_macos "$STARTED" "$bin"
  assert_equal "$output" "None"
  proof_as_macos "$out" "$bin"
  assert_equal "$output" "its working directory, $OUT, is outside your worktree and your job's tmp"
  ended
  proof_as_macos "$GONE" "$bin"
  assert_equal "$output" "None"
  printf '%s\n' "#!$BASH" "exit 1" >"$bin/lsof"
  proof_as_macos "$STARTED" "$bin"
  assert_equal "$output" "$UNPROVEN"
  rm "$bin/lsof"
  proof_as_macos "$STARTED" "$bin"
  assert_equal "$output" "$UNPROVEN"
}

# A name split by quotes or a backslash, a brace list, ANSI-C quoting or a script that printf or
# echo decodes is the name Bash runs.
@test "a kill by name spelled with quotes, a backslash, a brace list, ANSI-C quoting or in a decoded script is refused" {
  refuses "a kill by name or pattern (pkill), $BY_NAME" "$KILL_WAY" "pk''ill -f vite" '"pk"ill -f vite' \
    'pk\ill -f vite' "{pkill,-f,vite}" "pk{i,}ll -f vite" "{sudo,pkill,x}" "sudo {pkill,-f,x}" \
    "x=1; {pkill,-f,vite}" "\$'\\x70kill' -f vite" "\$'\\160kill' -f vite" "\$'pk'ill -f vite" \
    "printf 'pk%sll -f vite\\n' i > x.sh; bash x.sh" "printf '\\x70kill -f vite\\n' > x.sh; bash x.sh" \
    "echo -e '\\x70kill -f vite' > x.sh; bash x.sh"
  refuses "a kill by name or pattern (killall), $BY_NAME" "$KILL_WAY" "k\\illall node" "{killall,node}"
  refuses "tmux kill-server, which reaches other sessions' terminals and the team's own" "$KILL_WAY" \
    "tm''ux kill-server" "{tmux,kill-server}"
  passes "echo {pkill,x}" "printf 'pk%sll -f vite\\n' i > notes.md" "echo \$'\\x70kill' > notes.md"
}

@test "a PID word Bash reads as 0 or 1 is refused as one" {
  refuses "a kill of 00, $GROUP" "$KILL_WAY" "kill -9 00" "kill -- 00"
  refuses "a kill of 01, $GROUP" "$KILL_WAY" "kill 01" "kill -TERM 01"
  refuses "a kill of 000, $GROUP" "$KILL_WAY" "kill 000"
}

# What a feeder reads may add options, -s 9 among them, so a kill behind one signals whatever its
# input makes it.
@test "a signalling kill behind a feeder is refused whatever its own signal, and only a listing passes" {
  refuses "a kill of PIDs read from input (xargs kill), which the guard cannot read before it runs" "$READ_WAY" \
    "echo 9 1234 | xargs kill -0 -s" "echo -s 9 1234 | xargs kill -s 0" "xargs kill -n 0 < pids" \
    "xargs kill -0 < pids" "xargs kill -s0 < pids" "echo 9 1234 | xargs kill -0 -n"
  refuses "a kill of PIDs read from input (parallel kill), which the guard cannot read before it runs" "$READ_WAY" \
    "parallel kill -s 0 ::: 1 2"
  refuses "a kill of PIDs read from input (find -exec kill), which the guard cannot read before it runs" "$READ_WAY" \
    "find /proc -maxdepth 1 -name 1 -exec kill -0 {} +"
  passes "echo 9 | xargs kill -l" "xargs kill -L < x"
}
