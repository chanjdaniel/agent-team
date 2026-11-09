#!/usr/bin/env bats
# hooks/command-guard: the PreToolUse hook on a worker's Bash that refuses an ops launch, the
# frontend toolkit's capture script and a change of the session's role or task where a command
# starts, in place of the deny rules that matched their names anywhere in a call's text. Every
# command those rules refused when run is still refused (a test per rule), and the reads, searches,
# diffs, commits and file writes that only name them pass, the hook and the worker deny list both.

load helpers/common

setup() {
  sandbox
}

OPS="an ops session is the coordinator's to launch, on Daniel's request (team-worker or team-load-check with ops)"
CAPTURE="the frontend toolkit's capture script is Daniel's own sessions' (run by its path or by an interpreter)"
SET="a worker's role and task are its settings' (an assignment of AGENT_TEAM_ROLE or AGENT_TEAM_TASK)"
UNSET="a worker's role and task are its settings' (an unset of AGENT_TEAM_ROLE or AGENT_TEAM_TASK)"
EMPTIED="a worker's role and task are its settings' (a team script run with its environment emptied, by env -i, env --ignore-environment, env - or exec -c)"

# The hook on a Bash call of <command>, as Claude Code sends it: guard <status> <command>
guard() {
  run_bin "$1" --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$2" \
    '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: "Bash", tool_input: {command: $c}}')"
}

# The hook refuses each <command> with <rule> named: refuses <rule> <command>...
refuses() {
  local rule=$1 command
  shift
  for command; do
    guard -2 "$command"
    [[ $stderr == "Blocked by command-guard: $rule; a guardrail, so report it as BLOCKED and do not reach it another way." ]] ||
      { printf 'not refused with the rule %s: %s\nstderr: %s\n' "$rule" "$command" "$stderr" >&2; return 1; }
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

@test "the worker settings run command-guard beside lease-fence on Bash, and hold none of the rules it replaces" {
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$REPO_ROOT/settings/worker.json")" \
    "@TEAM_CODE@/bin/hooks/lease-fence
@TEAM_CODE@/bin/hooks/command-guard"
  assert_equal "$(jq -c '[.permissions.deny[] | select(test("team-worker|team-load-check|AGENT_TEAM_|ui-capture"))]' \
    "$REPO_ROOT/settings/worker.json")" '[]'
}

# The commands below are reads, searches, diffs, commits and file writes of the kind the old deny
# rules refused for naming a guarded thing, which they only read or write.
@test "a read, search, diff, commit or file write that only names a guarded thing passes" {
  passes "grep -rn 'AGENT_TEAM_ROLE=' tests/" "git grep -n 'AGENT_TEAM_ROLE=coordinator'" \
    "git log -S'toolkits/frontend/scripts/ui-capture' -- settings/worker.json" \
    "git log -S 'team-worker T1 ops' --oneline" "grep -rn 'bash <<EOF' docs" \
    "git grep -n 'Agent Chrome' -- roles bin/team-worker bin/lib/team.sh plugins toolkits/browser sops templates" \
    "git diff origin/dev -- bin/team-worker sops/platform-gotchas.md" "git log --oneline -- bin/team-worker sops" \
    "wc -l toolkits/frontend/scripts/ui-capture" "git add toolkits/frontend/scripts/ui-capture" \
    "git diff -- toolkits/frontend/scripts/ui-capture" "cd toolkits/frontend/scripts && ls" \
    'git commit -m "fix: team-worker refuses an ops launch from a worker"' 'git commit -m "fix(team-worker): ops"' \
    'git commit -m "test: env -u AGENT_TEAM_ROLE and unset AGENT_TEAM_TASK are refused"' \
    "sed -n '/team-worker T1 ops/p' notes.md" "printf '%s\n' 'AGENT_TEAM_TASK=T1 cmd' >f" \
    'echo "$AGENT_TEAM_ROLE $AGENT_TEAM_TASK"' 'env | grep AGENT_TEAM_' "git grep -n 'AGENT_TEAM_TASK:-'" \
    'grep -rn AGENT_TEAM_ROLE bin/' "tests/vendor/bats-core/bin/bats tests/team-post.bats -f 'a planner session'" \
    "tests/vendor/bats-core/bin/bats tests/team-worker.bats -f 'an ops session'" \
    "tests/vendor/bats-core/bin/bats tests/team-load-check.bats -f 'the ops form'" \
    '/home/me/agent-team/bin/team-worker T5 builder /home/me/slots/proj-1 -- "Read your brief"' \
    '/home/me/agent-team/bin/team-worker T5 reviewer wt -- "Read your brief; the ops toolkit is not yours"' \
    'node --test tests/toolkits/frontend.test.mjs' 'git status' 'bash -c "git status"'
  # A heredoc's body is a file's text: a bats line in team-ui.bats's own form, and a ticket's prose.
  passes $'cat >>tests/team-ui.bats <<\'EOF\'\n  AGENT_TEAM_ROLE=builder run_bin -1 team-ui T7 open\nEOF' \
    $'cat >tickets/02.md <<EOF\nteam-worker T1 ops stops and reports.\nunset AGENT_TEAM_ROLE\nEOF' \
    $'cat >x.md <<-"END"\n\tnode toolkits/frontend/scripts/ui-capture out\n\tEND\ngit add x.md' \
    $'cat >run.sh <<\'EOF\'\nteam-worker T1 ops wt\nEOF' \
    $'cat >a.md <<\'A\' >b.md <<\'B\'\nunset AGENT_TEAM_ROLE\nA\nteam-worker T1 ops\nB' \
    $'cat >t.md <<END-1\nx\nEND\nteam-worker T1 ops wt\nEND-1'
}

@test "a call of another tool passes, and input it cannot read is refused, naming why" {
  run_bin -0 --separate-stderr hooks/command-guard <<<'{"tool_name": "Read", "tool_input": {"file_path": "AGENT_TEAM_ROLE=x"}}'
  local input
  for input in 'not json' '{"tool_input": {"command": "git status"}}' '{"tool_name": "Bash", "tool_input": {}}' \
    '{"tool_name": "Bash", "tool_input": {"command": ["team-worker", "T1", "ops"]}}' '[]'; do
    run_bin -2 --separate-stderr hooks/command-guard <<<"$input"
    [[ $stderr == "Blocked by command-guard: it could not read "*"; a guardrail, so report it as BLOCKED and do not reach it another way." ]] ||
      { printf 'input %s: stderr %s\n' "$input" "$stderr" >&2; return 1; }
  done
}

@test "with no team home named, a guarded command is still refused and another passes" {
  homeless() {
    run --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/hooks/command-guard" <<<"$(jq -cn --arg c "$1" \
      '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: "Bash", tool_input: {command: $c}}')"
  }
  [[ ! -e $HOME/.config/agent-team/home ]]
  homeless 'team-worker T1 ops wt'
  assert_equal "$status" 2
  assert_equal "$stderr" "Blocked by command-guard: $OPS; a guardrail, so report it as BLOCKED and do not reach it another way."
  homeless ls
  assert_equal "$status:$stderr" 0:
}

@test "a command failing inside it is a refusal that names the hook and the exit code" {
  # Every jq and python3 call is checked, so the read of its input fails here.
  fails_on_call cat
  guard -2 ls
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by command-guard: it failed with exit 5 before it could decide, and a guard that cannot decide refuses; report it as BLOCKED and do not reach it another way."
  assert_equal "$(wc -l <"$STUB_CALLS/cat.failed")" 1
}

@test "a wrong argument on its command line refuses every call" {
  run_bin -2 --separate-stderr hooks/command-guard --bogus <<<'{"tool_name": "Read", "tool_input": {}}'
  assert_equal "$stderr" "command-guard: usage: command-guard   (the hook's input on stdin)"
}

# The forms a deny rule matching anywhere refused, which a reading of where a command starts must
# find too: shell grammar, a shell reading its script from stdin, and the common runners.
@test "a guarded command after a reserved word or in a brace group is refused" {
  refuses "$OPS" '{ team-worker T1 ops wt; }' 'if true; then team-worker T1 ops wt; fi' \
    'for t in T1; do team-worker "$t" ops wt; done' '! team-worker T1 ops wt' 'x || { team-worker T1 ops wt; }' \
    'if team-worker T1 ops wt; then :; fi' 'while false; do :; done; until team-worker T1 ops wt; do :; done' \
    'if x; then :; else team-worker T1 ops wt; fi' 'if x; then :; elif team-worker T1 ops wt; then :; fi' \
    'time team-worker T1 ops wt'
  refuses "$SET" 'while x; do AGENT_TEAM_ROLE=x team-post T7 --file f; done' 'let AGENT_TEAM_ROLE=1' \
    'read -r AGENT_TEAM_TASK <<<T1' 'printf -v AGENT_TEAM_ROLE %s coordinator'
  refuses "$UNSET" '{ unset AGENT_TEAM_ROLE; }'
}

@test "a guarded command a shell reads from stdin is refused: a heredoc, a here-string or a pipe" {
  refuses "$OPS" $'bash <<\'EOF\'\nteam-worker T1 ops wt\nEOF' $'sh -s <<EOF\ncd x\nteam-worker T1 ops wt\nEOF' \
    "bash <<<'team-worker T1 ops wt'" "echo 'team-worker T1 ops wt' | bash" 'echo team-worker T1 ops wt | sh -s' \
    "printf '%s\n' 'team-worker T1 ops wt' | /bin/bash" $'source /dev/stdin <<\'EOF\'\nteam-worker T1 ops wt\nEOF' \
    $'cat <<\'EOF\' | bash\nteam-worker T1 ops wt\nEOF' $'. /dev/stdin <<EOF\nteam-worker T1 ops wt\nEOF'
  refuses "$SET" $'bash <<\'EOF\'\nAGENT_TEAM_ROLE=x team-post T7 --file f\nEOF'
}

@test "a guarded command run by find -exec, watch, flock, script, su, parallel or after bash -c -- is refused" {
  refuses "$OPS" 'find . -exec team-worker T1 ops wt \;' 'find . -execdir team-worker {} ops wt +' \
    'watch -n 5 team-worker T1 ops wt' "watch 'team-worker T1 ops wt'" 'flock /tmp/l team-worker T1 ops wt' \
    "flock -x /tmp/l -c 'team-worker T1 ops wt'" "script -qc 'team-worker T1 ops wt' /dev/null" \
    "su -c 'team-worker T1 ops wt' me" 'parallel team-worker {} ops wt ::: T1' "bash -c -- 'team-worker T1 ops wt'"
  refuses "$CAPTURE" 'deno run toolkits/frontend/scripts/ui-capture out' 'bun toolkits/frontend/scripts/ui-capture out' \
    'npx toolkits/frontend/scripts/ui-capture out'
}

# A << that opens no heredoc, or a heredoc's marker taken whole, never hides a line Bash runs.
@test "a guarded command next to a << that opens no heredoc, or after a heredoc, is refused" {
  refuses "$OPS" $'echo \'<<X\'\nteam-worker T1 ops wt\nX' $'echo "<<X"\nteam-worker T1 ops wt\nX' \
    $'cat <<END-1\nx\nEND-1\nteam-worker T1 ops wt\nEND' $'echo $((1<<X))\nteam-worker T1 ops wt\nX' \
    $'# a <<X note\nteam-worker T1 ops wt\nX' \
    $'cat <<EOF\nx\nEOF\nteam-worker T1 ops wt' $'cat <<-EOF\n\tx\n\tEOF\nteam-worker T1 ops wt' \
    $'cat <<A <<B\na\nA\nb\nB\nteam-worker T1 ops wt' $'cat <<EOF; team-worker T1 ops wt\nx\nEOF'
}

@test "a guarded command after a pipe, in a backtick, in a subshell or through xargs is refused" {
  refuses "$OPS" 'git status | team-worker T1 ops wt' 'echo `team-worker T1 ops wt`' '(team-worker T1 ops wt)' \
    'echo T1 | xargs -I{} team-worker {} ops wt'
}

# Rule Bash(*team-worker *ops *), and the forms it took in by matching anywhere.
@test "team-worker with ops is refused where a command starts, by path, behind a wrapper or in a shell's string" {
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  refuses "$OPS" \
    '/home/me/agent-team/bin/team-worker T5 ops /home/me/slots/proj-1 --toolkit prod-read --request https://discord.com/channels/1/2/3 -- "$(cat /home/me/agent-team/tasks/T5/brief-ops.md)"' \
    'team-worker "T5" ops /home/me/slots/proj-1 --toolkit prod-read --request x -- go' \
    '/home/me/agent-team/bin/team-worker T5 ops /home/me/slots/proj-1 --toolkit vercel-read --request https://discord.com/channels/1/2/3 -- "$(cat /home/me/agent-team/tasks/T5/brief-ops.md)"' \
    'team-worker T5 ops /home/me/slots/proj-1 --toolkit prod-read --toolkit vercel-read --request x -- go' \
    'team-worker T1 ops' "team-worker T1 'ops' wt -- go" 'cd x && team-worker T1 ops wt -- go' \
    '~/agent-team/bin/team-worker T1 ops wt' '"$HOME/agent-team/bin/team-worker" T1 ops wt' \
    'nohup ~/agent-team/bin/team-worker T1 ops wt -- go &' 'env A=1 timeout -s KILL 10s team-worker T1 ops wt' \
    'bash ~/agent-team/bin/team-worker T1 ops wt' "bash -c 'team-worker T1 ops wt -- go'" \
    "bash -lc \"sh -c 'team-worker T1 ops wt'\"" 'eval "team-worker T1 ops wt"' 'echo "$(team-worker T1 ops wt)"' \
    "env --split-string='team-worker T1 ops wt'" "env -S'team-worker T1 ops wt'" \
    $'git status\nteam-worker T1 ops wt' $'cat <<EOF\n$(team-worker T1 ops wt)\nEOF' \
    $'cat >f <<\'EOF\'\nnotes\nEOF\nteam-worker T1 ops wt' $'cat <<<"x" && team-worker T1 ops wt'
}

# Rule Bash(*team-load-check *ops*).
@test "team-load-check with ops is refused where a command starts" {
  refuses "$OPS" \
    '/home/me/agent-team/bin/team-load-check --role ops --worktree /home/me/slots/proj-1 --toolkit prod-read' \
    'team-load-check --role=ops --worktree /home/me/slots/proj-1 --toolkit prod-read --toolkit prod-write' \
    '/home/me/agent-team/bin/team-load-check --role ops --worktree /home/me/slots/proj-1 --toolkit vercel-read' \
    'team-load-check --role ops --worktree /home/me/slots/proj-1 --toolkit prod-read --toolkit vercel-read' \
    'team-load-check ops' 'timeout 600 team-load-check --role "ops" --worktree wt --toolkit prod-read'
}

# Rule Bash(*toolkits/frontend/scripts/ui-capture*).
@test "the frontend capture script is refused run by its path or by an interpreter" {
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  refuses "$CAPTURE" '~/agent-team/toolkits/frontend/scripts/ui-capture .scratch/task/out' \
    'node toolkits/frontend/scripts/ui-capture out' 'node --no-warnings ~/agent-team/toolkits/frontend/scripts/ui-capture out' \
    'bash toolkits/frontend/scripts/ui-capture out' 'sh toolkits/frontend/scripts/ui-capture' \
    'source toolkits/frontend/scripts/ui-capture' '. toolkits/frontend/scripts/ui-capture' \
    'cd toolkits/frontend/scripts && ./ui-capture out' "bash -c 'toolkits/frontend/scripts/ui-capture out'"
}

# Rule Bash(*AGENT_TEAM_ROLE=*).
@test "an assignment of the role variable is refused before a command, alone, through env, export or declare, or in a shell's string" {
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  refuses "$SET" 'AGENT_TEAM_ROLE=coordinator ~/agent-team/bin/team-post T7 --file f' 'export AGENT_TEAM_ROLE=x' \
    'AGENT_TEAM_ROLE= team-post T7 --file f' 'env AGENT_TEAM_ROLE=coordinator team-post T7 --file f' \
    'cd x && AGENT_TEAM_ROLE=coordinator team-post T7 --file f' 'nohup env A=1 AGENT_TEAM_ROLE=x team-post T7 --file f' \
    "bash -c 'AGENT_TEAM_ROLE=coordinator team-post T7 --file f'" 'eval "AGENT_TEAM_ROLE=x team-post T7 --file f"' \
    "env -S 'AGENT_TEAM_ROLE=x team-post T7 --file f'" \
    'declare -x AGENT_TEAM_ROLE=coordinator' 'export -n AGENT_TEAM_ROLE' 'readonly AGENT_TEAM_ROLE' \
    'AGENT_TEAM_ROLE+=x team-post T7 --file f' $'git status\nAGENT_TEAM_ROLE=coordinator\nteam-post T7 --file f' \
    $'cat <<EOF\n$(AGENT_TEAM_ROLE=x team-post T7 --file f)\nEOF'
}

# Rule Bash(*AGENT_TEAM_TASK=*).
@test "an assignment of the task variable is refused before a command, through env, export or typeset, or in a shell's string" {
  refuses "$SET" 'env AGENT_TEAM_TASK=T1 cmd' 'export AGENT_TEAM_TASK=T8; team-post T8 --file f' \
    'AGENT_TEAM_ROLE=planner AGENT_TEAM_TASK=T8 team-post T8 --thread interview --file f' \
    'typeset -x AGENT_TEAM_TASK=T1' 'local AGENT_TEAM_TASK=T1' "sh -c \"export AGENT_TEAM_TASK=T1; team-post T1 --file f\""
}

# Rule Bash(*unset AGENT_TEAM_*).
@test "unset and env --unset of either variable are refused" {
  refuses "$UNSET" 'unset AGENT_TEAM_ROLE; team-post T7 --file f' 'unset -v AGENT_TEAM_TASK' 'unset X AGENT_TEAM_ROLE' \
    'env --unset AGENT_TEAM_ROLE team-post T7 --file f' "bash -c 'unset AGENT_TEAM_ROLE; team-post T7 --file f'"
}

# Rule Bash(*unset=AGENT_TEAM_*).
@test "env --unset= of either variable is refused" {
  refuses "$UNSET" 'env --unset=AGENT_TEAM_ROLE team-post T7 --file f' 'env -i --unset=AGENT_TEAM_TASK A=1 cmd'
}

# Rule Bash(*-u AGENT_TEAM_*).
@test "env -u of either variable is refused, by any path and behind a wrapper" {
  refuses "$UNSET" 'env -u AGENT_TEAM_ROLE team-post T7 --file f' '/usr/bin/env -u AGENT_TEAM_TASK cmd' \
    'nohup env -u HOME -u AGENT_TEAM_ROLE cmd'
}

# Rule Bash(*-uAGENT_TEAM_*).
@test "env -u joined to either variable is refused" {
  refuses "$UNSET" 'env -uAGENT_TEAM_TASK team-post T7 --file f' 'env -iuAGENT_TEAM_ROLE cmd'
}

@test "a command naming no guarded thing passes without Python, and a guarded one fails closed when Python fails" {
  printf '#!/bin/sh\nexit 3\n' >"$BATS_TEST_TMPDIR/stubs/python3"
  chmod +x "$BATS_TEST_TMPDIR/stubs/python3"
  guard -0 'git status && tests/run bats --changed'
  guard -0 'env -i ls' && guard -0 'env -i PATH="$PATH" HOME="$HOME" tests/run' && guard -0 'exec -c bash'
  guard -0 'team-log T7 review' && guard -0 'env A=1 team-state T7'
  guard -2 'env -i team-log T7 review'
  [[ $stderr == "Blocked by command-guard: it could not read the command"* ]]
  guard -2 'grep -rn AGENT_TEAM_ROLE bin/'
  [[ $stderr == "Blocked by command-guard: it could not read the command"* ]]
}

# The one plain way past worker_refusal's role check: a team script run with no AGENT_TEAM_ROLE.
@test "a team script run behind env -i, env --ignore-environment, env - or exec -c is refused, by any path" {
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  refuses "$EMPTIED" 'env -i team-log T7 review verdict=pass' 'env -i ~/agent-team/bin/team-merge T7' \
    '/usr/bin/env -i PATH="$PATH" HOME="$HOME" team-log T7 review' 'env --ignore-environment team-next T7 -- x' \
    'env --ignore-env team-close T7' 'env - team-open proj feature feat x y' 'env - A=1 team-catch-up T7' \
    'exec -c team-worker T7 builder wt -- go' 'exec -c -a x "$HOME/agent-team/bin/team-level" minor' \
    'exec -cl team-review-status url sha success x' 'env -i claude-coordinator' 'env -iC /tmp team-log T7 x' \
    'env -u HOME -i team-log T7 x' 'env -0i team-log T7 x' "env -i 'team-log' T7 x" 'env -i "team-log" T7 x' \
    'cd x && env -i team-log T7 x' 'nohup env -i team-log T7 x &' 'git status; env -i team-log T7 x' \
    'env -i nohup team-log T7 x' 'env -i timeout 10 team-log T7 x' 'env -i bash ~/agent-team/bin/team-log T7 x' \
    "bash -c 'env -i team-log T7 x'" "env -i bash -c 'team-log T7 x'" 'eval "env -i team-log T7 x"' $'bash <<\'EOF\'\nenv -i team-log T7 x\nEOF' \
    'echo "$(env -i team-merge T7)"' 'env -i team-anything'
}

@test "env -i before another command, and a search, commit or file naming env -i or a team script, pass" {
  passes 'env -i ls' 'env -i PATH="$PATH" HOME="$HOME" tests/run' 'env -i PATH="$PATH" tests/run bats --changed' \
    'env -i bash -c "echo hi"' 'env -i git status' 'env -i grep -rn team-log bin/' 'exec -c ls' 'env team-log T7 x' \
    "grep -rn 'env -i team-log' tests/" "git grep -n 'exec -c team-worker'" "git log -S'env -i team-merge' --oneline" \
    'git commit -m "fix(command-guard): refuse env -i team-log and exec -c team-worker"' \
    $'cat >notes.md <<\'EOF\'\nenv -i team-log T7 x\nEOF' "sed -n '/env -i team-/p' bin/hooks/command-guard" \
    'env -i ~/team-stuff/run' 'env -i ./steam-run' 'team-log T7 resumed' 'env -i teammate'
}
