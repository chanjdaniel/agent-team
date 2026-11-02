#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: what the hook follows through a command to work out where a target
# lands: the directory the shell is in, and the values of HOME, TMPDIR and CLAUDE_JOB_DIR.
# The hook does not follow a cd yet, so a relative target after one is unknown; and it keeps the
# three variables' values only in a command that cannot change them.

load helpers/common
load helpers/scratch-hook

setup() {
  scratch_setup
}

@test "a relative target after a cd, pushd or popd is unknown" {
  unknown 'cd .scratch && cmd > x' "x ($moved)"
  unknown 'cd .scratch/task; cat > review.md' "review.md ($moved)"
  unknown 'pushd .scratch; cmd > x' "x ($moved)"
  unknown 'popd; cmd | tee x' "x ($moved)"
  unknown 'command cd .scratch && cmd > x' "x ($moved)"
  unknown '/usr/bin/cd .scratch && cmd > x' "x ($moved)"
  unknown 'cd .scratch && cmd > a 2> b' "a ($moved), b ($moved)"
}

@test "a relative target before a cd, and an absolute one after it, are judged" {
  passes 'cmd > .scratch/x; cd /etc' "cd /etc && cmd > $wt/.scratch/x" 'cd /etc && cmd > $TMPDIR/x'
  blocked 'cd /etc && cmd > /etc/x' /etc/x
  # A command's redirections are made before it runs, in the directory it starts in.
  blocked 'cd .scratch > x' "$wt/x"
}

@test "eval, source, ., trap or a command word the hook cannot name may move the shell too" {
  local before
  for before in 'eval "$x"' 'source f' '. f' 'trap x EXIT' '"$tool" a' '$x' '/usr/bin/t?e'; do
    unknown "$before; cmd > .scratch/x" ".scratch/x ($moved)"
  done
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
  unknown 'unset CLAUDE_JOB_DIR; cmd > "$CLAUDE_JOB_DIR/x"' "\"\$CLAUDE_JOB_DIR/x\" ($expansion)"
}

@test "HOME, TMPDIR and CLAUDE_JOB_DIR are unknown after anything that may assign a variable it does not name" {
  local before
  for before in 'eval "$x"' 'source f' '. f' 'trap x EXIT' 'let v' 'declare -i n' 'typeset -n r=x' 'local -i n' \
    'mapfile -C f a' 'readarray -tC f a' 'read "$n"' 'printf -v "$n" x' 'printf "$f" x' 'export "$n"' 'a[v]=1' '"$tool" a'; do
    unknown "$before; cmd > \$TMPDIR/x" "\$TMPDIR/x ($expansion)"
  done
}

@test "any other variable in a target is unknown" {
  unknown 'cmd > $HOMEDIR/x' "\$HOMEDIR/x ($expansion)"
  unknown 'cmd > .scratch/$x/y' ".scratch/\$x/y ($expansion)"
  unknown 'cmd > $PWD/.scratch/x' "\$PWD/.scratch/x ($expansion)"
  unknown 'x=.scratch; cmd > $x/y' "\$x/y ($expansion)"
}

@test "an unquoted value holding a blank is unknown, as bash splits it, and a quoted one is judged" {
  hook_tmpdir="$BATS_TEST_TMPDIR/t mp"
  unknown 'cmd | tee $TMPDIR/x' "\$TMPDIR/x ($expansion)"
  passes 'cmd | tee "$TMPDIR/x"' 'cmd > "${TMPDIR}"/x'
}
