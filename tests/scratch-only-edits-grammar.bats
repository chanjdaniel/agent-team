#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2034,SC2088 # wt, tmp, job and the reasons are helpers/scratch-hook.bash's, hook_tmpdir and hook_job its shell's; a ~ is part of a command as an agent types it
# hooks/scratch-only-edits: the grammar the hook reads a Bash command against. Each form of it is
# read as bash reads it, so a write it holds is judged; each form outside it is refused unread,
# naming the form, and so is every form the grammar names as refused.

load helpers/common
load helpers/scratch-hook

setup() {
  scratch_setup
}

@test "a command with no > and no tee once its quotes and backslashes are taken out passes unread" {
  passes 'touch src/x' 'echo "$(echo $#)" $(( "1" ))' 'x=`y`' 'select x in a; do :; done' 'grep -rn foo src'
}

@test "a tee spelled with quotes, backslashes or a line continuation is read" {
  blocked "cmd | t''ee out" "$wt/out"
  blocked 'cmd | t\ee out' "$wt/out"
  blocked 'cmd | "tee" out' "$wt/out"
  blocked $'cmd | t\\\nee out' "$wt/out"
}

@test "quoted text is not a redirection, and what follows it is judged" {
  passes 'echo "a > b"' "grep -n '>>' file" 'echo a\>b' 'echo "a \" > b"' "echo 'it''s > fine'" \
    "echo 'a
> b'" 'echo "a
> b"'
  blocked 'echo "a > b" > c' "$wt/c"
  blocked "echo 'a > b' > c" "$wt/c"
  blocked 'echo a\>b > c' "$wt/c"
  blocked "echo 'a
> b' > c" "$wt/c"
  # A double-quoted string keeps \$ \` \" \\ as the character and a line continuation out.
  blocked 'cmd > ".scratch/\$\"\\x"/../../y' "$wt/y"
  blocked $'cmd > ".scr\\\natch/x/../../y"' "$wt/y"
}

@test "a comment runs to its line's end, and a # inside a word is text" {
  passes 'echo ok # > x' 'cmd;# > x' 'cmd > .scratch/x # | tee y'
  blocked 'echo a#b > x' "$wt/x"
  blocked 'echo a > x#y' "$wt/x#y"
  # A comment ends at its line even when that line ends in a backslash.
  blocked $'echo a # c \\\ncmd > x' "$wt/x"
  blocked $'# a comment\ncmd > x' "$wt/x"
}

@test "a line continuation joins its lines, inside words and operators" {
  blocked $'cmd \\\n> x' "$wt/x"
  blocked $'cmd >\\\n> x' "$wt/x"
  blocked $'true &\\\n& cmd > x' "$wt/x"
  blocked $'cmd > .scr\\\natch/../x' "$wt/x"
  # An escaped backslash before a newline is a backslash, and the newline separates commands.
  blocked $'echo a\\\\\ncmd > x' "$wt/x"
}

@test "an ANSI-C string is read to its unescaped quote" {
  blocked "echo \$'a\\'b' > out" "$wt/out"
  blocked "echo \$'a > b' > out" "$wt/out"
  passes "echo \$'a > b'" "cmd > \$'.scratch/x'"
  unknown "cmd > \$'.scratch/\\x41'" "\$'.scratch/\\x41' ($expansion)"
}

@test "\$name, \${name} and the special parameters are read, and a target holding an unknown one is unknown" {
  passes 'echo $x ${y} $? $# $@ $* $$ $! $- $0 $1 ${10} ${#} ${@} > .scratch/x' 'echo $ "$" a$ > .scratch/x'
  unknown 'cmd > .scratch/$1' ".scratch/\$1 ($expansion)"
  unknown 'cmd > "x$?"' "\"x\$?\" ($expansion)"
}

@test "each list and pipeline operator is read, and every command in it judged" {
  blocked 'a; cmd > x' "$wt/x"
  blocked 'a & cmd > x' "$wt/x"
  blocked 'cmd > x &' "$wt/x"
  blocked $'a\ncmd > x' "$wt/x"
  blocked 'a && cmd > x' "$wt/x"
  blocked 'a || cmd > x' "$wt/x"
  blocked 'a | cmd > x' "$wt/x"
  blocked 'a |& tee x' "$wt/x"
  blocked $'a |\n  tee x' "$wt/x"
  blocked $'a &&\n# then\ncmd > x' "$wt/x"
  blocked '! cmd > x' "$wt/x"
  blocked 'time -p cmd > x' "$wt/x"
  blocked 'time -p -- cmd > x' "$wt/x"
  blocked '! time cmd | tee x' "$wt/x"
  blocked 'time ! cmd > x' "$wt/x"
  passes 'time; cmd > .scratch/x' '! ; cmd > .scratch/x'
}

@test "each output redirection operator's target is judged" {
  blocked 'cmd > x' "$wt/x"
  blocked 'cmd >> x' "$wt/x"
  blocked 'cmd >| x' "$wt/x"
  blocked 'cmd &> x' "$wt/x"
  blocked 'cmd &>> x' "$wt/x"
  blocked 'cmd <> x' "$wt/x"
  blocked 'cmd 3<> x' "$wt/x"
  blocked 'cmd >& x' "$wt/x"
  blocked 'cmd 2> x' "$wt/x"
  blocked 'cmd 10>x' "$wt/x"
  blocked '>x' "$wt/x"
  blocked 'cmd >x>y' "$wt/x, $wt/y"
  # A word of digits apart from the operator is an argument, and &> always names a file.
  blocked 'cmd 2 > x' "$wt/x"
  blocked 'cmd &>2' "$wt/2"
}

@test "a file descriptor duplication or an input redirection judges nothing" {
  passes 'cmd 2>&1' 'cmd >&2' 'cmd 1>&2-' 'cmd >&-' 'cmd 3>&1 1>&2 2>&3' 'cmd 2>& 1' 'cmd >&"1"' \
    'cmd < src/x > .scratch/y' 'cmd 0<&3 > .scratch/y' 'cmd <&- > .scratch/y'
  unknown 'cmd >&$fd' "\$fd ($expansion)"
}

@test "a tee is found behind the wrappers, their options and their option values" {
  blocked 'cmd | timeout 60 tee out' "$wt/out"
  blocked 'cmd | timeout -s KILL -k 5 10s tee out' "$wt/out"
  blocked 'cmd | timeout 1e3 tee out' "$wt/out"
  blocked 'cmd | nice tee out' "$wt/out"
  blocked 'cmd | nice -n 5 tee out' "$wt/out"
  blocked 'cmd | sudo -u me tee out' "$wt/out"
  blocked 'cmd | sudo --user me -E tee out' "$wt/out"
  blocked 'cmd | sudo -- tee out' "$wt/out"
  blocked 'cmd | stdbuf -oL tee out' "$wt/out"
  blocked 'cmd | stdbuf -o L tee out' "$wt/out"
  blocked 'cmd | env -u X A=1 tee out' "$wt/out"
  blocked 'cmd | exec -a name tee out' "$wt/out"
  blocked 'cmd | builtin command nohup tee out' "$wt/out"
  blocked 'cmd | time -p tee out' "$wt/out"
  blocked 'cmd | time -o log tee out' "$wt/out"
  blocked 'cmd | /usr/bin/tee out' "$wt/out"
  blocked 'cmd | "tee" out' "$wt/out"
  blocked 'cmd | X=1 tee out' "$wt/out"
  # A lookup runs nothing, and a wrapper's own arguments are no tee's files.
  passes 'command -v tee out' 'command -V tee out' 'timeout 60 cmd out' 'sudo -u tee cmd x' 'echo tee x' 'grep tee x'
}

@test "a wrapper's -C, --chdir or -D makes a relative tee file unknown" {
  unknown 'env -C /tmp tee .scratch/x' ".scratch/x ($moved)"
  unknown 'env --chdir=/tmp tee .scratch/x' ".scratch/x ($moved)"
  unknown 'sudo -D /tmp tee .scratch/x' ".scratch/x ($moved)"
  # An absolute file is judged, and a redirection is the shell's, made before the wrapper runs.
  passes "env -C /tmp tee $wt/.scratch/x" 'env -C /tmp cmd > .scratch/x'
}

@test "a tee's every file is a target, after its options and after --" {
  blocked 'cmd | tee --append -p x' "$wt/x"
  blocked 'cmd | tee -- -x' "$wt/-x"
  blocked 'cmd | tee .scratch/a x' "$wt/x"
  blocked 'cmd | tee x -a' "$wt/x"
  unknown 'cmd | tee -$opt' "-\$opt ($expansion)"
  passes 'cmd | tee' 'cmd | tee -a .scratch/task/log /dev/null'
}

@test "a target holding an unquoted brace or glob is unknown" {
  unknown 'cmd | tee .scratch/{a,../../src/b}' ".scratch/{a,../../src/b} ($expansion)"
  unknown 'cmd > .scratch/*.md' ".scratch/*.md ($expansion)"
  unknown 'cmd > .scratch/a?' ".scratch/a? ($expansion)"
  unknown 'cmd > .scratch/[ab]' ".scratch/[ab] ($expansion)"
  passes 'cmd > ".scratch/*.md"' "cmd > .scratch/'{a,b}'"
}

@test "a ~ is HOME only alone or before a / at a target's start" {
  passes 'cmd > ~/wt/.scratch/x' 'cmd | tee ~/wt/.scratch/x'
  blocked 'cmd > ~' "$HOME"
  unknown 'cmd > ~user/x' "~user/x ($expansion)"
  unknown 'cmd > ~+/x' "~+/x ($expansion)"
  unknown 'cmd | tee a=~/x' "a=~/x ($expansion)"
  blocked 'cmd > .scratch/../~/x' "$wt/~/x"
  blocked 'cmd > "~/x"' "$wt/~/x"
}

@test "a backtick substitution, \$[ ], \$\" \" and an extended glob are refused unread" {
  unread 'x=`cmd > out`' 'a backtick substitution'
  unread 'echo "`cmd`" > .scratch/x' 'a backtick substitution'
  unread $'echo $[1<<2]\necho x > out' 'a $[ ] arithmetic expansion'
  unread 'echo $"hi" > .scratch/x' 'a $" " string'
  local glob
  for glob in '@(a|b)' '!(a)' '+(a)' '*(a)' '?(a)'; do
    unread "ls $glob > .scratch/x" 'an extended glob'
  done
}

@test "select, coproc, the function keyword, alias, enable and hash are refused unread" {
  unread 'select x in a; do cmd > out; done' 'a select command'
  unread 'coproc cmd > .scratch/x' 'a coproc command'
  unread 'function f { cmd > out; }' 'the function keyword'
  unread $'alias t=tee\necho | t out' 'the alias builtin'
  unread 'builtin alias t=tee; cmd > .scratch/x' 'the alias builtin'
  unread 'enable -n echo; echo > .scratch/x' 'the enable builtin'
  unread 'hash -p /bin/sh tee; cmd | tee .scratch/x' 'the hash builtin'
  # As an argument, such a word is text.
  passes 'echo alias select > .scratch/x'
}

@test "a set or shopt option outside the grammar's is refused unread" {
  unread 'set -o posix; cmd > .scratch/x' 'the set option -o posix'
  unread 'set -euo posix; cmd > .scratch/x' 'the set option -o posix'
  unread 'set -k; cmd > .scratch/x' 'the set option -k'
  unread 'set +H; cmd > .scratch/x' 'the set option +H'
  unread 'set $opt; cmd > .scratch/x' 'the set option $opt'
  unread 'shopt -s lastpipe; cmd > .scratch/x' 'the shopt option -s'
  unread 'shopt -u expand_aliases; cmd > .scratch/x' 'the shopt option -u'
  passes 'set -euo pipefail; cmd > .scratch/x' 'set -e +x -ET; set -o errexit -o nounset +o xtrace; cmd > .scratch/x' \
    'set -o verbose -o errtrace -o functrace; set -- -o posix $x; cmd > .scratch/x' 'set a -k; set; set -o; cmd > .scratch/x' \
    'shopt -q extglob; shopt -pq; shopt; cmd > .scratch/x'
}

@test "IFS, CDPATH and POSIXLY_CORRECT named anywhere are refused unread, but IFS= before a command" {
  unread 'echo "$IFS" > .scratch/x' 'the name IFS'
  unread 'IFS=/; cmd > .scratch/x' 'the name IFS'
  unread 'IFS=$IFS read -r a; cmd > .scratch/x' 'the name IFS'
  unread 'export IFS; cmd > .scratch/x' 'the name IFS'
  unread 'cmd > .scratch/x # IFS' 'the name IFS'
  unread 'CDPATH=/ cmd > .scratch/x' 'the name CDPATH'
  unread 'echo ${CDPATH} > .scratch/x' 'the name CDPATH'
  unread "POSIXLY_CORRECT=1 cmd > .scratch/x" 'the name POSIXLY_CORRECT'
  passes 'IFS= read -r line; cmd > .scratch/x' 'IFS=: read -r a b < f; cmd | tee .scratch/x' 'echo MYIFS IFS_X > .scratch/x'
}

@test "a {name} file descriptor is refused unread" {
  unread 'exec {fd}> .scratch/x' 'a {name} file descriptor'
  unread 'cmd {fd}>&1 > .scratch/x' 'a {name} file descriptor'
  # Apart from its operator, or quoted, it is a word.
  passes 'echo {fd} > .scratch/x' 'echo "{fd}"> .scratch/x'
}

@test "a command bash refuses as a syntax error is refused unread" {
  unread 'echo "a > x' 'an unclosed quote'
  unread "echo 'a > x" 'an unclosed quote'
  unread "echo \$'a > x" 'an unclosed quote'
  unread 'cmd ) > x' 'a ) out of place'
  unread 'cmd > x )' 'a ) out of place'
  unread 'cmd > x; fi' 'a fi out of place'
  unread 'done > x' 'a done out of place'
  unread 'then cmd > x' 'a then out of place'
  unread '} > x' 'a } out of place'
  unread 'cmd | ! tee x' 'a ! out of place'
  unread 'cmd > x &&' 'an operator with no command after it'
  unread 'cmd | tee x |' 'an operator with no command after it'
  unread '| tee x' 'a | out of place'
  unread '; cmd > x' 'a ; out of place'
  unread 'cmd > x; ; b' 'a ; out of place'
  unread 'cmd > x;;' 'a ;; out of place'
  unread 'cmd > x & & b' 'a & out of place'
  unread 'cmd >' 'a redirection with no target'
  unread 'cmd > ; b' 'a redirection with no target'
  unread 'cmd >#x' 'a redirection with no target'
  unread 'echo a (b) > x' 'a ( inside a command'
  # A reserved word after the first word is text.
  passes 'echo fi then done > .scratch/x' 'x=1 fi > .scratch/x'
}

@test "until the grammar grows, substitutions, here-documents, compound commands and the rest are refused unread" {
  unread 'x=$(cmd > out)' 'a command substitution $( )'
  unread 'echo $(( 1 > 2 ))' 'an arithmetic expansion $(( ))'
  unread '(( a > b ))' 'an arithmetic command (( ))'
  unread 'diff <(sort a) <(sort b) > .scratch/x' 'a process substitution'
  unread 'cmd | tee >(gzip > out.gz)' 'a process substitution'
  unread 'cmd > >(cat)' 'a process substitution'
  unread "cat > .scratch/x <<'EOF'
a
EOF" 'a here-document'
  unread 'cmd <<< "a > b"' 'a here-string'
  unread '( cmd ) > out' 'a ( ) subshell'
  unread '{ cmd; } > out' 'a { } group'
  unread 'if true; then cmd | tee x; fi' 'an if command'
  unread 'while read l; do cmd > out; done' 'a while loop'
  unread 'until false; do :; done > out' 'an until loop'
  unread 'for f in a b; do cmd > out; done' 'a for loop'
  unread 'case a in a) cmd > out ;; esac' 'a case command'
  unread '[[ $a > b ]] && echo yes' 'a [[ ]] test'
  unread 'cmd > ${out:-x}' 'a ${ } with an operator'
  unread 'echo ${#x} > .scratch/x' 'a ${ } with an operator'
  unread 'a=(x y); cmd > .scratch/x' 'an array assignment'
  unread 'f() { cmd > out; }' 'a function definition'
}

@test "a form no rule reads is refused unread, so a command holding one passes nothing it holds" {
  unread 'select x in a; do :; done; cmd > .scratch/x' 'a select command'
  unread 'cmd > .scratch/x; y=`date`' 'a backtick substitution'
  unread 'coproc cat; cmd > .scratch/x' 'a coproc command'
}
