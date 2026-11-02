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

@test "a write inside a \$( ) or a process substitution is judged, from the outer command's directory" {
  blocked 'x="$(cmd > out)"' "$wt/out"
  blocked 'x=$(cmd > out)' "$wt/out"
  blocked 'echo "$(printf x | tee out)"' "$wt/out"
  blocked 'echo "a $(echo "$(cmd >> out)") b"' "$wt/out"
  blocked 'x="$(cmd "a)b" > out)"' "$wt/out"
  blocked 'cmd | tee >(gzip > out.gz)' "$wt/out.gz"
  blocked 'diff <(cmd > out) b' "$wt/out"
  blocked 'cmd < <(cmd > out)' "$wt/out"
  blocked $'echo $(echo a\n  cmd > out) > .scratch/x' "$wt/out"
  blocked 'x=$(cmd > out)' "$wt/src/out" "$wt/src"
  blocked 'echo $(cmd > a) > b' "$wt/b, $wt/a"
}

@test "comments inside a \$( ) are read as bash reads them" {
  blocked $'x=$(\n# 1) it\'s built\ncmd > out\n# that\'s all\n)' "$wt/out"
  blocked $'x=$(echo a\\ #) ; echo "\n)" ; cmd > out' "$wt/out"
  passes 'echo $(echo a#b) > .scratch/x' $'x=$(echo a # b > out\n)'
}

@test "a target holding a substitution is unknown, named as written" {
  unknown 'cmd | tee "out-$(date).log"' "\"out-\$(date).log\" ($expansion)"
  unknown 'cmd > out-$(date).log' "out-\$(date).log ($expansion)"
  unknown 'cmd > "out-$(cat x/../name)"' "\"out-\$(cat x/../name)\" ($expansion)"
  unknown 'cmd > "src$(: /../.scratch/ )/x"' "\"src\$(: /../.scratch/ )/x\" ($expansion)"
  unknown 'cmd > src$(: /../.scratch/ )/x' "src\$(: /../.scratch/ )/x ($expansion)"
  unknown 'cmd > .scratch/../out-$(date)' ".scratch/../out-\$(date) ($expansion)"
  unknown "cmd > x-\$(echo \$'a\\'b').log; echo ok" "x-\$(echo \$'a\\'b').log ($expansion)"
}

@test "what passes outside a substitution passes inside it" {
  passes 'x="$(cmd 2>/dev/null)"' 'x="$(cmd > .scratch/task/out)" && echo "$x"' 'echo "it is \$(cmd > out)"' \
    'diff <(sort a) <(sort b)' 'x=$()' 'x=$(cmd;)' 'x=$(cmd &)' 'x=$( )' 'echo $(echo) > .scratch/x'
}

@test "a process substitution as a tee file or an output target writes to its pipe" {
  passes 'cmd | tee >(gzip > .scratch/out.gz) >/dev/null' 'cmd > >(cat)' 'cmd 2> >(cat >&2)' 'cmd | tee >(cat) <(true)'
  blocked 'cmd > >(cat) | tee x' "$wt/x"
}

@test "a quoted here-document delimiter's body is text" {
  local open
  for open in "<<'EOF'" '<<"EOF"' '<<\EOF' "<< 'EOF'"; do
    passes "cat > .scratch/x $open
a \$(cmd > out) b \`cmd > out\` \\
EOF"
  done
  passes "git commit -F - <<'EOF'
fix: a > b, and | tee c
cmd > out
EOF"
}

@test "an unquoted here-document delimiter's body has its substitutions judged" {
  blocked 'cat <<EOF
a $(cmd > out) b
EOF' "$wt/out"
  blocked 'cat > .scratch/x <<EOF
a $(echo b
cmd > out) c
EOF' "$wt/out"
  blocked 'cat <<EOF
${HOME} $x "$(cmd > out)"
EOF' "$wt/out"
  passes 'cat > .scratch/x <<EOF
\$(cmd > out) a \\$x > b
it'"'"'s "fine" | tee c
EOF'
}

@test "<<- strips a body's leading tabs before it is matched to the delimiter" {
  blocked $'cat <<-EOF\n\ta $(cmd > out)\n\t\tEOF\ncmd > y' "$wt/out, $wt/y"
  passes $'cat <<-\'EOF\' > .scratch/x\n\t$(cmd > out)\n\tEOF'
  unread $'cat <<EOF > .scratch/x\n\tEOF\ncmd > out' 'a here-document whose delimiter line is not found'
}

@test "two here-documents on a line keep their order and quoting" {
  blocked $'cat <<A <<\'B\'\n$(cmd > a)\nA\n$(cmd > b)\nB' "$wt/a"
  blocked $'cat <<\'A\' <<B\n$(cmd > a)\nA\n$(cmd > b)\nB' "$wt/b"
}

@test "what follows a here-document's body is judged" {
  blocked "cat > .scratch/x <<'EOF'
a > b
EOF
cmd > out" "$wt/out"
  blocked "cat <<'EOF' |
a > b
EOF
tee out" "$wt/out"
  blocked "cat <<'EOF' && cmd > out
a > b
EOF" "$wt/out"
  blocked "cat <<'EOF'; cmd > out
a
EOF" "$wt/out"
}

@test "a here-document read outside a \$( ) waits for a newline outside it" {
  blocked $'cat <<EOF; echo $(echo\n:)\n$(cmd > out)\nEOF' "$wt/out"
}

@test "a here-document inside a \$( ) is read when its delimiter line comes before the )" {
  passes "x=\$(cat <<'EOF'
a) > b
EOF
)" "git commit -m \"\$(cat <<'EOF'
fix: a > b | tee c

it's done)
EOF
)\"" "x=\$(cat <<EOF
\$HOME
EOF
) && cmd > .scratch/x"
  blocked 'x=$(cat <<EOF
it'"'"'s
EOF
); echo y > out' "$wt/out"
}

@test "a here-document this hook does not read is refused unread, naming its form" {
  unread $'cat <<EOF > .scratch/x\na' 'a here-document whose delimiter line is not found'
  unread 'cat <<EOF > .scratch/x' 'a here-document whose delimiter line is not found'
  unread $'cat <<EOF > .scratch/x\na\nEOF \ncmd > out' 'a here-document whose delimiter line is not found'
  unread $'x=$(cat <<EOF\nhi\nEOF) ; cmd > out' 'a here-document line inside $( ) that starts with its delimiter and a )'
  unread $'x=$(cat <<\'EOF\'\nhi\nEOF) ; cmd > out' 'a here-document line inside $( ) that starts with its delimiter and a )'
  unread $'x=$(cat <<\'EOF\'\nhi\nEOF ) ; cmd > out' 'a here-document line inside $( ) that starts with its delimiter and a )'
  unread $'x=$(cat <<EOF)\nhi\nEOF\ncmd > out' 'a here-document inside $( ) that closes before its body is read'
  local delimiter
  for delimiter in 'E"O"F' '$x' "'E'OF" '"E"OF' "''" 'EOF"x"' '$(cmd > out)'; do
    unread "cat <<$delimiter > .scratch/x
a
EOF" 'a here-document delimiter other than a plain word, quoted whole or not'
  done
  unread $'cat <<EOF > .scratch/x\na \\\nEOF\ncmd > out\nEOF' 'a line ending in a backslash in a here-document whose delimiter is not quoted'
  unread $'cat <<EOF > .scratch/x\na `cmd > out`\nEOF' 'a backtick substitution'
  # An escaped backslash ends the line, and so does any backslash in a quoted delimiter's body.
  passes $'cat <<EOF > .scratch/x\na \\\\\nEOF' $'cat <<\'EOF\' > .scratch/x\na \\\nEOF'
}

@test "a process substitution inside a longer word is refused unread" {
  unread 'echo a<(cmd) > .scratch/x' 'a process substitution inside a word'
  unread 'echo <(cmd)b > .scratch/x' 'a process substitution inside a word'
  unread 'echo <(cmd)<(cmd) > .scratch/x' 'a process substitution inside a word'
  unread 'echo 2>(cmd) > .scratch/x' 'a process substitution inside a word'
  unread 'x=<(cmd); cmd > .scratch/x' 'a process substitution inside a word'
}

@test "a substitution that does not close is refused unread" {
  unread 'echo $(cmd > .scratch/x' 'a $( ) that does not close'
  unread 'cmd | tee >(cat > .scratch/x' 'a process substitution that does not close'
  unread $'cat <<EOF > .scratch/x\n$(cmd\nEOF\n)' 'a $( ) that does not close'
}

@test "a here-string's word is read and its substitutions judged" {
  blocked 'cmd <<< "$(cmd > out)"' "$wt/out"
  passes 'cmd <<< "a > b"' 'cmd <<<a > .scratch/x' "cmd <<< 'a | tee b'"
  unread 'cmd > .scratch/x <<<' 'a redirection with no target'
}

@test "on a bash older than 5.2, a comment or a here-document inside a substitution is refused unread" {
  TEAM_BASH_VERSION=5.1 unread $'x=$(echo a # b\n) ; cmd > .scratch/x' 'a comment inside a substitution, on a bash older than 5.2'
  TEAM_BASH_VERSION=5.1 unread $'x=$(cat <<\'EOF\'\na\nEOF\n) ; cmd > .scratch/x' 'a here-document inside a substitution, on a bash older than 5.2'
  # Outside a substitution, and on 5.2 and later, they are read.
  TEAM_BASH_VERSION=5.1 passes $'cmd > .scratch/x # a\ncat > .scratch/y <<\'EOF\'\na\nEOF'
  TEAM_BASH_VERSION=5.2 passes $'x=$(echo a # b\n) ; cmd > .scratch/x'
  TEAM_BASH_VERSION=6.0 passes $'x=$(cat <<\'EOF\'\na\nEOF\n) ; cmd > .scratch/x'
}

@test "each compound command is read, a write in its body and one after it judged" {
  blocked '( cmd > a ) > out' "$wt/out, $wt/a"
  blocked '{ cmd > a; } > out' "$wt/out, $wt/a"
  blocked 'if true; then cmd | tee x; fi' "$wt/x"
  blocked 'if a; then b; elif c; then d > a; else e > b; fi > out' "$wt/out, $wt/a, $wt/b"
  blocked 'while read l; do cmd > out; done < in' "$wt/out"
  blocked 'until false; do :; done > out' "$wt/out"
  blocked 'for f in a b; do cmd > out; done' "$wt/out"
  blocked 'for f; do cmd > out; done' "$wt/out"
  blocked $'for f in a b\ndo\n  cmd > out\ndone' "$wt/out"
  blocked 'for f in $(cmd > out); do :; done' "$wt/out"
  blocked 'for (( i = $(cmd > out); i < 2; i++ )); do :; done' "$wt/out"
  blocked 'for ((;;)) do :; done > out' "$wt/out"
  blocked 'case a in a) cmd > out ;; esac' "$wt/out"
  blocked 'case a in (a|b) cmd ;; esac > out' "$wt/out"
  blocked 'case a in a) ;& b) ;;& c) cmd > out;; esac' "$wt/out"
  blocked 'case $(cmd > a) in $(cmd > b)) ;; esac' "$wt/a, $wt/b"
  blocked '[[ -n a ]] > out' "$wt/out"
  blocked '(( 1 )) > out' "$wt/out"
  # Prefixed, in a pipeline, with a file descriptor or a here-document, and nested.
  blocked 'time { cmd; } > out' "$wt/out"
  blocked '! { cmd; } 2> out' "$wt/out"
  blocked '{ cmd; } | tee out' "$wt/out"
  blocked $'while read l; do :; done <<EOF\n$(cmd > out)\nEOF' "$wt/out"
  blocked $'if true; then\n  cat <<EOF\n$(cmd > out)\nEOF\nfi' "$wt/out"
  passes 'if true; then { cmd; } fi > .scratch/x' '{ { cmd; } } 2>&1 > .scratch/x' 'for f do :; done > .scratch/x' \
    $'case a\nin\na)\n  cmd\n  ;;\nesac > .scratch/x' 'case a in a) :; esac > .scratch/x'
}

@test "a compound command bash refuses as a syntax error is refused unread" {
  unread '{ cmd } > .scratch/x' 'a { } group that does not close'
  unread '( cmd > .scratch/x' 'a ( ) subshell that does not close'
  unread 'if a; then cmd > .scratch/x' 'an if command that does not close'
  unread 'while a; do cmd > .scratch/x' 'a while loop that does not close'
  unread 'until a; do cmd > .scratch/x' 'an until loop that does not close'
  unread 'for f in a; do cmd > .scratch/x' 'a for loop that does not close'
  unread 'case a in a) cmd > .scratch/x' 'a case command that does not close'
  unread '[[ a > .scratch/x' 'a [[ ]] test that does not close'
  unread '( ) > .scratch/x' 'a ) out of place'
  unread 'if then cmd; fi > .scratch/x' 'a then out of place'
  unread 'if a; then b; else c; elif d; then :; fi > .scratch/x' 'a elif out of place'
  unread 'while false; do :; done done > .scratch/x' 'a done out of place'
  unread '{ cmd; } x > .scratch/x' 'a word after a compound command'
  unread '{ cmd; } >(cat) > .scratch/x' 'a word after a compound command'
  unread 'x=1 { cmd; } > .scratch/x' 'a } out of place'
  unread 'for f in a b; { cmd; } > .scratch/x' 'a { out of place'
  unread 'for 1 in a; do :; done > .scratch/x' 'a for loop whose variable is not a name'
  unread 'case a in a) cmd ;; > .scratch/x' 'a > out of place'
  unread '{ cmd; } {fd}> .scratch/x' 'a {name} file descriptor'
}

@test "case is read inside a \$( ) as bash 5.2 and later read it" {
  blocked 'echo "$(case a in a) cmd > out ;; esac)"' "$wt/out"
  passes 'x=$(case a in (a) cmd ;; esac) > .scratch/x'
  blocked 'echo "$(echo showcase ${x:-a} > out)"' "$wt/out"
  TEAM_BASH_VERSION=5.1 unread 'x=$(case a in a) cmd ;; esac) > .scratch/x' 'a case command inside a substitution, on a bash older than 5.2'
  TEAM_BASH_VERSION=5.1 passes 'case a in a) cmd ;; esac > .scratch/x'
}

@test "[[ ]] reads < and > as comparisons and the word after =~ as a regular expression" {
  passes '[[ $a > b ]] && echo yes' '[[ $x =~ ^(a|b)$ ]] && cmd > .scratch/x' '[[ a =~ (a b) && c < d || ! e ]] > .scratch/x' \
    '[[ a =~ (a;b|c&d<e) ]] > .scratch/x'
  blocked '[[ $(cmd > out) ]]' "$wt/out"
  blocked '[[ a =~ $(cmd > out) ]]' "$wt/out"
  # A substitution's body is a command list, inside a regular expression too.
  blocked '[[ a =~ $(cmd|tee x) ]]' "$wt/x"
  blocked '[[ a =~ (b$(cmd|tee x)|c) ]]' "$wt/x"
}

@test "a (, ), |, &, ; or newline in a [[ ]] outside its regular expression is refused unread" {
  unread '[[ (a) ]] > .scratch/x' 'a ( inside [[ ]]'
  unread '[[ a =~ a) ]] > .scratch/x' 'a ) inside [[ ]]'
  unread '[[ a | b ]] > .scratch/x' 'a | inside [[ ]]'
  unread '[[ a & b ]] > .scratch/x' 'a & inside [[ ]]'
  unread '[[ a ; b ]] > .scratch/x' 'a ; inside [[ ]]'
  unread $'[[ a &&\n b ]] > .scratch/x' 'a newline inside [[ ]]'
  unread $'[[ a =~ (a\nb) ]] > .scratch/x' 'a newline inside [[ ]]'
  # Inside a regular expression's ( ), bash runs a process substitution.
  unread '[[ a =~ (>(cmd > out)) ]]' 'a process substitution inside a [[ ]] regular expression'
  unread '[[ a =~ (x <(cmd > out)) ]]' 'a process substitution inside a [[ ]] regular expression'
}

@test "a function definition's body is judged where it is defined" {
  blocked 'f() { cmd > out; }' "$wt/out"
  blocked 'f () ( cmd > out )' "$wt/out"
  blocked $'f()\n{ cmd > out; }' "$wt/out"
  blocked 'f() { :; } > out' "$wt/out"
  blocked 'my-f() if true; then cmd > out; fi' "$wt/out"
  passes 'f() { cmd > .scratch/x; }; f'
  unread 'f() cmd > .scratch/x' 'a function body that is not a compound command'
  unread '"f"() { :; }; cmd > .scratch/x' 'a function name other than a plain name'
}

@test "a function named cd, pushd, popd, tee, mktemp, basename or a wrapper is refused unread" {
  local name
  for name in cd pushd popd tee mktemp basename env sudo nohup timeout nice stdbuf command exec time builtin; do
    unread "$name() { :; }; cmd > .scratch/x" "a function named $name"
  done
}

@test "an array assignment's words are read as words" {
  blocked 'a=(x "$(cmd > out)")' "$wt/out"
  blocked $'a+=( # one\n  x\n  $(cmd > out)\n)' "$wt/out"
  passes 'H=(-H "a b") ; cmd > .scratch/x' 'a=() b=(y) cmd > .scratch/x'
  # Text after its ) makes it one word of literal text in bash, and a ( anywhere else is no array.
  unread 'a=(x)y; cmd > .scratch/x' 'an array assignment with text after its )'
  unread 'a=(x; cmd > .scratch/x' 'a ; out of place'
  unread 'a=(x > .scratch/x' 'a > out of place'
  unread 'declare a=(x); cmd > .scratch/x' 'a ( inside a command'
  unread 'cmd > .scratch/x; a=(x y' 'an array assignment that does not close'
}

@test "\${ } with an operator is read to its first unescaped }" {
  passes 'echo ${#x} ${x##*/} ${x#\#} > .scratch/x' 'echo ${x:->}' 'echo "$(echo ${x}) ${y:-(}" > .scratch/x' \
    'echo ${x@Q} ${!x} ${a[@]} ${a[$i]:1:2} ${x/a/b} ${x^^} ${x,} ${x:-$y${z}$1} ${##} ${x:-a\}b} > .scratch/x'
  # A ) or a # in an operand is text, as bash reads it.
  blocked 'echo "$(echo ${x:-)} > out)"' "$wt/out"
  blocked $'x=$(echo ${y:-a #}) ; echo "\n)" ; cmd > out' "$wt/out"
}

@test "a target holding a \${ } with an operator is unknown, named as written" {
  unknown 'cmd > ${out:-x}' "\${out:-x} ($expansion)"
  unknown 'cmd > "src${x//../.scratch/}/x"' "\"src\${x//../.scratch/}/x\" ($expansion)"
}

@test "a \${ } outside the grammar's forms is refused unread, naming its form" {
  unread 'echo ${x:-"$(cmd > out)"}' 'a quote inside a ${ } operand'
  unread 'echo "${x:-"`cmd > out`"}"' 'a quote inside a ${ } operand'
  unread "echo \${x:-\$'a\\'b'} > out" 'a quote inside a ${ } operand'
  unread "echo \"\${x:-'\"'}\" ; cmd > out ; echo \"}\"" 'a quote inside a ${ } operand'
  unread "echo \"\${x:-'a'}\" > .scratch/x" 'a quote inside a ${ } operand'
  unread 'echo ${x:-`cmd`} > .scratch/x' 'a backtick substitution'
  unread 'echo ${x:-$(cmd)} > .scratch/x' 'an expansion inside a ${ } operand other than a variable'
  unread 'echo ${x:-${y:-z}} > .scratch/x' 'an expansion inside a ${ } operand other than a variable'
  unread $'echo ${x:-a\nb} > .scratch/x' 'a newline inside a ${ } operand'
  unread $'echo ${x:-a\\\nb} > .scratch/x' 'a newline inside a ${ } operand'
  unread 'echo ${x:-a > .scratch/x' 'a ${ } that does not close'
  local form
  for form in '${x;y}' '${}' '${ x}' '${x@Qa}' '${x*}'; do
    unread "echo $form > .scratch/x" 'a ${ } this hook does not read'
  done
  # A prompt expansion runs the substitutions in the value.
  unread 'echo ${x@P} > .scratch/x' 'the ${ } operator @P'
}

@test "arithmetic is read, and the substitutions in it judged" {
  blocked 'echo $(( $(cmd > out) + 1 ))' "$wt/out"
  blocked '(( $(cmd > out) ))' "$wt/out"
  blocked 'echo "$(( $(cmd > out) ))"' "$wt/out"
  blocked $'echo $(( 1 +\n  $(cmd > out) ))' "$wt/out"
  passes '(( a > b )) && echo yes' 'echo $(( a > b ? 1 : 2 ))' '(( (a) > (b) ))' 'echo $(( (a) > (b) ))' \
    'echo "$(( (a) > (b) ))"' 'echo $(( 2#101 << $1 | ${#x} & a[i] ^ ~b, c >= $x )) > .scratch/x'
  unread 'echo $(( ${x:-$(cmd > out)} ))' 'an expansion inside a ${ } operand other than a variable'
}

@test "arithmetic that does not close with )), or holds a quote or a backtick, is refused unread" {
  unread '((cmd) > out)' 'an arithmetic command that does not close with ))'
  unread 'echo $((cmd) > out)' 'an arithmetic expansion that does not close with ))'
  unread 'echo "$((cmd) > out)"' 'an arithmetic expansion that does not close with ))'
  unread $'cat <<EOF\n$((cmd) > out)\nEOF' 'an arithmetic expansion that does not close with ))'
  unread 'for ((i=0; i<2; i++); do :; done > out' 'a for (( )) loop that does not close with ))'
  unread "((echo '))' ) > out)" 'a quote inside arithmetic'
  unread "echo \$((echo '))' ) > out)" 'a quote inside arithmetic'
  unread "echo \$(( '\$(cmd > out)' ))" 'a quote inside arithmetic'
  unread 'echo $(( "1" + 2 )) > .scratch/x' 'a quote inside arithmetic'
  unread "echo \${x:-\$(( '\$(cmd > out)' ))}" 'an expansion inside a ${ } operand other than a variable'
  unread 'echo $(( `cmd > out` ))' 'a backtick substitution'
  unread 'echo $(( a; b )) > .scratch/x' 'a ; inside arithmetic'
  unread 'echo $(( a \ b )) > .scratch/x' 'a \ inside arithmetic'
  unread 'echo $(( $((1)) )) > .scratch/x' 'an arithmetic expansion inside arithmetic'
  unread 'echo $(( $ )) > .scratch/x' 'a $ inside arithmetic'
  unread 'echo $(( a @ b )) > .scratch/x' 'a @ inside arithmetic'
}

@test "a substitution inside an unquoted here-document body's \${ } or \$(( )) is judged" {
  unread $'x=$(cat <<EOF\n${y:-$(cmd > out)}\nEOF\n)' 'an expansion inside a ${ } operand other than a variable'
  blocked $'cat <<EOF\n$(( $(cmd > out) ))\nEOF' "$wt/out"
  passes $'cat > .scratch/x <<EOF\n${x:-a} ${#y} $(( 1 + 2 ))\nEOF'
}

@test "a form no rule reads is refused unread, so a command holding one passes nothing it holds" {
  unread 'select x in a; do :; done; cmd > .scratch/x' 'a select command'
  unread 'cmd > .scratch/x; y=`date`' 'a backtick substitution'
  unread 'coproc cat; cmd > .scratch/x' 'a coproc command'
}
