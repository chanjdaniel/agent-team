#!/usr/bin/env bats
# hooks/command-guard's kill rows (bin/lib/kill_rules.py): a kill by name or pattern, tmux's
# kill-*, a kill of PIDs read from input, of a PID the guard cannot read before it runs, and of a
# process group, every process or PID 0 or 1 are refused wherever a command runs (behind a
# wrapper, in a string a shell or eval runs, in a heredoc or here-string a shell reads, piped into
# a shell), each naming its allowed way with a worker's suffix or a gate agent's; the session's own
# jobs, signal 0, kill -l, a literal PID and the reads, commits and data that only name a kill
# pass.

load helpers/common

setup() {
  sandbox
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

@test "the session's own jobs, signal 0, kill -l and a literal PID pass, and so does what only names a kill" {
  passes "kill \$!" "kill -9 \${!}" "kill \"\$!\"" "P=\$!; kill \$P" "sleep 300 & P=\"\$!\"; kill \"\${P}\"" \
    "sleep 1 & local P=\$!; kill -TERM \$P" "kill %1" "kill -9 %%" "kill \$(jobs -p)" "kill -- \"\$(jobs -p)\"" \
    "kill \`jobs -p\`" "kill \$\$" "kill -0 \$X" "kill -0 1" "kill -s 0 \$(pgrep x)" "kill -n 0 -1" "kill -l" "kill -l 9" \
    "kill -L" "kill 4242" "kill -9 4242" "kill -s TERM -- 4242" "kill" "kill -TERM"
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
