#!/usr/bin/env bats
# lib/command_text.py's walk: each simple command a Bash call runs, past its wrappers and into the
# strings its tools run, as `python3 -I command_text.py --commands` prints it, one JSON line per
# command: how it was reached, its assignments, the wrappers it ran behind (each its own words,
# the outermost first) and its words from the name of what runs on. And its code text, which keeps
# as code a script the command writes to a file (a heredoc, a here-string, echo or printf, by >,
# >> or tee) and runs (by a shell, source, . or its own name), so command-guard refuses a kill or a
# recursive delete routed through one.

load helpers/common

setup() {
  sandbox
}

# The walk of <command> on stdin: walk <command>
walk() {
  run --separate-stderr python3 -I "$REPO_ROOT/bin/lib/command_text.py" --commands <<<"$1"
}

# The walk of <command> is exactly the <line>s, in order: walks <command> <line>...
walks() {
  local command=$1 expected
  shift
  walk "$command"
  expected=$(printf '%s\n' "$@")
  [[ $status -eq 0 && $output == "$expected" && -z $stderr ]] ||
    { printf 'walk of: %s\nstatus %s, stderr: %s\nexpected:\n%s\ngot:\n%s\n' "$command" "$status" "$stderr" "$expected" "$output" >&2; return 1; }
}

# The code text of <command> holds each <line> as a line of its own: keeps <command> <line>...
keeps() {
  local command=$1 line
  shift
  run --separate-stderr python3 -I "$REPO_ROOT/bin/lib/command_text.py" < <(printf '%s' "$command")
  [[ $status -eq 0 && -z $stderr ]] || { printf 'code text of: %s\nstatus %s, stderr: %s\n' "$command" "$status" "$stderr" >&2; return 1; }
  for line; do
    grep -qxF -- "$line" <<<"$output" ||
      { printf 'no line %s in the code text of:\n%s\ngot:\n%s\n' "$line" "$command" "$output" >&2; return 1; }
  done
}

# The code text of each <command> holds no line <line>: drops <line> <command>...
drops() {
  local line=$1 command
  shift
  for command; do
    run --separate-stderr python3 -I "$REPO_ROOT/bin/lib/command_text.py" < <(printf '%s' "$command")
    [[ $status -eq 0 && -z $stderr ]] || { printf 'code text of: %s\nstatus %s, stderr: %s\n' "$command" "$status" "$stderr" >&2; return 1; }
    if grep -qxF -- "$line" <<<"$output"; then
      printf 'line %s kept in the code text of:\n%s\ngot:\n%s\n' "$line" "$command" "$output" >&2
      return 1
    fi
  done
}

# Each way the tests write "run a" to x.sh, and each way they run x.sh.
WRITES=(
  $'cat > x.sh <<\'EOF\'\nrun a\nEOF'
  $'cat >>x.sh <<EOF\nrun a\nEOF'
  $'tee x.sh <<\'EOF\'\nrun a\nEOF'
  $'tee -a x.sh >/dev/null <<\'EOF\'\nrun a\nEOF'
  $'cat <<\'EOF\' | tee x.sh\nrun a\nEOF'
  $'{ cat <<\'EOF\'\nrun a\nEOF\n} > x.sh'
  "printf 'run a\\n' > x.sh"
  "printf '%s\\n' 'run a' >x.sh"
  "echo 'run a' >> x.sh"
  "echo -n 'run a' | tee x.sh"
  "cat <<< 'run a' > x.sh"
)
RUNS=('bash x.sh' 'sh ./x.sh' './x.sh' '"./x.sh"' '. x.sh' 'source x.sh' 'sudo bash -x x.sh y' "bash -c 'bash x.sh'" 'x.sh')

# The hook on a Bash call of <command>, from a worktree and job tmp of the test's own:
# guard <status> <command>
guard() {
  local wt=$BATS_TEST_TMPDIR/worktree
  mkdir -p "$wt" "$BATS_TEST_TMPDIR/job/tmp"
  CLAUDE_PROJECT_DIR=$wt CLAUDE_JOB_DIR=$BATS_TEST_TMPDIR/job run_bin "$1" --separate-stderr hooks/command-guard \
    <<<"$(jq -cn --arg c "$2" --arg d "$wt" '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Bash", tool_input: {command: $c}}')"
}

@test "each simple command of a list, a pipeline, a group and a substitution is reached directly" {
  walks 'a 1; b "$(c 2)" | d' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["a","1"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["b","$(c 2)"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["d"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["c","2"]}'
}

@test "the assignments before a command, and a command of assignments alone, are kept apart from its words" {
  walks 'X[0]=1 Y[k]+=2 run x' \
    '{"reached":"direct","assignments":["X[0]=1","Y[k]+=2"],"wrappers":[],"words":["run","x"]}'
  walks 'X[ 0 ]=1 Y[a[0]]=2 Z["]"]=3 run x' \
    '{"reached":"direct","assignments":["X[ 0 ]=1","Y[a[0]]=2","Z[\"]\"]=3"],"wrappers":[],"words":["run","x"]}'
  walks 'echo X[ 0 ]=1' '{"reached":"direct","assignments":[],"wrappers":[],"words":["echo","X[","0","]=1"]}'
  walks 'X[;]=1 run x' '{"reached":"direct","assignments":["X[;]=1"],"wrappers":[],"words":["run","x"]}'
  walks 'X[ # ]=1 >f Y[)]=2 run x' \
    '{"reached":"direct","assignments":["X[ # ]=1","Y[)]=2"],"wrappers":[],"words":["run","x"]}'
  walks 'time X[ 0 ]=1 run x' '{"reached":"direct","assignments":["X[ 0 ]=1"],"wrappers":[["time","X[ 0 ]=1"]],"words":["run","x"]}'
  walks 'X[$(c 2)]=1 run x' \
    '{"reached":"direct","assignments":["X[$(c 2)]=1"],"wrappers":[],"words":["run","x"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["c","2"]}'
  walks 'A=1 B+=2 run x; P=$!' \
    '{"reached":"direct","assignments":["A=1","B+=2"],"wrappers":[],"words":["run","x"]}' \
    '{"reached":"direct","assignments":["P=$!"],"wrappers":[],"words":[]}'
}

@test "each wrapper is passed with its options, numbers and values, and kept as its own words" {
  walks 'sudo -u bob nohup nice -n 5 timeout 10s stdbuf -oL setsid ionice -c3 doas time command exec run x' \
    '{"reached":"direct","assignments":[],"wrappers":[["sudo","-u","bob"],["nohup"],["nice","-n","5"],["timeout","10s"],["stdbuf","-oL"],["setsid"],["ionice","-c3"],["doas"],["time"],["command"],["exec"]],"words":["run","x"]}'
  walks '/usr/bin/xargs -r -n 1 kill' \
    '{"reached":"direct","assignments":[],"wrappers":[["/usr/bin/xargs","-r","-n","1"]],"words":["kill"]}'
  walks 'flock -w 5 /tmp/lock run x' \
    '{"reached":"direct","assignments":[],"wrappers":[["flock","-w","5","/tmp/lock"]],"words":["run","x"]}'
}

@test "env's assignments join the command's own, and env is kept as a wrapper" {
  walks 'A=1 env -u X B=2 run x' \
    '{"reached":"direct","assignments":["A=1","B=2"],"wrappers":[["env","-u","X","B=2"]],"words":["run","x"]}'
  walks 'env - B=2 run x' \
    '{"reached":"direct","assignments":["B=2"],"wrappers":[["env","-","B=2"]],"words":["run","x"]}'
}

@test "a substitution inside arithmetic is walked, in \$((...)), \$[...], ((...)) and a double quote" {
  walks 'echo $(( $(run x) + 1 ))' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["echo","$(( $(run x) + 1 ))"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","x"]}'
  walks '(( n = `run x` ))' '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","x"]}'
  walks 'echo "$[ $(run x) ]"' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["echo","$[ $(run x) ]"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","x"]}'
  walks 'echo "$(( $(run x) ))" y' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["echo","$(( $(run x) ))","y"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","x"]}'
  walks 'for ((i = 0; i < 3; i++)); do run $i; done' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["for"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","$i"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["run","$i"]}'
}

@test "a shell's -c string is walked as a string the shell runs, the shell among its wrappers" {
  walks "sudo bash -xc 'run 1; other 2'" \
    '{"reached":"direct","assignments":[],"wrappers":[["sudo"]],"words":["bash","-xc","run 1; other 2"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["sudo"],["bash","-xc","run 1; other 2"]],"words":["run","1"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["sudo"],["bash","-xc","run 1; other 2"]],"words":["other","2"]}'
}

@test "eval's words, su's and script's -c, trap's action, env -S and flock -c are walked as strings their tools run" {
  walks 'eval run "x y"' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["eval","run","x y"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["eval","run","x y"]],"words":["run","x","y"]}'
  walks "su - bob --comm 'run x'" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["su","-","bob","--comm","run x"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["su","-","bob","--comm","run x"]],"words":["run","x"]}'
  walks "su -c 'run x' bob" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["su","-c","run x","bob"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["su","-c","run x","bob"]],"words":["run","x"]}'
  walks "su bob -C 'run x'" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["su","bob","-C","run x"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["su","bob","-C","run x"]],"words":["run","x"]}'
  walks "trap -- 'run x' EXIT" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["trap","--","run x","EXIT"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["trap","--","run x","EXIT"]],"words":["run","x"]}'
  walks "script -qc 'run x' /dev/null" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["script","-qc","run x","/dev/null"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["script","-qc","run x","/dev/null"]],"words":["run","x"]}'
  walks "A=1 env -S'run x' y" \
    '{"reached":"direct","assignments":["A=1"],"wrappers":[["env","-Srun x"]],"words":[]}' \
    '{"reached":"string","assignments":["A=1"],"wrappers":[["env","-Srun x"]],"words":["run","x","y"]}'
  walks "flock /tmp/lock -c 'run x'" \
    '{"reached":"direct","assignments":[],"wrappers":[["flock","/tmp/lock","-c","run x"]],"words":[]}' \
    '{"reached":"string","assignments":[],"wrappers":[["flock","/tmp/lock","-c","run x"]],"words":["run","x"]}'
}

@test "what watch and parallel join of their command's words is walked as a joined string" {
  walks "watch -d 'run x'" \
    '{"reached":"direct","assignments":[],"wrappers":[["watch","-d","run x"]],"words":[]}' \
    '{"reached":"joined","assignments":[],"wrappers":[["watch","-d","run x"]],"words":["run","x"]}'
  walks 'parallel run {} ::: a b' \
    '{"reached":"direct","assignments":[],"wrappers":[["parallel"]],"words":["run","{}"]}' \
    '{"reached":"joined","assignments":[],"wrappers":[["parallel"]],"words":["run","{}"]}'
}

@test "each command find's -exec, -execdir, -ok and -okdir run is reached by find -exec" {
  walks 'find . -exec run {} \; -okdir sudo other {} +' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["find",".","-exec","run","{}",";","-okdir","sudo","other","{}","+"]}' \
    '{"reached":"find -exec","assignments":[],"wrappers":[["find",".","-exec","run","{}",";","-okdir","sudo","other","{}","+"]],"words":["run","{}"]}' \
    '{"reached":"find -exec","assignments":[],"wrappers":[["find",".","-exec","run","{}",";","-okdir","sudo","other","{}","+"],["sudo"]],"words":["other","{}"]}'
}

@test "a string inside a string is walked in turn" {
  walks "bash -c \"eval 'run x'\"" \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["bash","-c","eval '"'run x'"'"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["bash","-c","eval '"'run x'"'"]],"words":["eval","run x"]}' \
    '{"reached":"string","assignments":[],"wrappers":[["bash","-c","eval '"'run x'"'"],["eval","run x"]],"words":["run","x"]}'
}

@test "a shell with no -c or -s runs its first operand as a script, with the words after it" {
  walks 'sudo bash -x -o errexit --rcfile rc ./x.sh a b' \
    '{"reached":"direct","assignments":[],"wrappers":[["sudo"]],"words":["bash","-x","-o","errexit","--rcfile","rc","./x.sh","a","b"]}' \
    '{"reached":"script","assignments":[],"wrappers":[["sudo"],["bash","-x","-o","errexit","--rcfile","rc"]],"words":["./x.sh","a","b"]}'
  walks 'sh -- -x.sh' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["sh","--","-x.sh"]}' \
    '{"reached":"script","assignments":[],"wrappers":[["sh","--"]],"words":["-x.sh"]}'
}

@test "a shell reading stdin, or with no operand, runs no script file" {
  walks 'bash -s x.sh; zsh' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["bash","-s","x.sh"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["zsh"]}'
}

@test "source and . run their file with the words after it" {
  walks 'source ./lib.sh a; . lib.sh' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":["source","./lib.sh","a"]}' \
    '{"reached":"source","assignments":[],"wrappers":[["source"]],"words":["./lib.sh","a"]}' \
    '{"reached":"direct","assignments":[],"wrappers":[],"words":[".","lib.sh"]}' \
    '{"reached":"source","assignments":[],"wrappers":[["."]],"words":["lib.sh"]}'
}

@test "a string 20 deep is walked, and one deeper fails, so a guard refuses" {
  walk "$(printf 'eval %.0s' {1..20})run"
  [[ $status -eq 0 ]]
  [[ ${lines[-1]} == '{"reached":"string",'*'"words":["run"]}' ]]
  walk "$(printf 'eval %.0s' {1..21})run"
  [[ $status -eq 1 ]]
  [[ $stderr == "command_text.py: ValueError: a command string nested deeper than 20" ]]
}

@test "a string equal to the text being walked is not walked again" {
  # No command found yet runs a string equal to itself (each tool's string is shorter than the
  # text, or requoted), so a shell is made to run the text itself.
  run --separate-stderr python3 -I -c '
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import command_text
command_text._shell_string = lambda args: "bash -c x"
for command in command_text.commands("bash -c x"):
    print(command.reached, command.words)
' "$REPO_ROOT/bin/lib"
  [[ $status -eq 0 && -z $stderr ]]
  assert_equal "$output" "direct ('bash', '-c', 'x')"
}

@test "the code text is still what the module prints without --commands" {
  run --separate-stderr python3 -I "$REPO_ROOT/bin/lib/command_text.py" < <(printf '%s' "bash -c 'run x'")
  [[ $status -eq 0 && -z $stderr ]]
  assert_equal "$output" "bash -c 'run x'
run x'"
}

@test "a script written to a file and run as one in the same command is kept as code" {
  local write runner
  for write in "${WRITES[@]}"; do
    for runner in "${RUNS[@]}"; do
      keeps "$write"$'\n'"$runner" 'run a'
      keeps "$write"$'\n'"chmod +x x.sh && $runner" 'run a'
    done
  done
}

@test "a written script's text is read as code in its turn, and each file it runs" {
  # A heredoc a written script feeds to a shell, a string it runs and a script it writes and runs.
  keeps $'printf \'bash <<EOF\\nrun b\\nEOF\\n\' > x.sh; bash x.sh' 'run b'
  keeps "printf '%s\\n' \"bash -c 'run c'\" > x.sh; bash x.sh" "run c'"
  keeps "printf 'run d\\n' > a.sh; printf 'bash a.sh\\n' > b.sh; bash b.sh" 'run d'
  # printf's format is used again while its arguments last; echo -e and %b decode escapes.
  keeps "printf '%s\\n' 'run e' 'run f' > x.sh; bash x.sh" 'run e' 'run f'
  keeps "printf 'run %s\\n' g > x.sh; bash x.sh" 'run g'
  keeps "echo -e 'run h\\nrun i' > x.sh; bash x.sh" 'run h' 'run i'
  keeps "printf '%b' 'run j\\nrun k' > x.sh; bash x.sh" 'run j' 'run k'
  # Pieces written to one file are read together, in order.
  keeps "printf 'run ' > x.sh; printf 'l\\n' >> x.sh; bash x.sh" 'run l'
  # echo without -e writes a backslash as it is, which sh's echo would decode: both are read.
  keeps "echo 'run m\\nrun n' > x.sh; sh x.sh" 'run m\nrun n' 'run n'
}

@test "a written file never run, or run under another name, keeps its text out of the code text" {
  local write
  for write in "${WRITES[@]}"; do
    drops 'run a' "$write" "$write"$'\n''bash y.sh' "$write"$'\n''cat x.sh; ./x.sh.bak; bash sub/x.sh' \
      "$write"$'\n''printf -v s x.sh'
  done
  # A printf into a variable writes no file; neither does a redirection of another fd.
  drops 'run a' "printf -v x.sh 'run a'; bash x.sh" "echo 'run a' 2> x.sh; bash x.sh" "echo 'run a' >&2; bash x.sh"
}

@test "a script written 20 deep is read, and one deeper fails, so a guard refuses" {
  local command='run z' k
  for k in {1..20}; do command="cat > x$k.sh <<'E$k'"$'\n'"$command"$'\n'"E$k"$'\n'"bash x$k.sh"; done
  keeps "$command" 'run z'
  command="cat > x21.sh <<'E21'"$'\n'"$command"$'\n'"E21"$'\n'"bash x21.sh"
  run --separate-stderr python3 -I "$REPO_ROOT/bin/lib/command_text.py" < <(printf '%s' "$command")
  [[ $status -eq 1 ]]
  [[ $stderr == *"ValueError: a written script nested deeper than 20" ]]
}

@test "command-guard refuses a kill or a recursive delete in a script written and run in the same command" {
  local body runner command
  for body in 'pkill -f vite' 'rm -rf /tmp/x'; do
    for command in \
      $'cat > x.sh <<\'EOF\'\n'"$body"$'\nEOF\nbash x.sh' \
      $'cat > x.sh <<EOF\n'"$body"$'\nEOF\nsh ./x.sh' \
      $'tee x.sh <<EOF\n'"$body"$'\nEOF\n./x.sh' \
      $'cat > x.sh <<\'EOF\'\n'"$body"$'\nEOF\n. x.sh' \
      $'cat > x.sh <<\'EOF\'\n'"$body"$'\nEOF\nsource x.sh' \
      "printf '$body\\n' > x.sh; bash x.sh"; do
      guard -2 "$command"
      case $body in
        pkill*) [[ $stderr == "Blocked by command-guard: a kill by name or pattern (pkill), "* ]] ;;
        rm*) [[ $stderr == "Blocked by command-guard: a recursive delete of /tmp/x"* ]] ;;
      esac || { printf 'command: %s\nstderr: %s\n' "$command" "$stderr" >&2; return 1; }
    done
    for runner in 'bash y.sh' 'cat x.sh'; do
      guard -0 $'cat > x.sh <<\'EOF\'\n'"$body"$'\nEOF\n'"$runner"
      [[ -z $stderr ]] || { printf 'runner: %s\nstderr: %s\n' "$runner" "$stderr" >&2; return 1; }
    done
  done
}
