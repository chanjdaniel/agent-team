#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: what the hook follows through a command to work out where a target
# lands: the directory the shell is in, and the values of the variables the command assigns once.
# It follows both by the order rule: each command leaves the directories the shell may be in and
# the values each variable may hold when it succeeded and when it failed, and a target is judged
# from each; arithmetic and the other places that may assign any variable stop the following.

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

@test "a relative target after a cd that may not have run, its and-or list cut short, says the cd may have failed" {
  unknown "mkdir -p .scratch/task/tickets && cd .scratch/task/tickets && cat > 01-x.md <<'EOF'"$'\n# 01\nEOF\ncat > 02-y.md <<\'EOF\'\n# 02\nEOF' \
    "02-y.md ($failed)"
  unknown $'test -d .scratch || cd .scratch\ncmd > x' "x ($failed)"
  # Joined by &&, it passes.
  passes "mkdir -p .scratch/task/tickets && cd .scratch/task/tickets && cat > 01-x.md <<'EOF' && cat > 02-y.md <<'EOF'"$'\n# 01\nEOF\n# 02\nEOF'
  # Outside from every directory, the target is named.
  blocked $'mkdir -p src && cd src\ncmd > x' "$wt/src/x, $wt/x"
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

@test "a cd word worked out only through variables is judged by its values, and refused unread when one may be an option" {
  # bash's cd parses the value: -P, -L or -- is an option, and with no word after it cd goes to $HOME.
  local o
  for o in -P -- -L; do
    unread "o=$o; cd ./.scratch && cd \$o && cmd > x" 'the cd word $o'
    unread "o=$o; cd ./.scratch && cd \"\$o\" && cmd > x" 'the cd word "$o"'
  done
  # A basename's name may start with a -.
  unread 'cd .scratch && cd "$(basename "$f")" && cmd > x' 'the cd word "$(basename "$f")"'
  # A value that starts with no - is the directory, and after -- every value is.
  passes 'd=.scratch/task; cd "$d" && cmd > x' 'd=$(mktemp -d) && cd "$d" && cmd > x' 'o=-P; cd .scratch && cd -- "$o" && cmd > x' \
    'cd "$CLAUDE_JOB_DIR" && cmd > x'
}

@test "an unquoted cd word whose value may be empty may be no word, so cd alone, to \$HOME" {
  # bash removes an unquoted word whose expansion is empty.
  local cd
  for cd in 'cd $o' 'cd -- $o' 'cd -P ${o}' 'cd $o$p'; do
    blocked "o=; p=; cd ./.scratch && $cd && cmd > x" "$HOME/x"
  done
  # One that may be empty or not leaves the directory unknown, and so does an empty one when the walk
  # does not know HOME.
  unknown 'cd ./.scratch && for o in task ""; do (cd $o && cmd > x); done' "x ($moved)"
  unknown 'HOME=$(cmd); o=; cd ./.scratch && cd $o && cmd > x' "x ($moved)"
  # A quoted empty word is a word, which stays put.
  passes 'o=; cd ./.scratch && cd "$o" && cmd > x'
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

@test "after a place that may assign any variable, a cd to a name CDPATH may search is unknown" {
  local before
  for before in 'a[v]=1' 'let v' 'declare -n r="$n"; r=/' '(( v ))'; do
    unknown "$before; cd .scratch/task && cmd > out" "out ($moved)"
    passes "$before; cd ./.scratch/task && cmd > out" "$before; cd $wt/.scratch && cmd > out"
  done
}

@test "\$PWD stands for each directory the shell may be in, and \$OLDPWD for an unknown one" {
  passes 'cd .scratch && cmd > $PWD/x' 'cd .scratch && cmd > "${PWD}/x"' 'cd .scratch && cd $PWD/task && cmd > x'
  blocked 'cmd > $PWD/x' "$wt/x"
  unknown 'cd .scratch; cmd > $PWD/x' "\$PWD/x ($failed)"
  unknown 'cd "$x"; cmd > $PWD/x' "\$PWD/x ($moved)"
  unknown 'cd .scratch && cmd > $OLDPWD/x' "\$OLDPWD/x ($expansion)"
  unknown 'PWD=/tmp; cmd > $PWD/x' "\$PWD/x ($(not_followed PWD))"
  unknown 'for PWD in /tmp; do cmd > $PWD/x; done' "\$PWD/x ($(not_followed PWD))"
}

@test "after a stop, \$PWD is unknown until a cd the walk follows sets it again" {
  local before
  for before in '(( v ))' 'a[v]=1' ': $(( v ))' 'let v'; do
    unknown "$before; cmd > \"\$PWD/x\"" "\"\$PWD/x\" ($(not_followed PWD))" "$wt/.scratch/task"
    unknown "$before; cmd > \"\${PWD}/x\"" "\"\${PWD}/x\" ($(not_followed PWD))" "$wt/.scratch/task"
    passes "$before; cd ./.scratch && cmd > \"\$PWD/x\"" "cd ./.scratch && cmd > \"\$PWD/x\"; $before"
  done
  unknown '(( v )); cd "$x"; cmd > "$PWD/x"' "\"\$PWD/x\" ($moved)"
}

@test "a command's redirections are judged in the directory it starts in, before its own cd" {
  blocked 'cd .scratch/task > out' "$wt/out"
  blocked '{ cd .scratch; } > x' "$wt/x"
  passes 'cd .scratch && cmd > a 2> b' 'cd /etc && cmd > $TMPDIR/x' "cd /etc && cmd > $wt/.scratch/x"
}

@test "eval, source, . or trap may move the shell at any later point" {
  local before
  for before in 'eval "$x"' 'source f' '. f' 'trap x EXIT'; do
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


@test "a command word whose every value the walk knows names that program, and neither moves the shell nor stops the following" {
  mkdir -p "$job/tmp"
  passes 'T=.scratch/task/try; I=$T/tools/bin/probe; $I detect --json src/ > $T/out.json 2>$T/out.err' \
    'T=$CLAUDE_JOB_DIR/tmp/probe; C=$T/code/bin/x; $C a; cd .scratch/task && cmd > b; echo s > $T/c' \
    "\$PWD/bin/x; cd $wt/.scratch && cmd > y" \
    'T=$CLAUDE_JOB_DIR/tmp; for i in 1 2; do "$T/v$i/bin/pip" freeze > $T/f$i; done' \
    'T=$CLAUDE_JOB_DIR/tmp; for c in /opt/a /opt/b; do cmd > $T/x; $c; done' \
    'T=$CLAUDE_JOB_DIR/tmp; I=/opt/bin/x; while c; do cmd > $T/x; $I; done' \
    'A=chrome-devtools-axi; $A eval "() => 1" > .scratch/y; cd .scratch && $A snapshot > z' \
    'X=.scratch; for a in jq yq; do $a . f > $X/y; done'
  # A value that is a builtin, a reserved word, a function the command defines, a tee, a wrapper or
  # a shell, one holding a blank, a glob, a brace, a quote or a backslash, an unknown one, and a word
  # holding another expansion are refused unread, as is one the walk cannot work out at every turn
  # of a loop or every call of a function.
  local before word
  for before in 'I=eval; $I a' 'I=cd; $I /etc' 'I=if; $I' 'I=f; f() { :; }; $I' 'I=tee; $I x' 'I=/usr/bin/tee; $I src/x' \
    'I=env; $I tee x' 'I=/usr/bin/env; $I tee src/x' 'I=/bin/bash; $I' 'I="/opt/x a"; "$I"' "I='x*'; \"\$I\"" \
    "I='x{a,b}'; \"\$I\"" "I='x\\y'; \"\$I\"" 'I=/opt/x; I=eval; $I a' 'I="/opt/x a"; $I' \
    'eval x; I=/opt/x; $I' '$J/bin/x'; do
    word=${before##*; }
    unread "$before; cmd > .scratch/y" "the command word ${word%% *}"
  done
  unread 'for c in /opt/a eval; do cmd > .scratch/y; $c; done' 'the command word $c'
  unread 'I=/opt/x; f() { $I; }; cmd > .scratch/y' 'the command word $I'
  unread 'I=$(command -v x); "$I" > .scratch/y' 'the command word "$I"'
  # Assigned in the loop before it runs, it holds that value at every turn.
  passes 'X=.scratch; while c; do cmd > $X/y; I=/opt/x; $I; done'
}

@test "a variable the command assigns once holds its value after the assignment, and its earlier one before" {
  mkdir -p "$job/tmp"
  passes 'T=$CLAUDE_JOB_DIR/tmp; cmd > $T/out.log' 'export TMPDIR=$CLAUDE_JOB_DIR/tmp; cmd > $TMPDIR/x' \
    'P=.scratch/task/probe; cmd > $P/x' 'T=$CLAUDE_JOB_DIR/tmp; for f in a b; do cmd > $T/$f.log; done' \
    'x=src; x2=.scratch/x; cmd > $x2' 'a=.scratch b=$a/x; cmd | tee "$b"' 'export A=.scratch B=$TMPDIR; cmd > $A/x 2> $B/y' \
    'T=$CLAUDE_JOB_DIR/tmp && cmd > "${T}/x"' 'cd .scratch && { P=$PWD; cmd > $P/x; }' 'cmd > $TMPDIR/x; TMPDIR=/etc'
  blocked 'x=src; cmd > $x/y' "$wt/src/y"
  blocked 'T=/etc; cmd | tee $T/x' /etc/x
  blocked 'HOME=/etc; cmd > ~/x' /etc/x
  unknown 'cmd > $x/y; x=.scratch' "\$x/y ($(not_followed x))"
  # A variable the command never assigns is one it does not follow.
  unknown 'cmd > $HOMEDIR/x' "\$HOMEDIR/x ($expansion)"
  unknown 'cmd > .scratch/$x/y' ".scratch/\$x/y ($expansion)"
}

@test "a command of assignments alone makes its redirections after them, as bash does" {
  blocked 'x=src > $x/y' "$wt/src/y"
  passes 'x=.scratch > $x/y'
}

@test "a variable assigned twice, by a builtin or a \${ } operator, or where the assignment may not have run, is not followed" {
  local before
  for before in 'x=a; x=src' 'read x' 'printf -v x src' 'declare x=.scratch' ': ${x:=src}' ': ${x=src}' 'x=.scratch cmd' \
    'x+=.scratch' 'x=(.scratch)' 'local x=.scratch' 'readonly x=.scratch' 'export x; x=.scratch' 'getopts ab x' \
    'mapfile x' 'unset x; x=.scratch' 'wait -p x' 'export "x=.scratch"' 'cd .scratch && x=task' 'if c; then x=.scratch; fi' \
    'x=.scratch; printf -vx src' 'x=.scratch; read -rax' 'x=.scratch; wait -px' 'export x=.scratch/{a,..}' \
    'export x=.scratch/{a}'; do
    unknown "$before; cmd > \$x/y" "\$x/y ($(not_followed x))"
  done
  unknown 'for x in $(ls); do cmd > $x; done' "\$x ($(not_followed x))"
  unknown 'for x; do cmd > $x; done' "\$x ($(not_followed x))"
  unknown 'cd .scratch && P=task; cmd > $P/x' "\$P/x ($(not_followed P))"
  for before in 'read TMPDIR' 'TMPDIR=/etc cmd' 'export "TMP""DIR=/etc"' 'builtin read -r a TMPDIR' 'TMPDIR[0]=/etc'; do
    unknown "$before; cmd > \$TMPDIR/x" "\$TMPDIR/x ($(not_followed TMPDIR))"
  done
  # env's assignments are the command's it runs, not the shell's; export brace-expands only an
  # unquoted brace.
  passes 'env TMPDIR=/etc cmd; cmd > $TMPDIR/x' "export x='.scratch/{a,..}'; cmd > \"\$x/y\""
}

@test "a variable whose value bash sets itself is never followed" {
  local name
  for name in REPLY OPTARG OPTIND PATH OLDPWD RANDOM BASH_X; do
    unknown "$name=.scratch; cmd > \$$name/x" "\$$name/x ($(not_followed "$name"))"
  done
}

@test "a for loop's variable holds each value of its words, read as bash reads a for list" {
  passes 'for f in .scratch/a "$TMPDIR/b c"; do cmd > "$f"; done' 'for d in .scratch $TMPDIR; do cmd > $d/x; done'
  blocked 'for f in .scratch/a src/b; do cmd > $f; done' "$wt/src/b"
  unknown 'for f in .scratch/*; do cmd > $f; done' "\$f ($(not_followed f))"
  unknown 'for f in "$TMPDIR/b c"; do cmd | tee -- $f; done' "\$f ($expansion)"
  # After the loop, it holds a value of its words, or the one before when no word gave any.
  passes 'for TMPDIR in .scratch/a; do :; done; cmd > $TMPDIR/x'
  blocked 'for TMPDIR in src; do :; done; cmd > $TMPDIR/x' "$wt/src/x"
  unknown 'for x in .scratch/a; do :; done; cmd > $x' "\$x ($(not_followed x))"
}

@test "arithmetic and the other places that may assign any variable stop following there, and an assignment after them is followed" {
  local before
  for before in '(( v ))' ': $(( v ))' 'let v' '[[ v -eq 1 ]]' 'echo ${a[v]}' 'echo ${x:$o}' 'a[v]=1' \
    'a=([v]=1)' 'for (( ; v; )); do :; done'; do
    unknown "T=\$CLAUDE_JOB_DIR/tmp; $before; cmd > \$T/x" "\$T/x ($(not_followed T))"
  done
  unknown "T=\$CLAUDE_JOB_DIR/tmp; cat <<EOF"$'\n$(( v ))\nEOF\n'"cmd > \$T/x" "\$T/x ($(not_followed T))"
  passes '(( v )); T=.scratch; cmd > "$T/x"'
  # Naming no variable, it stops nothing; in a subshell, a substitution or a pipeline, it reaches no further.
  passes 'T=$CLAUDE_JOB_DIR/tmp; echo $(( 1 + 2 )) ${x:0:8} ${a[0]}; cmd > $T/x' \
    'T=$CLAUDE_JOB_DIR/tmp; (let v); y=$(let v); let v | cat; cmd > $T/x'
}

@test "after a stop, an unquoted variable is unknown, as IFS may have changed with it" {
  unknown 'x=.scratch/a; (( v )); y=.scratch/b; cmd | tee -- $y' "\$y ($expansion)"
  passes 'x=.scratch/a; (( v )); y=.scratch/b; cmd | tee "$y"'
  unknown '(( v )); cd ./.scratch && cmd > $PWD/x' "\$PWD/x ($expansion)"
  passes '(( v )); cd ./.scratch && cmd > "$PWD/x"'
}

@test "a stop makes HOME, TMPDIR and CLAUDE_JOB_DIR unknown too, as it may assign them, and an assignment after it is followed" {
  local before
  for before in '(( v ))' 'let v' 'a[v]=1' ': $(( v ))'; do
    unknown "$before; cmd > \"\$TMPDIR/x\"" "\"\$TMPDIR/x\" ($(not_followed TMPDIR))"
  done
  unknown '(( v )); cmd > ~/x' "~/x ($(not_followed HOME))"
  unknown 'f() { cmd > "$CLAUDE_JOB_DIR/x"; }; (( v ))' "\"\$CLAUDE_JOB_DIR/x\" ($(not_followed CLAUDE_JOB_DIR))"
  passes '(( v )); TMPDIR=.scratch/t; cmd > "$TMPDIR/x"' 'cmd > "$TMPDIR/x"; (( v ))'
}

@test "eval, source, ., trap, mapfile -C, and declare, typeset or local with i or n end following for the rest of the command" {
  local before
  for before in 'eval x' 'source f' '. f' 'trap x EXIT' 'declare -i n' 'declare -n r=y' 'typeset -n r' 'local -i n' \
    'mapfile -C f a' 'readarray -tC f a'; do
    unknown "T=\$CLAUDE_JOB_DIR/tmp; $before; cmd > \$T/x" "\$T/x ($(not_followed T))"
    unknown "$before; T=\$CLAUDE_JOB_DIR/tmp; cmd > \"\$T/x\"" "\"\$T/x\" ($(not_followed T))"
  done
  unknown 'T=$CLAUDE_JOB_DIR/tmp; declare -n r=T; cmd > $T/x' "\$T/x ($(not_followed T))"
  unknown 'eval x; cmd > $TMPDIR/x' "\$TMPDIR/x ($(not_followed TMPDIR))"
  unknown 'mapfile -C f a; cd .scratch && cmd > x' "x ($moved)"
  # In a subshell or a substitution, it reaches no further.
  passes 'T=$CLAUDE_JOB_DIR/tmp; (eval x); y=$(source f); cmd > $T/x'
}

@test "a loop or a function whose body stops following, or assigns a followed variable, does so from its start or definition" {
  unknown 'T=$CLAUDE_JOB_DIR/tmp; while c; do cmd > $T/x; (( n++ )); done' "\$T/x ($(not_followed T))"
  unknown 'T=$CLAUDE_JOB_DIR/tmp; for f in a; do cmd > $T/x; eval x; done' "\$T/x ($(not_followed T))"
  unknown 'while c; do cmd > $TMPDIR/x; TMPDIR=/etc; done' "\$TMPDIR/x ($(not_followed TMPDIR))"
  passes 'while c; do T=.scratch; cmd > $T/x; done' 'T=.scratch; while c; do (( n++ )); done > $T/x'
  unknown 'f() { (( v )); }; T=$CLAUDE_JOB_DIR/tmp; f; cmd > $T/x' "\$T/x ($(not_followed T))"
  unknown 'f() { TMPDIR=/etc; }; f; cmd > $TMPDIR/x' "\$TMPDIR/x ($(not_followed TMPDIR))"
  unknown 'f() { eval x; }; T=$CLAUDE_JOB_DIR/tmp; cmd > $T/x' "\$T/x ($(not_followed T))"
}

@test "a function's body follows only those of HOME, TMPDIR and CLAUDE_JOB_DIR the command does not assign, and none when it stops or ends following" {
  mkdir -p "$job/tmp"
  passes 'f() { cmd > $TMPDIR/x; }; f' 'f() { cmd > "$CLAUDE_JOB_DIR/x"; }; T=$CLAUDE_JOB_DIR; cmd > $T/y'
  unknown 'f() { cmd > "$T/x"; }; T=$CLAUDE_JOB_DIR/tmp' "\"\$T/x\" ($(not_followed T))"
  unknown 'TMPDIR=/etc; f() { cmd > $TMPDIR/x; }' "\$TMPDIR/x ($(not_followed TMPDIR))"
  unknown 'f() { cmd > $TMPDIR/x; }; (( v ))' "\$TMPDIR/x ($(not_followed TMPDIR))"
  unknown 'f() { cmd > "$TMPDIR/x"; }; (( v ))' "\"\$TMPDIR/x\" ($(not_followed TMPDIR))"
  unknown 'f() { cmd > "$TMPDIR/x"; }; eval x' "\"\$TMPDIR/x\" ($(not_followed TMPDIR))"
}

@test "an unquoted value holding a blank or a glob is unknown, a quoted one is followed, and an assignment expands ~ only at its start" {
  unknown "x='.scratch/a b'; cmd | tee -- \$x" "\$x ($expansion)"
  unknown "x='.scratch/*'; cmd > \$x" "\$x ($expansion)"
  passes "x='.scratch/a b'; cmd | tee \"\$x\"" "x='.scratch/*'; cmd > \"\$x\"" 'x=.scratch/*; cmd > "$x"' \
    'x=~/wt/.scratch/y; cmd > $x'
  blocked 'x=~/y; cmd > $x' "$HOME/y"
  unknown 'x=a:~/y; cmd > $x' "\$x ($(not_followed x))"
  hook_tmpdir="$BATS_TEST_TMPDIR/t mp"
  unknown 'cmd | tee -- $TMPDIR/x' "\$TMPDIR/x ($expansion)"
  passes 'cmd | tee "$TMPDIR/x"' 'cmd > "${TMPDIR}"/x'
}

@test "a variable assigned a mktemp holds a new name in its directory when it succeeded, and the empty string when it failed" {
  mkdir -p "$job/tmp"
  passes 'd=$(mktemp -d) && cmd > $d/x' 'd=$(mktemp -d -p "$CLAUDE_JOB_DIR/tmp") && cmd > "$d/x"' 'f=$(mktemp) && cmd > $f' \
    'f=$(mktemp -t out.XXXXXX) && cmd | tee "$f"' 'd=$(mktemp -d --tmpdir) && cmd > $d/x' 'd=$(mktemp -dp .scratch) && cmd > $d/x' \
    'd=$(mktemp -d --tmpdir=.scratch/task) && cmd > $d/x' 'f=$(mktemp .scratch/out.XXXX) && cmd > $f' \
    'f=$(mktemp -p .scratch out.XXXX) && cmd > $f' 'export TMPDIR=$CLAUDE_JOB_DIR/tmp; d=$(mktemp -d) && cmd > $d/x' \
    'd="$(mktemp -d)" && cmd > "$d/x"' 'd=$(mktemp -q -u) && cmd > $d'
  shell -0 'f=$(mktemp out.XXXX) && cmd > $f' "$wt/.scratch"
  blocked 'd=$(mktemp -d -p src) && cmd > $d/x' "$wt/src/tmp.XXXXXXXXXX/x"
  blocked 'f=$(mktemp src/out.XXXX) && cmd > $f' "$wt/src/out.XXXX"
  blocked 'f=$(mktemp out.XXXX) && cmd > $f' "$wt/out.XXXX"
  blocked 'd=$(mktemp -d --tmpdir=src) && cmd > $d/x' "$wt/src/tmp.XXXXXXXXXX/x"
  blocked 'TMPDIR=/etc; d=$(mktemp -d) && cmd > $d/x' /etc/tmp.XXXXXXXXXX/x
  unknown 'd=$(mktemp -d); cmd > $d/x' "\$d/x ($(may_be_empty d))"
  local form
  for form in '/usr/bin/mktemp -d' 'mktemp -d -- "$x"' 'mktemp --suffix=.x' 'mktemp a.XX b.XX' 'mktemp 2> /dev/null' 'TMPDIR=. mktemp' \
    'command mktemp'; do
    unknown "d=\$($form) && cmd > \$d/x" "\$d/x ($(not_followed d))"
  done
  unknown 'cmd > $(mktemp)' "\$(mktemp) ($expansion)"
  # mktemp parses its words' values: one the hook works out only through variables, where an option
  # may stand, is refused unread when a value may be an option or is unknown.
  unread 'o=-p/etc; cd ./.scratch && d=$(mktemp -d $o) && cmd > "$d/x"' 'the mktemp word $o'
  unread 'o=--tmpdir=/etc; cd ./.scratch && d=$(mktemp -d "$o") && cmd > "$d/x"' 'the mktemp word "$o"'
  unread 'd=$(mktemp -d "$x") && cmd > $d/x' 'the mktemp word "$x"'
  passes 't=.scratch/out.XXXX; f=$(mktemp "$t") && cmd > $f' 'd=$(mktemp -d -p "$CLAUDE_JOB_DIR") && cmd > $d/x'
  # GNU's mktemp reads a word written -... after its template as an option, BSD's as another
  # template, and BSD's reads the word after -t as its prefix.
  unread 'd=$(mktemp .scratch/x.XXXX -d) && cmd > $d/y' 'the mktemp word -d'
  unread 'd=$(mktemp -t -d) && cmd > $d/y' 'the mktemp word -d'
  passes 'd=$(mktemp -dt x.XXXX) && cmd > $d/y'
}

@test "a basename substitution holds a name with no / in it, ., .., a lone / or nothing, each judged" {
  passes 'cmd > .scratch/task/capture/$(basename "$f")' 'cmd > ".scratch/task/capture/$(basename "$f" .md)"' \
    'cmd > .scratch/task/out-$(basename "$f").json' 'b=$(basename "$f"); cmd | tee ".scratch/task/$b"'
  blocked 'cmd > .scratch/$(basename "$f")' "$wt"
  blocked 'cmd > src/$(basename x)' "$wt/src/\$(basename x), $wt/src, $wt"
  # basename prints nothing for an empty word, or for none.
  blocked 'cmd > ".scratch/x/.$(basename "$f")./../y"' "$wt/y"
  # Unquoted, bash splits the name it prints into a tee's files, or a variable's value into words.
  unknown 'cmd | tee .scratch/task/$(basename "$f")' ".scratch/task/\$(basename \"\$f\") ($expansion)"
  unknown 'b=$(basename "$f"); cmd > .scratch/task/$b' ".scratch/task/\$b ($expansion)"
  unknown 'cmd > .scratch/task/$(basename a b c)' ".scratch/task/\$(basename a b c) ($expansion)"
  unknown 'cmd > .scratch/task/$(/usr/bin/basename a)' ".scratch/task/\$(/usr/bin/basename a) ($expansion)"
}

@test "the team-stack env form clears only COMPOSE_PROJECT_NAME and the TH_ and TEAM_ names, and any other eval ends following" {
  mkdir -p "$job/tmp"
  passes 'eval "$(~/agent-team/bin/team-stack env)"; export TMPDIR=$CLAUDE_JOB_DIR/tmp; cmd > $TMPDIR/e2e.log' \
    'X=.scratch; eval "$(team-stack env)"; cmd > $X/y' 'eval "$(bin/team-stack env)"; cd .scratch && cmd > x'
  local name
  for name in TEAM_X TH_X COMPOSE_PROJECT_NAME; do
    unknown "$name=.scratch; eval \"\$(~/agent-team/bin/team-stack env)\"; cmd > \$$name/y" "\$$name/y ($(not_followed "$name"))"
  done
  unknown 'X=.scratch; eval "$(team-stack ls)"; cmd > $X/y' "\$X/y ($(not_followed X))"
  unknown 'X=.scratch; eval "$(team-stack env) x"; cmd > $X/y' "\$X/y ($(not_followed X))"
}
