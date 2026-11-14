#!/usr/bin/env bats
# hooks/command-guard's delete rows (bin/lib/delete_rules.py): a recursive delete (rm -r in every
# spelling, find -delete and find -exec rm) passes only when every path it deletes resolves
# strictly inside the worktree or the job's tmp, never one of them, the worktree's .scratch/task or
# a directory holding one, wherever it runs (behind a wrapper, in a string a shell or eval runs, in
# a heredoc or here-string a shell reads, piped into a shell); a path the guard cannot read before
# it runs is refused; and git rm, a single file's rm, rmdir and text that only names a delete pass.

load helpers/common

# Each test's worktree (CLAUDE_PROJECT_DIR, the input's cwd), its job tmp ($CLAUDE_JOB_DIR/tmp),
# a directory outside both, and a link in the worktree to that directory.
setup() {
  sandbox
  WT=$BATS_TEST_TMPDIR/worktree JOB=$BATS_TEST_TMPDIR/job OUT=$BATS_TEST_TMPDIR/outside
  mkdir -p "$WT/src/sub" "$WT/build" "$WT/.scratch/task/work/old" "$JOB/tmp/check" "$OUT"
  ln -s "$OUT" "$WT/link"
  export CLAUDE_PROJECT_DIR=$WT CLAUDE_JOB_DIR=$JOB
  CWD=$WT
  TMP=$(cd -P /tmp && pwd)
}

OUTSIDE="which is outside your worktree and your job's tmp"
KEPT="which is your worktree, its .scratch/task or your job's tmp, or holds one"
UNREAD="a path the guard cannot read before it runs (a variable or substitution this command does not set, a ~user, a brace range, or a relative path after a cd it cannot follow)"
FIND="a recursive delete (find -delete or find -exec rm) under"
# shellcheck disable=SC2016 # the allowed ways name $CLAUDE_JOB_DIR as the worker writes it
DELETE_WAY='delete only inside your worktree (never it or its .scratch/task, which team-close archives) or inside $CLAUDE_JOB_DIR/tmp, by a path spelled out in the command; make scratch with mktemp -d "$CLAUDE_JOB_DIR/tmp/<name>.XXXXXX"'
# shellcheck disable=SC2016
UNREAD_WAY='spell the path out, or set the variable in the same command (T=$(mktemp -d "$CLAUDE_JOB_DIR/tmp/<name>.XXXXXX")), inside your worktree or your job'"'"'s tmp'

# The hook on a Bash call of <command> run in CWD, as Claude Code sends it: guard <status> <command>
guard() {
  run_bin "$1" --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$2" --arg d "$CWD" \
    '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Bash", tool_input: {command: $c}}')"
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
# and behind sudo, env, nohup and timeout, one per line of FORMS: wrapped <command>
wrapped() {
  FORMS=("$1" "bash -c '$1'" "eval '$1'" $'bash <<\'EOF\'\n'"$1"$'\nEOF' "bash <<< '$1'" "echo '$1' | bash"
    "sudo $1" "env A=1 $1" "nohup $1" "timeout 5 $1")
}

# The hook refuses <command> in each of its wrapped forms: refuses_wrapped <reason> <allowed> <command>
refuses_wrapped() {
  wrapped "$3"
  refuses "$1" "$2" "${FORMS[@]}"
}

@test "a recursive delete inside the worktree or the job's tmp passes, in every wrapped form" {
  local command
  for command in "rm -rf build" "rm -r src/sub" "rm -rf .scratch/task/work/old" "rm -rf $WT/build/x" \
    'rm -rf "$CLAUDE_JOB_DIR/tmp/check"' "rm -rf $JOB/tmp/check" 'rm -rf "$PWD/build"' "rm -rf build/*" \
    "rm -rf build/{a,b}" "rm -rf src/{sub,x/{y,z}}" "rm -rf ./build" "rm -rf src/../build" \
    "find build -name x -delete" "find build -exec rm -rf {} +"; do
    wrapped "$command"
    # The worker settings deny sudo, so its form is the hook's alone, refused or not.
    unset 'FORMS[6]'
    passes "${FORMS[@]}"
    guard -0 "sudo $command"
  done
  passes "cd src && rm -rf sub" "pushd src && rm -rf sub" "rm -fr build" "rm -Rf build" \
    "rm --recursive --force build" "rm -rf -- build" "rm build -rf" "/bin/rm -rf build" '"rm" -rf build' \
    "xargs -r echo < list; rm -rf build" "rm -rf" "find src -depth -okdir rm -rf {} \\;" \
    "find -L build -delete" "rm -rf \"\"" "rm -rf \"\$CLAUDE_JOB_DIR/tmp/a b\""
}

@test "a variable the command sets passes when every value it is given passes" {
  # shellcheck disable=SC2016
  passes 'T=$(mktemp -d "$CLAUDE_JOB_DIR/tmp/x.XXXXXX"); ls "$T"; rm -rf "$T"' \
    'T=$(mktemp -d "$CLAUDE_JOB_DIR/tmp/x.XXXXXX") && trap '"'"'rm -rf "$T"'"'"' EXIT && ls "$T"' \
    'T=`mktemp -d -p "$CLAUDE_JOB_DIR/tmp" x.XXXXXX`; rm -rf "${T}"' \
    'T="$(mktemp -d --tmpdir="$CLAUDE_JOB_DIR/tmp")"; rm -rf "$T"' \
    'T=$(mktemp -d build/x.XXXXXX); rm -rf "$T"' \
    'D=build; rm -rf "$D"' 'D="$CLAUDE_JOB_DIR/tmp/check"; rm -rf "$D/x"' 'local D=build/x; rm -rf $D' \
    'export D=build; rm -rf "$D"' 'D=build; E="$D/x"; rm -rf "$E"' 'D=build; [ -d "$D" ] && rm -rf "$D"' \
    'D=build; rm -rf "${D}" && D=src/sub && rm -rf "$D"' \
    "bash -c 'D=build; rm -rf \"\$D\"'"
}

@test "a recursive delete outside the worktree and the job's tmp is refused, naming the path" {
  refuses_wrapped "a recursive delete of $TMP/x, $OUTSIDE" "$DELETE_WAY" "rm -rf /tmp/x"
  refuses_wrapped "a recursive delete of $HOME/x, $OUTSIDE" "$DELETE_WAY" 'rm -rf "$HOME/x"'
  refuses_wrapped "a recursive delete of $HOME/x, $OUTSIDE" "$DELETE_WAY" "rm -rf ~/x"
  refuses_wrapped "a recursive delete of $TEAM_HOME/tasks, $OUTSIDE" "$DELETE_WAY" "rm -rf $TEAM_HOME/tasks"
  refuses_wrapped "a recursive delete of $BATS_TEST_TMPDIR/x, $OUTSIDE" "$DELETE_WAY" "rm -rf ../x"
  refuses "a recursive delete of $TMP/x, $OUTSIDE" "$DELETE_WAY" "rm --recursive /tmp/x" "rm --rec -f /tmp/x" \
    "rm -Rf /tmp/x" "rm -r -f -- /tmp/x" "/usr/bin/rm -rf /tmp/x" "'rm' -rf /tmp/x" "rm -rf build /tmp/x" \
    "rm -rf /tmp/x \"\$T\"" "xargs -r echo; rm -rf /tmp/x" "sudo -u root rm -rf /tmp/x" "nice -n 5 rm -rf /tmp/x" \
    "rm -rf {build,/tmp/x}" "rm -rf /tmp/x/../x" "command rm -rf /tmp/x" "D=/tmp/x; rm -rf \"\$D\"" \
    "D=build; D=/tmp/x; rm -rf \"\$D\""
  refuses "a recursive delete of $TMP/*, $OUTSIDE" "$DELETE_WAY" "rm -rf /tmp/*"
  refuses "a recursive delete of $TMP/[ab]*, $OUTSIDE" "$DELETE_WAY" "rm -rf /tmp/[ab]*"
  refuses "a recursive delete of /, $OUTSIDE" "$DELETE_WAY" "rm -rf /" "rm -rf --no-preserve-root /"
}

@test "a link out of the worktree is followed before the check" {
  refuses_wrapped "a recursive delete of $OUT, $OUTSIDE" "$DELETE_WAY" "rm -rf link"
  refuses "a recursive delete of $OUT/x, $OUTSIDE" "$DELETE_WAY" "rm -rf link/x" "rm -rf $WT/link/x" \
    "cd link && rm -rf x"
  refuses "a recursive delete of $BATS_TEST_TMPDIR/x, $OUTSIDE" "$DELETE_WAY" "rm -rf link/../x"
  refuses "a recursive delete of $OUT/*, $OUTSIDE" "$DELETE_WAY" "rm -rf link/*"
}

@test "a relative delete is checked against every directory the command may be in" {
  refuses "a recursive delete of $BATS_TEST_TMPDIR/x, $OUTSIDE" "$DELETE_WAY" "(cd ..); rm -rf x" "cd .. && rm -rf x" \
    "cd src/../.. && rm -rf x"
  refuses "a recursive delete of $(dirname "$BATS_TEST_TMPDIR")/x, $OUTSIDE" "$DELETE_WAY" "(cd src); rm -rf ../../x"
  refuses "a recursive delete of $TMP/x, $OUTSIDE" "$DELETE_WAY" "(cd /tmp); rm -rf x" "cd /tmp; cd ..; cd tmp; rm -rf x"
  refuses "a recursive delete of $HOME/x, $OUTSIDE" "$DELETE_WAY" "cd; rm -rf x" "cd -- && rm -rf x"
  refuses "a recursive delete of $OUT/x, $OUTSIDE" "$DELETE_WAY" "bash -c 'cd $OUT' && rm -rf x"
}

@test "the worktree, its .scratch/task, the job's tmp and a directory holding one are refused" {
  refuses_wrapped "a recursive delete of $WT, $KEPT" "$DELETE_WAY" "rm -rf $WT"
  refuses_wrapped "a recursive delete of $WT, $KEPT" "$DELETE_WAY" "rm -rf ."
  refuses_wrapped "a recursive delete of $WT/.scratch/task, $KEPT" "$DELETE_WAY" "rm -rf .scratch/task"
  refuses_wrapped "a recursive delete of $JOB/tmp, $KEPT" "$DELETE_WAY" 'rm -rf "$CLAUDE_JOB_DIR/tmp"'
  refuses "a recursive delete of $WT, $KEPT" "$DELETE_WAY" "rm -rf ./" "rm -rf src/.." 'rm -rf "$PWD"'
  refuses "a recursive delete of $WT/.scratch, $KEPT" "$DELETE_WAY" "rm -rf .scratch" "rm -rf .scratch/task/.."
  refuses "a recursive delete of $WT/.scratch/task, $KEPT" "$DELETE_WAY" "rm -rf .scratch/task/" \
    "rm -rf $WT/.scratch/task"
  refuses "a recursive delete of $JOB/tmp, $KEPT" "$DELETE_WAY" "rm -rf $JOB/tmp" "rm -rf \"\$CLAUDE_JOB_DIR/tmp/\""
}

@test "a glob passes only under a directory that passes, holding no kept path, never starting with a dot" {
  refuses_wrapped "a recursive delete of $WT/*, $KEPT" "$DELETE_WAY" "rm -rf ./*"
  refuses "a recursive delete of $WT/*, $KEPT" "$DELETE_WAY" "rm -rf *" "rm -rf $WT/*"
  # The glob matches link, whose build is outside, and the outside row comes first.
  refuses "a recursive delete of $OUT/build, $OUTSIDE" "$DELETE_WAY" "rm -rf */build"
  rm "$WT/link"
  refuses "a recursive delete of $WT/*/build, $KEPT" "$DELETE_WAY" "rm -rf */build"
  refuses "a recursive delete of $WT/.scratch/*, $KEPT" "$DELETE_WAY" "rm -rf .scratch/*"
  refuses "a recursive delete of $WT/.*, $KEPT" "$DELETE_WAY" "rm -rf .*"
  refuses "a recursive delete of $WT/build/.*, $KEPT" "$DELETE_WAY" "rm -rf build/.*"
  refuses "a recursive delete of $WT/.s*, $KEPT" "$DELETE_WAY" "rm -rf .s*"
  refuses "a recursive delete of $JOB/tmp/*, $KEPT" "$DELETE_WAY" 'rm -rf "$CLAUDE_JOB_DIR"/tmp/*'
  passes "rm -rf build/*" "rm -rf src/*/x" "rm -rf build/x?" "rm -rf build/[ab]" "rm -rf .scratch/task/work/*"
}

@test "a path the guard cannot read before it runs is refused, naming the word" {
  refuses_wrapped "a recursive delete of \$T, $UNREAD" "$UNREAD_WAY" 'rm -rf "$T"'
  refuses "a recursive delete of \$T, $UNREAD" "$UNREAD_WAY" 'rm -rf $T' 'rm -rf "$T"; T=build' \
    'T=build; read T; rm -rf "$T"' 'T=build; T+=x; rm -rf "$T"' 'for T in a b; do rm -rf "$T"; done' \
    'T=build; printf -v T /tmp; rm -rf "$T"' 'T=build; unset T; rm -rf "$T"' 'T=(/tmp); rm -rf $T' \
    'declare -n T=X; rm -rf "$T"' 'T=$(cat list); rm -rf "$T"' 'T=$(mktemp -d; echo /tmp); rm -rf "$T"' \
    'T="a b"; rm -rf $T' 'T=build rm -rf "$T"' 'env T=build rm -rf "$T"'
  refuses "a recursive delete of \${T}, $UNREAD" "$UNREAD_WAY" 'rm -rf "${T}"'
  refuses "a recursive delete of \${T:-build}, $UNREAD" "$UNREAD_WAY" 'rm -rf "${T:-build}"'
  refuses "a recursive delete of \$TMPDIR, $UNREAD" "$UNREAD_WAY" "TMPDIR=$WT/x rm -rf \"\$TMPDIR\""
  refuses "a recursive delete of \$1, $UNREAD" "$UNREAD_WAY" "bash -c 'rm -rf \"\$1\"' _ /tmp"
  refuses "a recursive delete of \$(pwd)/x, $UNREAD" "$UNREAD_WAY" 'rm -rf "$(pwd)/x"'
  refuses "a recursive delete of \`pwd\`/x, $UNREAD" "$UNREAD_WAY" 'rm -rf `pwd`/x'
  refuses "a recursive delete of <(ls), $UNREAD" "$UNREAD_WAY" 'rm -rf <(ls)'
  refuses "a recursive delete of ~other/x, $UNREAD" "$UNREAD_WAY" "rm -rf ~other/x"
  refuses "a recursive delete of ~+/x, $UNREAD" "$UNREAD_WAY" "rm -rf ~+/x"
  refuses "a recursive delete of build/{1..3}, $UNREAD" "$UNREAD_WAY" "rm -rf build/{1..3}"
  refuses "a recursive delete of \\x2ftmp, $UNREAD" "$UNREAD_WAY" "rm -rf \$'\\x2ftmp'"
  refuses "a recursive delete of ~/x, $UNREAD" "$UNREAD_WAY" "HOME=$WT; rm -rf ~/x"
  refuses "a recursive delete of \$HOME/x, $UNREAD" "$UNREAD_WAY" "HOME=$WT rm -rf \"\$HOME/x\""
  refuses "a recursive delete of \$CLAUDE_JOB_DIR/tmp/x, $UNREAD" "$UNREAD_WAY" \
    "CLAUDE_JOB_DIR=$WT; rm -rf \"\$CLAUDE_JOB_DIR/tmp/x\""
  refuses "a recursive delete of \$T, $UNREAD" "$UNREAD_WAY" 'T=a/tmp; IFS=a; rm -rf $T'
  refuses "a recursive delete of /proc/self/cwd/x, $UNREAD" "$UNREAD_WAY" "rm -rf /proc/self/cwd/x"
  refuses "a recursive delete of /dev/fd/3/x, $UNREAD" "$UNREAD_WAY" "rm -rf /dev/fd/3/x"
}

@test "a relative path after a cd the guard cannot follow is refused" {
  refuses "a recursive delete of x, $UNREAD" "$UNREAD_WAY" "cd -; rm -rf x" "cd \"\$D\" && rm -rf x" "popd; rm -rf x" \
    "pushd +1; rm -rf x" "pushd && rm -rf x" "cd \$(git rev-parse --show-toplevel) && rm -rf x" \
    "env -C /tmp rm -rf x" "sudo -D /tmp rm -rf x" "env --chdir=/tmp rm -rf x"
  CDPATH=/tmp refuses "a recursive delete of x, $UNREAD" "$UNREAD_WAY" "cd src && rm -rf x"
  # An absolute path stays readable after any cd.
  passes "cd -; rm -rf $WT/build"
}

@test "mktemp -d with no template or a template under TMPDIR deletes outside" {
  TMPDIR=$OUT refuses "a recursive delete of $OUT/tmp.XXXXXXXXXX, $OUTSIDE" "$DELETE_WAY" \
    'T=$(mktemp -d); rm -rf "$T"' 'T=$(mktemp -d --tmpdir); rm -rf "$T"'
  TMPDIR=$OUT refuses "a recursive delete of $OUT/x.XXXXXX, $OUTSIDE" "$DELETE_WAY" 'T=$(mktemp -d -t x.XXXXXX); rm -rf "$T"'
  TMPDIR='' refuses "a recursive delete of $TMP/tmp.XXXXXXXXXX, $OUTSIDE" "$DELETE_WAY" 'T=$(mktemp -d); rm -rf "$T"'
  refuses "a recursive delete of $OUT/x.XXXXXX, $OUTSIDE" "$DELETE_WAY" "T=\$(mktemp -d -p $OUT x.XXXXXX); rm -rf \"\$T\"" \
    "T=\$(mktemp -d $OUT/x.XXXXXX); rm -rf \"\$T\""
}

@test "CLAUDE_PROJECT_DIR, which the Bash tool's shell does not set, is read as unset too" {
  refuses "a recursive delete of /x, $OUTSIDE" "$DELETE_WAY" 'rm -rf "$CLAUDE_PROJECT_DIR/x"'
  refuses "a recursive delete of $WT, $KEPT" "$DELETE_WAY" 'rm -rf "$CLAUDE_PROJECT_DIR"'
}

@test "find -delete and find -exec rm are held to the same rule, under their start paths" {
  refuses_wrapped "$FIND $TMP, $OUTSIDE" "$DELETE_WAY" "find /tmp -name x -delete"
  refuses_wrapped "$FIND $TMP, $OUTSIDE" "$DELETE_WAY" "find /tmp -exec rm -rf {} +"
  refuses "$FIND $TMP, $OUTSIDE" "$DELETE_WAY" "find /tmp -delete" "find -L /tmp -delete" "find -H -O3 /tmp -delete" \
    "find build /tmp -delete" "find /tmp -execdir rm {} \\;" "find /tmp -okdir /bin/rm -f {} \\;" \
    "find /tmp -exec sudo rm -rf {} \\;" "find /tmp -exec sh -c 'rm -rf {}' \\;" "sudo find /tmp -mindepth 1 -delete"
  refuses "$FIND $WT, $KEPT" "$DELETE_WAY" "find . -name '*.pyc' -delete" "find -delete" "find -name x -exec rm {} +"
  refuses "$FIND \$D, $UNREAD" "$UNREAD_WAY" "find \"\$D\" -delete"
  refuses "a recursive delete of \$1, $UNREAD" "$UNREAD_WAY" "find build -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"
  passes "find /tmp -name x" "find /tmp -exec ls {} +" "find build -exec grep -delete {} +" "find /tmp -print -quit"
}

@test "a recursive delete of paths read from input is refused" {
  refuses_wrapped "a recursive delete of xargs's input, $UNREAD" "$UNREAD_WAY" "xargs rm -rf < list"
  refuses "a recursive delete of xargs's input, $UNREAD" "$UNREAD_WAY" "find . -print0 | xargs -0 rm -rf" \
    "ls | xargs -r rm -rf" "ls | xargs -I{} rm -rf {}" "ls | xargs -I{} rm -rf build/{}"
  refuses "a recursive delete of parallel's input, $UNREAD" "$UNREAD_WAY" "parallel rm -rf ::: build" "ls | parallel rm -rf"
  refuses "$FIND xargs's input, $UNREAD" "$UNREAD_WAY" "ls | xargs -I{} find {} -delete"
  passes "ls | xargs rm -f" "ls | xargs -r echo"
}

@test "with no worktree and no job tmp, every recursive delete is refused as outside" {
  unset CLAUDE_PROJECT_DIR CLAUDE_JOB_DIR
  CWD=$OUT
  refuses "a recursive delete of $WT/build, $OUTSIDE" "$DELETE_WAY" "rm -rf $WT/build"
  refuses "a recursive delete of $OUT/x, $OUTSIDE" "$DELETE_WAY" "rm -rf x"
  refuses "a recursive delete of \$T, $OUTSIDE" "$DELETE_WAY" 'rm -rf "$T"'
  refuses "$FIND $OUT, $OUTSIDE" "$DELETE_WAY" "find . -delete"
  passes "rm -rf" "rm x" "git rm -r x"
}

@test "git rm, a single file's rm, rmdir and what only names a recursive delete pass" {
  passes "git rm -r x" "git rm -rf /tmp/x" "rm x" "rm -f /tmp/x" "rm -- -r" "rmdir x" "rmdir /tmp/x" "rm -d /tmp/x" \
    "rm -i /tmp/x" "unlink /tmp/x" "bash rm -rf /tmp/x"
  passes 'git commit -m "fix: refuse rm -rf / and find /tmp -delete"' "grep -rn 'rm -rf /' docs" \
    $'cat > notes.md <<\'EOF\'\nrm -rf /tmp/x\nfind / -delete\nEOF' "echo 'rm -rf /tmp/x' > notes.md" \
    "rg -n 'rm -rf \$T' ."
}

@test "a refusal tells a worker to report it and go on by the allowed way" {
  AGENT_TEAM_ROLE=builder guard -2 "rm -rf /tmp/x"
  assert_equal "$stderr" "Blocked by command-guard: a recursive delete of $TMP/x, $OUTSIDE; the allowed way: $DELETE_WAY. A guardrail: report it as BLOCKED, saying you took the allowed way, and go on only by that way."
}

@test "the delete rows come after the kill rows, outside first, then kept, then unread" {
  guard -2 "rm -rf /tmp/x; pkill x"
  assert_equal "$stderr" "Blocked by command-guard: a kill by name or pattern (pkill), which reaches every task's processes and the team's own sessions; the allowed way: find your own process's PID (pgrep -af <pattern>, or the \$! you noted when you started it) and kill that literal PID in a call of its own, which passes when the process is yours and its working directory is inside your worktree or your job's tmp. A guardrail: do not reach it another way."
  refuses "a recursive delete of $TMP/x, $OUTSIDE" "$DELETE_WAY" 'rm -rf "$T" . /tmp/x'
  refuses "a recursive delete of $WT, $KEPT" "$DELETE_WAY" 'rm -rf "$T" .'
}

# A name split by quotes or a backslash, a brace list, ANSI-C quoting or a script that printf
# decodes is the name Bash runs.
@test "a recursive delete spelled with quotes, a backslash, a brace list, ANSI-C quoting or in a decoded script is refused" {
  refuses "a recursive delete of $TMP/x, $OUTSIDE" "$DELETE_WAY" "r''m -rf /tmp/x" '"r"m -rf /tmp/x' 'r\m -rf /tmp/x' \
    "{rm,-rf,/tmp/x}" "sudo {rm,-rf,/tmp/x}" "\$'\\x72m' -rf /tmp/x" "\$'\\162m' -rf /tmp/x" \
    $'printf \'\\x72m -rf /tmp/x\\n\' > x.sh; bash x.sh' $'printf \'%sm -rf /tmp/x\\n\' r > x.sh; bash x.sh'
  refuses "$FIND $TMP, $OUTSIDE" "$DELETE_WAY" "fi''nd /tmp -delete" "{find,/tmp,-delete}"
  passes "echo {rm,-rf,/tmp/x}" "{rm,-rf,build}"
}

# A glob's matches are where it deletes, and a .. after it climbs from each of them.
@test "a glob followed by more of the path is judged as written and on what it matches" {
  refuses "a recursive delete of $BATS_TEST_TMPDIR/x, $OUTSIDE" "$DELETE_WAY" "rm -rf src/*/../../../x" \
    "rm -rf build/*/../../../x"
  refuses "a recursive delete of $WT/.scratch/task, $KEPT" "$DELETE_WAY" "rm -rf src/*/../../.scratch/task"
  ln -s "$OUT" "$WT/build/l"
  refuses "a recursive delete of $OUT/x, $OUTSIDE" "$DELETE_WAY" "rm -rf build/*/x" "rm -rf build/[l]/x"
  passes "rm -rf src/*/x" "rm -rf src/*/../build" "rm -rf build/*"
}

@test "find's -- before its start paths and its -files0-from list are read" {
  CWD=$WT/src
  refuses "$FIND $TMP/x, $OUTSIDE" "$DELETE_WAY" "find -- /tmp/x -delete" "find -L -- /tmp/x -delete" \
    "find -- /tmp/x -exec rm -rf {} +"
  refuses "$FIND -files0-from's list, $UNREAD" "$UNREAD_WAY" "find -files0-from list -delete" \
    "find -files0-from list -exec rm -rf {} +"
  passes "find -- . -delete" "find -files0-from list -print"
}

# shopt's cdable_vars makes a cd follow a variable, and its extglob makes @(...), !(...), +(...),
# ?(...) and *(...) patterns, which the walk reads as subshells.
@test "after cdable_vars a relative delete is unread, and after extglob so is a delete in a call holding a pattern" {
  refuses "a recursive delete of x, $UNREAD" "$UNREAD_WAY" $'T=/tmp\nshopt -s cdable_vars\ncd T; rm -rf x' \
    "shopt -s cdable_vars; rm -rf x"
  refuses "a recursive delete of an extglob pattern, $UNREAD" "$UNREAD_WAY" $'shopt -s extglob\nrm -rf @(.scratch)' \
    $'shopt -s extglob\nrm -rf +(.scratch)' $'shopt -s extglob\nrm -rf !(build)' \
    $'shopt -s extglob\nrm -rf build/@(a|b)' $'shopt -s extglob\nrm -rf build/*(x)'
  refuses "$FIND an extglob pattern, $UNREAD" "$UNREAD_WAY" $'shopt -s extglob\nfind @(.scratch) -delete'
  passes "shopt -s cdable_vars; rm -rf $WT/build" $'shopt -s extglob\nrm -rf build/x' "rm -rf build/x; (cd src)"
}
