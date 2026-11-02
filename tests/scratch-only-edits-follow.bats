#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: what the hook follows through a command to work out where a target
# lands: the directory the shell is in, and the values of HOME, TMPDIR and CLAUDE_JOB_DIR.
# It follows a cd by the order rule: each command leaves the directories the shell may be in when
# it succeeded and when it failed, and a relative target is judged from each one; it keeps the
# three variables' values only in a command that cannot change them.

load helpers/common
load helpers/scratch-hook

setup() {
  scratch_setup
}

@test "a relative target is judged from the directory a cd before it moves to" {
  passes "cd .scratch/task && cat > review.md <<'EOF'"$'\n# Review\nEOF' \
    "cd $wt/.scratch/task && cat > review.md <<'EOF'"$'\n# Review\nEOF' \
    "cd ~/wt/.scratch/task && cat > review.md <<'EOF'"$'\n# Review\nEOF' \
    "mkdir -p .scratch/task/tickets && cd .scratch/task/tickets && cat > 01-x.md <<'EOF'"$'\n# 01\nEOF' \
    'cd .scratch/task && { cmd > a; cmd > b; }' '(cd .scratch/task && cmd > out)' 'cd .scratch && cd task && cmd > out' \
    'cd "$CLAUDE_JOB_DIR/tmp" && cmd > out' 'cd $TMPDIR && cmd > x' 'cd && cd wt/.scratch && cmd | tee x' \
    'cd -L .scratch && cmd > x' 'cd -P -- .scratch && cmd > x' 'cd .. && cmd > wt/.scratch/x' 'cd src/../.scratch && cmd > x'
}

@test "a cd out of the allowed places is followed there" {
  blocked 'cd /etc && echo > .scratch/x' /etc/.scratch/x
  blocked 'cd .scratch && cmd > ../x' "$wt/x"
  blocked 'cd src && cd .scratch/task && cmd > x' "$wt/src/.scratch/task/x"
  blocked 'cd && cmd > x' "$HOME/x"
}

@test "a relative target after a cd that may have failed is judged from where the shell stays" {
  unknown 'cd .scratch/task; cat > review.md' "review.md ($failed)"
  unknown 'cd $TMPDIR; cmd > a; cmd | tee b' "a ($failed), b ($failed)"
  blocked 'cd .scratch/task || cmd > out' "$wt/out"
  blocked '! cd .scratch/task && cmd > out' "$wt/out"
  # Outside from the directory the cd moves to, the target is named.
  blocked 'cd /etc; cmd > .scratch/x' /etc/.scratch/x
  blocked 'cd src; cmd > x' "$wt/src/x, $wt/x"
  # A cd to an empty directory name stays put, as some shells read it, and bash refuses it.
  passes 'cd "" && cmd > .scratch/x'
}

@test "a cd the hook cannot follow loses the directory, and an absolute target or cd after it is judged" {
  local cd
  for cd in 'cd "$x"' 'cd -' 'pushd .scratch' 'popd' 'command cd .scratch' '/usr/bin/cd .scratch' 'cd a b' \
    'cd -e .scratch' 'cd $(pwd)' 'cd .scratch/*' 'cd $OLDPWD'; do
    unknown "$cd && cmd > out" "out ($moved)"
  done
  passes 'cd "$x" && cmd > $TMPDIR/x' 'cd "$x"; cd $TMPDIR && cmd > x' "pushd /etc; cmd > $wt/.scratch/x"
  # A pushd that fails stays put.
  shell -2 'pushd .scratch || cmd > x; cmd > y'
  assert_equal "$stderr" "Blocked: this hook cannot tell where these targets point: y ($moved); spell each path out, or write files under $wt/.scratch with the Write tool.
Blocked: this role may write files only under $wt/.scratch; write there with the Write tool, not a shell redirection or tee (tried $wt/x)."
}

@test "past 16 directories the shell may be in, the directory is unknown" {
  passes 'cd a; cd a; cd a; cd a; cmd > $TMPDIR/x' 'cd a; cd a; cd a; cd a; cd a; cmd > $TMPDIR/x'
  unknown 'cd .scratch/a; cd b; cd c; cd d; cd e; cmd > x' "x ($moved)"
}

@test "a pipeline, a subshell, a substitution and a background list keep their cd to themselves" {
  passes '(cd /etc); cmd > .scratch/x' 'x=$(cd /etc && pwd); cmd > .scratch/x' 'cd /etc | cat; cmd > .scratch/x' \
    'cd /etc & cmd > .scratch/x' 'cmd <(cd /etc) > .scratch/x' 'cat <<EOF > .scratch/x'$'\n$(cd /etc)\nEOF'
  blocked '{ cd /etc; }; cmd > .scratch/x' /etc/.scratch/x
}

@test "after if, case and a loop, the shell may be in any directory a path through it leaves" {
  blocked 'if c; then cd /etc; fi; cmd > .scratch/x' /etc/.scratch/x
  blocked 'if cd /etc; then :; fi; cmd > .scratch/x' /etc/.scratch/x
  passes 'if cd .scratch; then cmd > x; fi' 'if c; then cd .scratch; elif d; then cd .scratch/task; fi; cmd > .scratch/x'
  blocked 'if cd .scratch; then :; else cmd > x; fi' "$wt/x"
  blocked 'case $1 in a) cd /etc ;; esac; cmd > .scratch/x' /etc/.scratch/x
  passes 'case $1 in a) cd /etc ;; b) cmd > .scratch/x ;; esac'
  blocked 'case $1 in a) cd /etc ;& b) cmd > .scratch/x ;; esac' /etc/.scratch/x
  blocked 'case $1 in a) cd /etc ;;& b) cmd > .scratch/x ;; esac' /etc/.scratch/x
}

@test "a loop that holds a cd in its own shell loses the directory from its start" {
  unknown 'for d in a b; do cd $d; cmd > x; done' "x ($moved)"
  unknown 'while c; do cmd > .scratch/x; cd /etc; done' ".scratch/x ($moved)"
  unknown 'for f in a b; do cmd > .scratch/x; cd /tmp/..; done' ".scratch/x ($moved)"
  unknown 'until c; do cmd | tee .scratch/x; pushd /; done' ".scratch/x ($moved)"
  unknown 'for ((i = 0; i < 2; i++)); do cmd > .scratch/x; { cd /; }; done' ".scratch/x ($moved)"
  unknown 'for f in a; do cd /etc; done; cmd > .scratch/x' ".scratch/x ($moved)"
  # A cd in a subshell or a substitution in the loop stays there, and a loop's redirections are made
  # once, before it runs.
  passes 'for f in a; do cmd > .scratch/x; if :; then echo "$(cd /)"; (cd /etc); fi; done' \
    'while cd x; do :; done > .scratch/x' 'cmd > .scratch/x; while :; do cd x; done'
}

@test "a function's body is judged where it is defined, with the directory lost when the command holds a cd" {
  unknown 'f() { cd /etc; }; f; cmd > .scratch/x' ".scratch/x ($moved)"
  unknown 'f() { cmd > out; }; cd .scratch' "out ($moved)"
  unknown 'f() { cmd > .scratch/x; }; cd /etc; f' ".scratch/x ($moved)"
  unknown 'f() { cmd > .scratch/x; }; for f in a; do { cd /; }; done' ".scratch/x ($moved)"
  passes 'f() { cmd > .scratch/x; }; f; f' 'f() { (cd /etc); }; f; cmd > .scratch/x'
}

@test "cd -P resolves symlinks, and cd and cd -L resolve .. by text, as bash does" {
  mkdir -p "$HOME/elsewhere/sub"
  ln -s "$HOME/elsewhere" "$wt/.scratch/out"
  ln -s "$wt/.scratch/task" "$wt/src/in"
  passes 'cd .scratch/out/.. && cmd > x' 'cd -L .scratch/out/.. && cmd > x'
  blocked 'cd -P .scratch/out/.. && cmd > x' "$HOME/x"
  blocked 'cd src/in/.. && cmd > x' "$wt/src/x"
  passes 'cd -P src/in/.. && cmd > x'
  # When the directory by text does not exist, bash goes where the path leads by its symlinks.
  blocked 'cd .scratch/out/../sub && cmd > x' "$HOME/sub/x"
}

@test "a relative target after a cd into a symlinked directory is judged with its symlinks resolved" {
  ln -s "$HOME/elsewhere" "$wt/.scratch/out"
  ln -s "$wt/.scratch/task" "$wt/src/in"
  blocked 'cd .scratch/out && cmd > x' "$wt/.scratch/out/x"
  passes 'cd src/in && cmd > x' 'cd -P src/in && cmd | tee x'
}

@test "with CDPATH set in the hook's environment, a cd to a name it may search is unknown" {
  CDPATH=$wt/.scratch unknown 'cd task && cmd > x' "x ($moved)"
  CDPATH=$wt/.scratch unknown 'cd .scratch && cmd > x' "x ($moved)"
  CDPATH=$wt/.scratch passes 'cd ./.scratch && cmd > x' 'cd ../wt/.scratch/task && cmd > x' "cd $wt/.scratch && cmd > x" 'cd .. && cmd > wt/.scratch/x'
}

@test "\$PWD stands for each directory the shell may be in, and \$OLDPWD for an unknown one" {
  passes 'cd .scratch && cmd > $PWD/x' 'cd .scratch && cmd > "${PWD}/x"' 'cd .scratch && cd $PWD/task && cmd > x'
  blocked 'cmd > $PWD/x' "$wt/x"
  unknown 'cd .scratch; cmd > $PWD/x' "\$PWD/x ($failed)"
  unknown 'cd "$x"; cmd > $PWD/x' "\$PWD/x ($moved)"
  unknown 'cd .scratch && cmd > $OLDPWD/x' "\$OLDPWD/x ($expansion)"
  unknown 'PWD=/tmp; cmd > $PWD/x' "\$PWD/x ($expansion)"
  unknown 'for PWD in /tmp; do cmd > $PWD/x; done' "\$PWD/x ($expansion)"
}

@test "a command's redirections are judged in the directory it starts in, before its own cd" {
  blocked 'cd .scratch/task > out' "$wt/out"
  blocked '{ cd .scratch; } > x' "$wt/x"
  passes 'cd .scratch && cmd > a 2> b' 'cd /etc && cmd > $TMPDIR/x' "cd /etc && cmd > $wt/.scratch/x"
}

@test "eval, source, ., trap or a command word the hook cannot name may move the shell at any later point" {
  local before
  for before in 'eval "$x"' 'source f' '. f' 'trap x EXIT' '"$tool" a' '$x' '/usr/bin/t?e'; do
    unknown "$before; cmd > .scratch/x" ".scratch/x ($moved)"
    # A trap it sets, or a function it defines, may run at any command after it, so a cd after it is
    # no longer followed.
    unknown "$before; cd $wt/.scratch && cmd > x" "x ($moved)"
  done
  unknown "while c; do cd $wt/.scratch && cmd > x; eval \"\$y\"; done" "x ($moved)"
  unknown "f() { eval \"\$y\"; }; cd $wt/.scratch && cmd > x" "x ($moved)"
  # In a subshell or a substitution, it reaches no further.
  passes "(eval \"\$y\"); cd $wt/.scratch && cmd > x" "v=\$(source f); cd $wt/.scratch && cmd > x"
}

@test "HOME, TMPDIR and CLAUDE_JOB_DIR keep the hook's values in a command that cannot change them" {
  mkdir -p "$job/tmp"
  passes 'export X=1; cmd > $TMPDIR/x' 'printf x; cmd > "$TMPDIR/x"' 'read -r line; cmd > $CLAUDE_JOB_DIR/tmp/x' \
    'unset X; cmd > ~/wt/.scratch/x' 'env TMPDIR=/etc cmd > $TMPDIR/x' 'X=1 cmd > ${HOME}/wt/.scratch/x' \
    'declare -x X=1; cmd > $TMPDIR/x' 'echo eval source let > $TMPDIR/x' 'printf "%s" "$x"; cmd > $TMPDIR/x'
}

@test "HOME, TMPDIR and CLAUDE_JOB_DIR are unknown in a command that may assign one" {
  local before
  for before in 'TMPDIR=/etc' 'TMPDIR+=/x' 'export TMPDIR=/etc' 'TMPDIR=/etc cmd' 'TMPDIR[0]=/etc' 'read TMPDIR' \
    'read -r a TMPDIR' 'unset TMPDIR' 'declare -x TMPDIR' 'local TMPDIR' 'printf -v TMPDIR x' 'getopts ab TMPDIR' \
    'builtin read TMPDIR' 'export "TMP""DIR=/etc"'; do
    unknown "$before; cmd > \$TMPDIR/x" "\$TMPDIR/x ($expansion)"
  done
  unknown 'HOME=/etc; cmd > ~/x' "~/x ($expansion)"
  unknown 'for TMPDIR in /etc; do cmd > $TMPDIR/x; done' "\$TMPDIR/x ($expansion)"
  unknown 'unset CLAUDE_JOB_DIR; cmd > "$CLAUDE_JOB_DIR/x"' "\"\$CLAUDE_JOB_DIR/x\" ($expansion)"
}

@test "HOME, TMPDIR and CLAUDE_JOB_DIR are unknown after anything that may assign a variable it does not name" {
  local before
  for before in 'eval "$x"' 'source f' '. f' 'trap x EXIT' 'let v' 'declare -i n' 'typeset -n r=x' 'local -i n' \
    'mapfile -C f a' 'readarray -tC f a' 'read "$n"' 'printf -v "$n" x' 'printf "$f" x' 'export "$n"' 'a[v]=1' '"$tool" a'; do
    unknown "$before; cmd > \$TMPDIR/x" "\$TMPDIR/x ($expansion)"
  done
}

@test "HOME, TMPDIR and CLAUDE_JOB_DIR are unknown after arithmetic or a \${ } that may assign a variable" {
  local before
  for before in 'echo $(( x ))' '(( i++ ))' 'for (( i = 0; i < 1; i++ )); do :; done' '[[ $a -eq 1 ]]' 'echo ${x:$o}' \
    'echo ${a[i]}' 'a=([i]=1)' 'echo ${TMPDIR:=/etc}' 'echo ${x=a}'; do
    unknown "$before; cmd > \$TMPDIR/x" "\$TMPDIR/x ($expansion)"
  done
  passes 'echo $(( 1 + 2 )); cmd > $TMPDIR/x' 'echo ${x:1} ${a[0]} ${x:-a}; cmd > $TMPDIR/x' 'a=(i 1); [[ $a == 1 ]]; cmd > $TMPDIR/x'
}

@test "any other variable in a target is unknown" {
  unknown 'cmd > $HOMEDIR/x' "\$HOMEDIR/x ($expansion)"
  unknown 'cmd > .scratch/$x/y' ".scratch/\$x/y ($expansion)"
  unknown 'x=.scratch; cmd > $x/y' "\$x/y ($expansion)"
}

@test "an unquoted value holding a blank is unknown, as bash splits it, and a quoted one is judged" {
  hook_tmpdir="$BATS_TEST_TMPDIR/t mp"
  unknown 'cmd | tee $TMPDIR/x' "\$TMPDIR/x ($expansion)"
  passes 'cmd | tee "$TMPDIR/x"' 'cmd > "${TMPDIR}"/x'
}
