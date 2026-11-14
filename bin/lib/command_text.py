#!/usr/bin/env python3
"""The text of a Bash command that runs as code, and the walk of each simple command it runs.

Usage: python3 -I command_text.py              (the command on stdin; prints the text on stdout)
       python3 -I command_text.py --commands   (the command on stdin; prints its walk, below)

bin/lib/command_rules.py, the rule table bin/hooks/command-guard runs, imports code_parts,
blank_heredocs and commands, the walk of each simple command, from it, with heads and the other
readings of where a command's name may stand; its kill rows, kill_rules.py, import command_name
and heads_behind, and its delete rows, delete_rules.py, those with the walk, simple_commands,
find's FIND_EXEC, SHELLS, the option readers and unquoted; outbound.py imports commands and the
option readers long_options and short_cluster, and team-tokens without_heredocs.
It reads the command far enough to know its quotes ('...', "..." and $'...'), backslashes, comments,
arithmetic ($[, and $(( or (( whose two closing parentheses are adjacent, matched as Bash's
parse_matched_pair does, past quotes, backticks and a $(...) read by this scan: ((cmd) ) is two
subshells), groups ((, $(, a backtick, ${ in which quotes nest up to its first }, [[ ... ]], in
which a comment and a newline's heredoc bodies are read as outside it, a { ... }, if ... fi, a
while, until, for or select loop to its done (for's and select's to a { ... } body before any
do), and after = an array assignment's list, a word's part in which no word is reserved), case's
patterns, pipelines, here-strings and heredocs, whose marker is its word up to a blank or an
operator with its quotes removed, as Bash takes it; a << inside quotes, a comment, arithmetic, ${
or [[ opens none. In arithmetic ($((, $[, (( and for's ((, in a double quote too) only its quotes,
a $(, a backtick and a nested $(( are read, to its close: each substitution in it is a group,
whose commands Bash runs.
A reserved word ({, }, case, esac, [[ and the rest) is one where Bash takes it as one, as its
reserved_word_acceptable does: after a separator, a pipe, (, ), {, }, an opening reserved word,
a compound command's end (fi, done, esac, }, ), (( ... )) or ]]), time, its -p or the -- after
either, coproc, or coproc's or function's name; after any other word it is a word.
An element's subscript (X[...]) is read as one bracket pair, as _pair_end reads it, where Bash's
lexer reads one, in an assignment's place (its assignment_acceptable): where a reserved word may
come, or after only assignments and redirections with their targets; so a separator, a
parenthesis, a comment or a newline in it is part of its word, and its substitutions are read as
arithmetic's are.
The text it prints is the command with:
  - each heredoc's body left out, through its closing line, its marker's line kept. A body is kept
    whole, as code, when a shell may read it as its script: the heredoc is a shell's own, or its
    command, or a group it is in, is piped into a shell. Else a body under an unquoted marker
    keeps, each on a line of its own, the text of each of its lines from its first command
    substitution ($( or a backtick, an escaped one, \\$( or \\`, no substitution) on, since Bash
    runs those. A heredoc with no closing line is left as it is, all of it read as code;
  - the string after a shell's -c (bash, sh, zsh, dash or ksh, by any path), su's, script's and
    flock's -c, eval, env's -S or --split-string and find's -exec, -execdir, -ok and -okdir, to
    the end of its line, added on a line of its own with a leading -- and its opening quotes
    dropped, and so for each such string inside another (its later lines already start lines);
  - a shell's here-string, or one in a command piped into a shell, its quotes removed; and for
    each command piped into a shell, the text of each of its quoted strings and of each of its
    simple commands' words after the first, quotes dropped, and what each of its echo and printf
    commands prints, as written and decoded as for a file written (below); each added on a line of
    its own.
A shell here is a pipeline segment one of whose simple commands, as the walk below reads it (its
assignments, redirections and the wrappers' options passed, its words' quotes removed, its
$'...' escapes decoded and its braces expanded), or a command that one runs (its string, its find -exec),
is bash, sh, zsh, dash, ksh or source by any path, or . with a file; a compound command's body
(if, a loop, case, { ... }) is part of the segment it stands in; or a segment a group or
substitution in which starts one, as (bash) or tee >(bash) does; so a shell or . named as an
argument feeds it nothing.
The words it adds of a command piped into a shell split at a separator inside quotes too: a walk
of the text sees more commands there, never fewer.
code_parts(command) gives the same text as a list, the command first, then each added line: a
line may leave a quote open (find -exec's string to its line's end, its closing quote with it, or
a fed string's apostrophe), which in the joined text would hide every line after it, so a reader
walks each part alone; blank_heredocs(part) blanks the operator and marker of each heredoc a part
still opens, so a walk of it reads the lines after it, and a body a shell reads, as code.
A script the command writes to a file and runs is code too, its parts after the command's, read by
code_parts in its turn, a script it writes and runs among them, to 20 scripts deep, past which it
raises. Written are a heredoc's body, a here-string, and what echo and printf print (echo's text as
written and again with its escapes decoded, as sh's echo writes it, or only decoded under -e;
printf's format used again while its arguments last, %b decoded; printf -v writes no file), when
the output of their pipeline segment, of a later segment it is piped into, or of the segment
holding a group or compound command they stand in, goes to a file: > f, >> f, >| f, &> f, >& f or
1> f, or tee's files (tee f, tee -a f). The pieces one file is written are read joined, in the
order found. It is run when, anywhere in the command, its text, an added part or a script read so,
a Command of the walk (below) has the file as its first word, its path normalized: a shell's script
file or a sourced one (bash x.sh, sh ./x.sh, source x.sh, . x.sh) or a command word naming it
(./x.sh, or x.sh itself); a run before the write counts too, since a loop may run it later. A file
never run so keeps its text out, as do a file a shell reads on stdin (bash < x.sh), a variable's
value (x=...; echo "$x" > f), a script written by an earlier call or by the Write tool, and a file
run under another name (a copy, a link, a path through a cd).

A word of the walk is the one Bash makes of it: its quotes removed (a $"..." locale string one,
its text as written), a backslash-newline dropped, a $'...' string's escapes decoded (\\x70,
\\160, \\u, \\cX), and, but for an assignment before a command's name, its unquoted brace lists
and ranges expanded into words ({pkill,-f,x} is pkill -f x; an empty one dropped; past 4096 words
it raises); one a $'...' escape or a range made is a Word, whose written keeps its
escapes and its range as they are written.
commands(text), which --commands prints as one JSON line each, yields a Command for each simple
command the text runs (simple_commands: those in a group, a substitution, a pipeline or a list
too): the assignments before its name, env's and an array element's (X[0]=1, its subscript one
bracket pair as Bash's lexer reads it there, blanks, quotes, nested brackets and operators in it,
kept as written: X[ 0 ]=1, X[;]=1) among them, since Bash runs the command after one it refuses;
its words from the name of what runs on, past the wrappers env, command, builtin, exec, nohup,
time, nice, ionice, stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch and flock with
their options (env's lone - among them; command's, and time's -p and --, take no value, so
command -p source runs source), numbers and flock's file, parallel's inputs after its ::: or
:::: left out but for those with a scheme (https://host/u), read as URLs; the wrappers it ran
behind, each its own words, the outermost first, with the command that ran its string, its find,
or the shell or source that ran its file; and how it was reached: directly, in a string a tool
runs, by find -exec, in a string watch or parallel join, as a shell's script file or by source.
A command string is walked in turn, its commands yielded after the command that runs it, where
the tool itself takes one: what watch and parallel join of their command's words (from the first
word that is no option, and the next too when an option may take that one), env's -S or
--split-string value with the words after it, and flock's -c or --command value, each after the
assignments before it, quoted; a shell's -c string (bash, sh, zsh, dash or ksh), su's -c, -C,
--command or --session-command, script's -c or --command, eval's words and trap's action (its
first operand past a --, when a signal follows it and it is no -); and each command find's -exec,
-execdir, -ok or -okdir runs is walked as a simple command of its own.
env's, flock's, su's and script's long options are taken by any prefix getopt_long takes as one
alone (su --comm), and their short ones in a cluster as getopt reads it (env -uSPATH is -u SPATH).
A shell with no -c or -s whose first operand, past its options (-o and -O, --rcfile and
--init-file with their value) and a -- or -, is a file, and source or . with one, run that file
with the words after it: the Command is that file and its words, never read.
A command string is never walked again when it is the text being walked, and one nested deeper
than 20 strings raises, so a guard that walks it refuses.
Not walked: a command word built by a substitution ($(command -v curl)), a command given as one
string where its tool takes words (sudo -s escapes each word it passes its shell), a watch or
parallel command string after an option's value followed by another option (watch -n 5 -d '...'),
ssh's remote command (it runs on the other host), and a command another tool runs from its
arguments (nsenter, chroot, unshare, systemd-run, tmux send-keys, git rebase's --exec).
"""

import functools
import json
import os
import re
import shlex
import sys
from dataclasses import dataclass

# The characters that end a word outside quotes.
METACHARACTERS = frozenset(" \t\n;&|()<>")
# A word, from where it starts to a metacharacter.
WORD = re.compile(r"[^\s;&|()<>]+")
# A redirection operator where a word would start, with the fd or {name} before it.
REDIRECT = re.compile(r"(?:[0-9]+|\{[A-Za-z_]\w*\})?(?:&>>?|<<<|<<-?|<>|[<>]&|>\||>>|[<>])")
# A name and the [ that opens its subscript, where a word starts.
SUBSCRIPTED = re.compile(r"[A-Za-z_]\w*\[")
# A variable's assignment, where a word starts.
ASSIGNED = re.compile(r"[A-Za-z_]\w*\+?=")
# The reserved words after which another may come, each with the state it leaves: function's and
# coproc's name lets one follow, as do time's -p and the -- after either (Bash's
# reserved_word_acceptable).
OPENS = {word: True for word in ("!", "if", "then", "else", "elif", "do", "while", "until", "fi", "done")}
OPENS.update(function="name", coproc="coproc", time="time")
# The compound commands that open a frame to the reserved word that ends them, each its frame's kind
# and the state it starts with: for's and select's name comes first, and their frame is a "for"
# until its do makes it a loop, or a { ... } body, which Bash takes in place of do ... done, ends it.
COMPOUNDS = {"if": ("if", True), "while": ("loop", True), "until": ("loop", True), "for": ("for", "name")}
COMPOUNDS["select"] = COMPOUNDS["for"]
# The reserved words that end a compound command's frame, each with its frame's kind.
ENDS = {"fi": "if", "done": "loop"}
# A string the shell runs as a command: what follows a shell's -c, eval, env's -S or find's -exec.
RUNS_STRING = re.compile(
    r"(?<![\w.-])(?:(?:(?:ba|z|da|k)?sh|su|script|flock)(?:[ \t]+[^\s;&|]+)*?[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+"
    r"|eval[ \t]+|env(?:[ \t]+[^\s;&|]+)*?[ \t]+(?:-[A-Za-z]*S[ \t]*|--split-string(?:=|[ \t]+))"
    r"|-(?:exec|execdir|ok|okdir)[ \t]+)"
)
OPENING = re.compile(r"^(?:--[ \t]+)?(?:\$?['\"])*")
QUOTED = re.compile(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"")
# Where a piped command's text splits into simple commands, for each one's words after its first.
SIMPLE = re.compile(r"[;&|(){}`\n]")


@dataclass
class Heredoc:
    """A heredoc in its pipeline's segment: its marker, its body and closing line, whether quoted."""

    pipeline: int
    segment: int
    marker: tuple
    body: tuple
    end: int
    quoted: bool


@dataclass
class Reading:
    """A command's pipelines (each its parent's pipeline and segment, or None, and its segments'
    spans), its closed heredocs, its here-strings (each its pipeline, its segment and its word),
    where its reading ended: past the ) that closes a group's reading, else the text's end, and
    each subscript read as one bracket pair in an assignment's place, where its word starts mapped
    to just past its ]."""

    pipelines: list
    heredocs: list
    strings: list
    end: int
    subscripts: dict


def _word(text, i):
    """The word at i as Bash reads it, its quotes removed: (word, quoted, end); word is None when a
    quote in it never closes."""
    out, quoted, n = [], False, len(text)
    while i < n and text[i] not in METACHARACTERS:
        c = text[i]
        if c == "\\":
            out.append(text[i + 1 : i + 2].replace("\n", ""))
            quoted, i = True, i + 2
        elif c in "'\"" or text.startswith("$'", i):
            ansi, close = c == "$", '"' if c == '"' else "'"
            j = i + 1 + ansi
            while j < n and text[j] != close:
                escaped = text[j + 1 : j + 2]
                if text[j] == "\\" and escaped and (ansi or (close == '"' and escaped in '\\"$`\n')):
                    out.append(escaped.replace("\n", ""))
                    j += 2
                else:
                    out.append(text[j])
                    j += 1
            if j >= n:
                return None, True, n
            quoted, i = True, j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out), quoted, i


def _past_blanks(text, i):
    """The first index at or after i that is no blank."""
    while text[i : i + 1] in (" ", "\t"):
        i += 1
    return i


def _pair_end(text, j, open_, close, flags=""):
    """Past the close that matches open_, read from j, just after open_, as Bash's
    parse_matched_pair reads it, or len(text) when none does. flags "esc" lets a backslash quote
    in '...' ($'...'), "first" ends at the first close (${...}), and "arith" reads only a $( whole
    (the span after (( or $((, P_ARITH). In a group ((...), ${...} or $[...]) a quote or backtick
    nests and a $(, ${ or $[ is read whole, a $( by the scan, as Bash's parse_comsub; in "..." a
    backtick, $(, ${ and $[ do; elsewhere only a backslash."""
    n, count, dollar = len(text), 1, False
    while j < n:
        ch = text[j]
        if open_ == "'":
            if ch == "'":
                return j + 1
            j += 2 if ch == "\\" and flags == "esc" else 1
            continue
        if ch == "\\":
            j, dollar = j + 2, False
            continue
        if ch == close:
            count -= 1
            if count == 0:
                return j + 1
        elif ch == open_ and flags != "first" and open_ != close:
            count += 1
        if open_ != close and ch in "'\"`":
            j = _pair_end(text, j + 1, ch, ch, "esc" if dollar and ch == "'" else "")
        elif open_ == '"' and ch == "`":
            j = _pair_end(text, j + 1, "`", "`")
        elif open_ != "`" and dollar and (ch == "(" or ch in "{[" and flags != "arith"):
            # Bash undoes the count its open added, which a ${...} never does.
            count -= open_ == ch and flags != "first"
            if ch == "(":
                j = _group_end(text, j + 1)
            else:
                j = _pair_end(text, j + 1, ch, "}" if ch == "{" else "]", "first" if ch == "{" else "")
        else:
            dollar, j = ch == "$" and not dollar, j + 1
            continue
        dollar = False
    return n


# _arith_end and _group_end keep their answers for the text being read, which read_command clears
# for each new one: deciding a (( reads each $( in it, whose reading decides each (( in that, so
# with no memo nested ((cmd) ) groups would take time doubling with each level.
@functools.lru_cache(maxsize=None)
def _arith_end(text, i):
    """The end of the arithmetic whose (( starts at i, or None when the ) closing its second ( is
    not right before another, as in ((cmd) ), which Bash reads as two subshells (parse_arith_cmd)."""
    end = _pair_end(text, i + 2, "(", ")", "arith")
    return end + 1 if text[end : end + 1] == ")" else None


@functools.lru_cache(maxsize=None)
def _group_end(text, j):
    """Past the ) that closes the group whose ( is just before j, as the scan reads it."""
    return read_command(text, j, group=True).end


def _closing(text, pos, word, tabs):
    """The start and end of the line at or after pos that closes a heredoc on word, or None."""
    while True:
        end = text.find("\n", pos)
        end = len(text) if end < 0 else end
        if (text[pos:end].lstrip("\t") if tabs else text[pos:end]) == word:
            return pos, end
        if end == len(text):
            return None
        pos = end + 1


def read_command(text, start=0, group=False):
    """The command's reading, as Reading says, from one pass over its text from start; with group,
    the reading of a group whose ( is just before start, ended by its )."""
    if not group:
        _arith_end.cache_clear()
        _group_end.cache_clear()
    pipelines, heredocs, strings, pending = [], [], [], []
    # Each group open at i: its kind (root, (, `, {, ${, [[, an array assignment's list, a case's
    # case-word, case-pattern or case-body, or a COMPOUNDS kind: if, for or loop), its pipeline,
    # where its segment starts, whether a pipe began that segment, the quote it sits in, whether a
    # reserved word may come next (True, False, or "name", "coproc", "time" or "time -p" after
    # function, coproc, time or time's -p; or "assign" where only assignments and redirections came
    # before in the command, so no reserved word may come but an element's assignment may, and
    # "target" where a redirection's target comes next in such a place), and that state for its
    # parent once it ends: a compound command's end lets one come, a word's part does not, but for
    # keeping its assignment's place.
    frames = []
    # Each arithmetic open at i, $((, $[ or ((, or an element's subscript in an assignment's place,
    # read only for the substitutions in it, which Bash runs: the depth of the frames it sits in,
    # where its closing )) or ] starts, where it ends, the quote to go back to after it, and the
    # state it leaves, or None for its word's: an arithmetic command lets a reserved word come, a
    # subscript keeps its assignment's place when its = follows.
    ariths = []
    subscripts = {}
    quote, i, n = None, start, len(text)

    def here():
        return frames[-1][1], len(pipelines[frames[-1][1]][1])

    def end_segment(at):
        pipelines[frames[-1][1]][1].append((frames[-1][2], at))

    def push(kind, at, resume=None, ends=False):
        pipelines.append((here() if frames else None, []))
        frames.append([kind, len(pipelines) - 1, at, False, resume, True, ends])

    def pop(at):
        end_segment(at)
        frame = frames.pop()
        if frames:
            frames[-1][5] = True if frame[6] else "assign" if frames[-1][5] == "assign" else False
        return frame[4]

    def next_pipeline(at, after):
        end_segment(at)
        pipelines.append((pipelines[frames[-1][1]][0], []))
        frames[-1][1:4] = [len(pipelines) - 1, after, False]
        frames[-1][5] = True

    def reserved():
        """Whether a reserved word may come here: never in an array assignment's list."""
        return frames[-1][0] != "array" and frames[-1][5] in (True, "coproc", "time", "time -p")

    def bodies(pos):
        """Read the pending heredocs' bodies from pos on, each up to its closing line, and return
        where the last closing line ends, or None when the first has none."""
        last = None
        for pipeline, segment, start, marker_end, word, quoted, tabs in pending:
            found = _closing(text, pos, word, tabs) if pos <= n else None
            if found is None:
                break
            heredocs.append(Heredoc(pipeline, segment, (start, marker_end), (pos, found[0]), found[1], quoted))
            pos, last = found[1] + 1, found[1]
        pending.clear()
        return last

    def word_at(at):
        """A word that is no reserved word starts at at, or goes on there: one may follow it only
        as function's or coproc's name, and a redirection's target keeps its assignment's place."""
        if at == 0 or text[at - 1] in METACHARACTERS:
            state = frames[-1][5]
            frames[-1][5] = "assign" if state == "target" else state in ("name", "coproc")

    push("(" if group else "root", start)
    while i < n and frames:
        c, kind = text[i], frames[-1][0]
        if quote in ("'", "$'"):
            if c == "\\" and quote == "$'":
                i += 2
                continue
            quote, i = None if c == "'" else quote, i + 1
            continue
        if c == "\\":
            word_at(i)
            i += 2
            continue
        if quote == '"':
            if text.startswith("$((", i) and (arith := _arith_end(text, i + 1)):
                ariths.append((len(frames), arith - 2, arith, '"', None))
                quote, i = None, i + 3
            elif text.startswith("$(", i) or text.startswith("${", i) or c == "`":
                push("`" if c == "`" else "(" if text[i + 1] == "(" else "${", i + 1 + (c == "$"), '"')
                quote, i = None, i + 1 + (c == "$")
            else:
                quote, i = None if c == '"' else quote, i + 1
            continue
        if ariths and ariths[-1][0] == len(frames):
            # In arithmetic only a quote, a $(, a backtick and a nested $(( are read, to its close.
            _, close, end, resume, after = ariths[-1]
            if i >= close:
                ariths.pop()
                quote, i = resume, max(i, end)
                if after is not None:
                    frames[-1][5] = after
            elif c in "'\"" or text.startswith("$'", i):
                quote, i = "$'" if c == "$" else c, i + 1 + (c == "$")
            elif text.startswith("$((", i) and (arith := _arith_end(text, i + 1)):
                ariths.append((len(frames), arith - 2, arith, None, None))
                i += 3
            elif text.startswith("$(", i) or c == "`":
                push("`" if c == "`" else "(", i + 1 + (c == "$"))
                i += 1 + (c == "$")
            else:
                i += 1
            continue
        if c in "'\"" or text.startswith("$'", i):
            word_at(i)
            quote, i = "$'" if c == "$" else c, i + 1 + (c == "$")
        elif text.startswith("$((", i) and (arith := _arith_end(text, i + 1)):
            word_at(i)
            ariths.append((len(frames), arith - 2, arith, None, None))
            i += 3
        elif text.startswith("$[", i):
            word_at(i)
            end = _pair_end(text, i + 2, "[", "]")
            ariths.append((len(frames), end - (text[end - 1 : end] == "]"), end, None, None))
            i += 2
        elif kind not in ("${", "[[") and text.startswith("((", i) and (arith := _arith_end(text, i)):
            # An arithmetic command, a compound one.
            ariths.append((len(frames), arith - 2, arith, None, True))
            i += 2
        elif text.startswith("$(", i) or text.startswith("${", i):
            word_at(i)
            push("(" if text[i + 1] == "(" else "${", i + 2)
            i += 2
        elif c == "`":
            if kind == "`":
                quote = pop(i)
            else:
                word_at(i)
                push("`", i + 1)
            i += 1
        elif kind == "${":
            # In ${...} quotes nest, and its first } ends it; nothing else is an operator.
            if c == "}":
                quote = pop(i)
            i += 1
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif kind == "[[":
            # In [[ ... ]] nothing is an operator but its ]]; a newline reads the pending bodies.
            if text.startswith("]]", i) and text[i - 1] in METACHARACTERS and text[i + 2 : i + 3] in METACHARACTERS | {""}:
                pop(i)
                i += 1
            elif c == "\n" and pending:
                last = bodies(i + 1)
                if last is not None:
                    i = last
                    continue
            i += 1
        elif kind == "case-pattern" and c in "(|":
            # A pattern's opening parenthesis or its alternatives' bar.
            i += 1
        elif c == "(":
            # A subshell, a function's () or body, or a word's part: a process substitution, which
            # as a redirection's target keeps its assignment's place, or an array assignment's list.
            array = text[i - 1 : i] == "="
            substitution = array or text[i - 1 : i] in ("<", ">")
            if substitution and not array:
                frames[-1][5] = "assign" if frames[-1][5] == "target" else False
            push("array" if array else "(", i + 1, ends=not substitution)
            i += 1
        elif c == ")":
            if kind in ("(", "array"):
                quote = pop(i)
            else:
                # A case pattern's end, after which its command starts; else one Bash would refuse.
                next_pipeline(i, i + 1)
                if kind == "case-pattern":
                    frames[-1][0] = "case-body"
            i += 1
        elif c == "{" and reserved() and text[i + 1 : i + 2] in (" ", "\t", "\n") and (i == 0 or text[i - 1] in METACHARACTERS):
            push("{", i + 1, ends=True)
            i += 1
        elif c == "}" and kind == "{" and reserved() and text[i - 1] in METACHARACTERS and text[i + 1 : i + 2] in METACHARACTERS | {""}:
            pop(i)
            if frames and frames[-1][0] == "for":
                pop(i + 1)
            i += 1
        elif text.startswith("<<<", i):
            word, _, end = _word(text, _past_blanks(text, i + 3))
            if word is not None:
                strings.append((*here(), word))
            i = max(end, i + 3)
        elif text.startswith("<<", i):
            tabs = text.startswith("<<-", i)
            word, quoted, end = _word(text, _past_blanks(text, i + 2 + tabs))
            if word is not None and (word or quoted):
                pending.append((*here(), i, end, word, quoted, tabs))
                i = end
            else:
                i += 2
        elif c == "|" and text[i - 1 : i] != ">":
            if text.startswith("||", i):
                next_pipeline(i, i + 2)
                i += 2
            else:
                step = 2 if text.startswith("|&", i) else 1
                end_segment(i)
                frames[-1][2:4] = [i + step, True]
                frames[-1][5] = True
                i += step
        elif kind == "case-body" and text[i : i + 2] in (";;", ";&"):
            # A case item's end, after which the next pattern comes.
            step = 3 if text.startswith(";;&", i) else 2
            next_pipeline(i, i + step)
            frames[-1][0] = "case-pattern"
            i += step
        elif c in ";&\n" and not (c == "&" and (text[i - 1 : i] in (">", "<") or text[i + 1 : i + 2] == ">")):
            step = 2 if text[i : i + 2] in ("&&", ";;", ";&") else 1
            # A pipe at a line's end carries its pipeline on to the next line.
            if not (c == "\n" and frames[-1][3] and not text[frames[-1][2] : i].strip()):
                next_pipeline(i, i + step)
            if c == "\n" and pending:
                last = bodies(i + 1)
                if last is not None:
                    # The next segment starts after the bodies.
                    frames[-1][2], frames[-1][5], i = last, True, last
                    continue
            i += step
        else:
            # A word, read as a reserved word where one may come: case's, in after its word and
            # esac in place of a pattern, [[, and those after which another may come (OPENS).
            found = WORD.match(text, i) if i == 0 or text[i - 1] in METACHARACTERS else None
            word = found and found.group()
            if word == "in" and kind == "case-word":
                frames[-1][0] = "case-pattern"
            elif word == "esac" and (kind == "case-pattern" or (kind == "case-body" and reserved())):
                pop(i)
            elif word == "case" and reserved() and kind not in ("case-word", "case-pattern"):
                push("case-word", i + 4, ends=True)
            elif word == "[[" and reserved():
                push("[[", i + 2, ends=True)
            elif word in COMPOUNDS and reserved() and kind not in ("case-word", "case-pattern"):
                push(COMPOUNDS[word][0], i + len(word), ends=True)
                frames[-1][5] = COMPOUNDS[word][1]
            elif word == "do" and reserved() and kind == "for":
                frames[-1][0], frames[-1][5] = "loop", True
            elif word in ENDS and reserved() and kind == ENDS[word]:
                pop(i)
            elif word in OPENS and reserved():
                frames[-1][5] = OPENS[word]
            elif word == "-p" and frames[-1][5] == "time":
                frames[-1][5] = "time -p"
            elif word == "--" and frames[-1][5] in ("time", "time -p"):
                frames[-1][5] = True
            else:
                # In an assignment's place (Bash's assignment_acceptable), a redirection keeps it,
                # its target read as the next word, and Bash's lexer reads an element's subscript
                # as one bracket pair before it looks for an operator, so a separator, a comment or
                # a newline in it is part of the word.
                begins = i == 0 or text[i - 1] in METACHARACTERS
                place = (
                    begins
                    and kind not in ("case-word", "case-pattern", "array")
                    and (reserved() or frames[-1][5] == "assign")
                )
                redirect = place and REDIRECT.match(text, i)
                subscript = place and SUBSCRIPTED.match(text, i)
                pair = subscript and _pair_end(text, subscript.end(), "[", "]")
                if redirect and "<<" in redirect.group():
                    # A heredoc's or here-string's fd, whose operator its own branch reads.
                    i += redirect.group().index("<<")
                    continue
                if redirect and text[redirect.end() : redirect.end() + 1] != "(":
                    frames[-1][5] = "target"
                    i = redirect.end()
                    continue
                if pair and text[pair - 1] == "]":
                    frames[-1][5] = "assign" if text.startswith(("=", "+="), pair) else False
                    subscripts[i] = pair
                    ariths.append((len(frames), pair - 1, pair, None, frames[-1][5]))
                    i = subscript.end()
                    continue
                if word:
                    word_at(i)
                    if place and ASSIGNED.match(text, i):
                        frames[-1][5] = "assign"
                word = None
            i += len(word) if word else 1
    end = n if frames else i
    while frames:
        pop(n)
    return Reading(pipelines, heredocs, strings, end, subscripts)


def without_heredocs(command):
    """The command with each closed heredoc's marker and body left out, the rest of its marker's
    line kept."""
    reading = read_command(command)
    out, start = [], 0
    for begin, end in sorted([h.marker for h in reading.heredocs] + [(h.body[0] - 1, h.end) for h in reading.heredocs]):
        out.append(command[start:begin])
        start = end
    return "".join(out) + command[start:]


def _substitution(line):
    """Where the first command substitution ($( or a backtick) of an unquoted heredoc body's line
    starts, past each backslash and the character it escapes, as Bash reads the body, or None."""
    i = 0
    while i < len(line):
        if line[i] == "\\":
            i += 2
            continue
        if line.startswith("$(", i) or line[i] == "`":
            return i
        i += 1
    return None


def _fed(reading, shells, pipeline, segment):
    """Whether a shell may read what the segment's command writes or reads as its script."""
    while not any(shells[pipeline][segment:]):
        if reading.pipelines[pipeline][0] is None:
            return False
        pipeline, segment = reading.pipelines[pipeline][0]
    return True


def _runs_shell(command, start, end, bodies, subscripts):
    """Whether a simple command of the segment from start to end, or one it runs (in a string, by
    find -exec), is a shell that may read its script from stdin, as the header says."""
    for words in _segment_commands(command, start, end, bodies, subscripts):
        for found in _walk(words, command, 0, (), DIRECT):
            name = os.path.basename(found.words[0]) if found.words else ""
            if name in SHELLS or name == "source" or (name == "." and len(found.words) > 1):
                return True
    return False


def code_text(command):
    """The command's text as code: heredoc bodies out, run strings and fed text added, as the
    header says, its parts (code_parts) one per line."""
    return "\n".join(code_parts(command))


def code_parts(command):
    """The command's code text in parts: the command with its heredoc bodies out, then each string
    and fed text added, each a part of its own, so a walk of each alone leaves no quote, group or
    heredoc one opens to hide another, then the parts of each script it writes and runs."""
    return _code_parts(command, 0)


def _code_parts(command, depth):
    """code_parts of a command, or of a script written depth scripts deep in one."""
    if depth > DEPTH:
        raise ValueError(f"a written script nested deeper than {DEPTH}")
    reading = read_command(command)
    bodies = {h.body[0]: h.end for h in reading.heredocs}
    shells = [
        [_runs_shell(command, s, e, bodies, reading.subscripts) for s, e in segments]
        for _, segments in reading.pipelines
    ]
    # A segment is a shell too when a group or substitution in it starts one, (bash) or >(bash),
    # since it reads the segment's stdin; a group's pipelines come after its parent's.
    for (parent, _), shell in reversed(list(zip(reading.pipelines, shells))):
        if parent is not None and any(shell):
            shells[parent[0]][parent[1]] = True
    out, start = [], 0
    for heredoc in reading.heredocs:
        lines = command[heredoc.body[0] : heredoc.body[1]].split("\n")[:-1]
        if _fed(reading, shells, heredoc.pipeline, heredoc.segment):
            code = lines
        elif heredoc.quoted:
            code = []
        else:
            code = [line[found:] for line in lines if (found := _substitution(line)) is not None]
        out += [command[start : heredoc.body[0] - 1]] + ["\n" + line for line in code]
        start = heredoc.end
    text = "".join(out) + command[start:]
    # One pass finds a string inside another too, since a quote before a shell or eval is no
    # word character: bash -c "bash -c 'x'" adds both strings. Each is added to its line's end
    # only: its later lines already start lines of the text.
    added = [OPENING.sub("", text[match.end() :].split("\n", 1)[0]) for match in RUNS_STRING.finditer(text)]
    added += [word for pipeline, segment, word in reading.strings if _fed(reading, shells, pipeline, segment)]
    for (_, segments), shell in zip(reading.pipelines, shells):
        for k in range(1, len(segments)):
            if not shell[k]:
                continue
            for s, e in segments[:k]:
                piped = command[s:e]
                added += [single or double for single, double in QUOTED.findall(piped)]
                for simple in SIMPLE.split(piped.replace("'", "").replace('"', "")):
                    words = simple.split(None, 1)
                    added += words[1:]
                # What echo or printf prints into the pipe, decoded, as _writes reads it for a file.
                for words in _segment_commands(command, s, e, bodies, reading.subscripts):
                    added += list(_printed(words))
    parts = [text] + [inner for inner in added if inner]
    return parts + _scripts(command, reading, parts, depth)


def blank_heredocs(part):
    """A part of the command's code text, with the operator and marker of each heredoc it still
    opens blanked, so a walk reads every line of it as code: a body a shell reads, kept whole, and
    the lines after a heredoc whose body is left out."""
    out, start = [], 0
    for heredoc in sorted(read_command(part).heredocs, key=lambda heredoc: heredoc.marker[0]):
        begin, end = heredoc.marker
        out += [part[start:begin], " " * (end - begin)]
        start = end
    return "".join(out) + part[start:]


def _scripts(command, reading, parts, depth):
    """The code parts of each script the command writes to a file (_writes) and runs, as the header
    says: each file's pieces joined in the order they were found, as written and with echo's
    escapes decoded, each a script read by code_parts in its turn, whose runs count too."""
    pieces = {}
    writes = _writes(command, reading) + [found for part in parts[1:] for found in _writes(part)]
    for file, piece in writes:
        found = pieces.setdefault(os.path.normpath(file), []) if file else [piece]
        if piece not in found:
            found.append(piece)
    if not pieces:
        return []
    runs = _runs([command], blank=False) | _runs(parts)
    out, kept = [], set()
    while new := [file for file in pieces if file in runs and file not in kept]:
        for file in new:
            kept.add(file)
            written = ["".join(piece[variant] for piece in pieces[file]) for variant in (0, -1)]
            for script in dict.fromkeys(written):
                found = _code_parts(script, depth + 1)
                out += found
                runs |= _runs(found)
    return out


def _runs(texts, blank=True):
    """Each file the texts may run as a script, normalized: the first word of each Command their
    walk yields, a shell's script file and a sourced file among them; with blank, each text is a
    code part, whose open heredocs are blanked first."""
    return {
        os.path.normpath(found.words[0])
        for text in texts
        for found in commands(blank_heredocs(text) if blank else text)
        if found.words and found.words[0]
    }


def _writes(text, reading=None):
    """Each file the text writes a piece of text to, with that piece as variants (as written, and
    decoded as another echo would), in the order found: a heredoc's body, a here-string and what
    echo and printf print, when the output of their pipeline segment, of a later segment it is
    piped into, or of a segment holding the group or compound command it stands in, goes to a file
    (> f, >> f, >| f, &> f, >& f, 1> f, or tee's files)."""
    reading = reading or read_command(text)
    bodies = {h.body[0]: h.end for h in reading.heredocs}
    own, simple = [], []
    for _, segments in reading.pipelines:
        own.append([])
        simple.append([])
        for start, end in segments:
            redirects = []
            found = _segment_commands(text, start, end, bodies, reading.subscripts, redirects)
            files = [target for operator, target in redirects if _to_file(operator, target)]
            for words in found:
                _, words, _, _ = _command(list(words))
                if words and os.path.basename(words[0]) == "tee":
                    files += _tee_files(words[1:])
            own[-1].append(files)
            simple[-1].append(found)

    def reached(pipeline, segment):
        files = []
        while True:
            files += [file for later in own[pipeline][segment:] for file in later]
            if reading.pipelines[pipeline][0] is None:
                return files
            pipeline, segment = reading.pipelines[pipeline][0]

    pieces = []
    for heredoc in reading.heredocs:
        lines = text[heredoc.body[0] : heredoc.body[1]].split("\n")[:-1]
        body = "".join(line + "\n" for line in lines)
        pieces += [(file, (body,)) for file in reached(heredoc.pipeline, heredoc.segment)]
    for pipeline, segment, word in reading.strings:
        pieces += [(file, (word + "\n",)) for file in reached(pipeline, segment)]
    for pipeline, segments in enumerate(simple):
        for segment, found in enumerate(segments):
            files = reached(pipeline, segment)
            for words in found if files else ():
                printed = _printed(words)
                pieces += [(file, printed) for file in files if printed]
    return pieces


def _to_file(operator, target):
    """Whether a redirection sends standard output to the file target."""
    fd, operator = re.fullmatch(r"([0-9]*|\{\w+\})(.*)", operator).groups()
    if operator in ("&>", "&>>"):
        return not fd
    if operator in (">", ">>", ">|"):
        return fd in ("", "1")
    return operator == ">&" and fd in ("", "1") and not re.fullmatch(r"[0-9]*-?", target)


def _tee_files(args):
    """tee's files: its operands, past its options up to a --."""
    files, options = [], True
    for word in args:
        if options and word == "--":
            options = False
        elif not (options and word.startswith("-") and word != "-"):
            files.append(word)
    return files


# An escape echo -e, printf's format and its %b decode: \c ends the output, octal is \0 and up to
# three digits for echo and %b, one to three for the format, and \x, \u and \U take hex digits.
ESCAPE = re.compile(
    r"\\(?:([abeEfnrtv\\'\"?])|(0[0-7]{0,3}|[0-7]{1,3})|x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})"
    r"|U([0-9A-Fa-f]{1,8})|(c))"
)
ESCAPES = dict(zip("abeEfnrtv", "\a\b\x1b\x1b\f\n\r\t\v"))
# A conversion of printf's format: %% or one with its flags, width and precision.
CONVERSION = re.compile(r"%(?:%|[-+ #0']*(\*|[0-9]*)(?:\.(\*|[0-9]*))?([A-Za-z]))")


def _decoded(text, format_=False):
    """The text with its escapes decoded, as echo -e and %b do it, or as printf's format does with
    format_ (its octal needs no leading 0); and whether a \\c ended it."""
    out, i = [], 0
    for found in ESCAPE.finditer(text):
        out.append(text[i : found.start()])
        i = found.end()
        plain, octal, hex_, short, long_, stop = found.groups()
        if stop:
            return "".join(out), True
        if plain:
            out.append(ESCAPES.get(plain, plain))
        elif octal is not None:
            if not format_ and not octal.startswith("0"):
                out.append(found.group())
            else:
                digits = octal[1:] if not format_ and octal.startswith("0") else octal
                out.append(chr(int(digits or "0", 8) & 0xFF))
        else:
            code = int(hex_ or short or long_, 16)
            out.append(chr(code) if code < 0x110000 else found.group())
    return "".join(out) + text[i:], False


def _printed(words):
    """What echo or printf prints with words, past its wrappers, as variants: echo's text as written
    and decoded, as another shell's echo or echo -e decodes it; printf's output, its format used
    again while its arguments last; empty for any other command, or printf -v, which prints none."""
    _, words, _, _ = _command(list(words))
    if not words:
        return ()
    name, args = os.path.basename(words[0]), words[1:]
    if name == "echo":
        flags = ""
        while args and re.fullmatch(r"-[neE]+", args[0]):
            flags += args.pop(0)[1:]
        text = " ".join(args)
        decoded, stopped = _decoded(text)
        end = "" if "n" in flags or stopped else "\n"
        if flags.rfind("e") > flags.rfind("E"):
            return (decoded + end,)
        return tuple(dict.fromkeys((text + ("" if "n" in flags else "\n"), decoded + end)))
    if name != "printf":
        return ()
    if args[:1] == ["--"]:
        args = args[1:]
    if not args or args[0].startswith("-v"):
        return ()
    form, values, out = args[0], args[1:], []
    while True:
        used, i = 0, 0
        for found in CONVERSION.finditer(form):
            literal, stopped = _decoded(form[i : found.start()], format_=True)
            out.append(literal)
            if stopped:
                return ("".join(out),)
            i = found.end()
            width, precision, kind = found.groups()
            if found.group() == "%%":
                out.append("%")
                continue
            used += (width == "*") + (precision == "*")
            value = values[used] if used < len(values) else ""
            used += 1
            if kind == "b":
                value, stopped = _decoded(value)
                out.append(value)
                if stopped:
                    return ("".join(out),)
            else:
                quoted = shlex.quote(value) if kind == "q" and value else value
                out.append(value[:1] if kind == "c" else quoted)
        literal, stopped = _decoded(form[i:], format_=True)
        out.append(literal)
        values = values[used:]
        if stopped or not used or not values:
            return ("".join(out),)


# The reserved words a simple command's words may start with, which are no part of it.
LEADING = frozenset(
    ("!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac",
     "coproc")
)


def _closed(text, i, j, end):
    """Whether the quote opened at i and read to j, just past what closes it, closes before end."""
    return i + 1 < j <= end and text[j - 1] == text[i]


def _command_word(text, i, end):
    """The word at i, before end, as a command's argument, and where it ends: its quotes removed,
    as _word reads them, but for a quote's text holding $ or a backtick and a substitution, $(...),
    `...`, ${...}, $((...)) or $[...], which are kept as written, so a word built by one still holds
    its $ or backtick (in a double quote holding one, an escaped double quote or backslash is
    undone all the same, an escaped $ or backtick kept), a $"..." read as a double quote; a $'...'
    string's escapes are decoded as Bash decodes them, and a word one changed is a Word whose
    written keeps them; a quote that does not close before end ends the word, and the segment with
    it (end is where it returns):
    code_text adds a -c string's line with its closing quote left on, and what follows that quote
    is the outer command's, never the string's."""
    out, kept = [], []
    while i < end:
        c = text[i]
        if c in METACHARACTERS:
            if c != "(" or not out or text[i - 1] != "=":
                break
            # An array assignment's list.
            j = _group_end(text, i + 1)
        elif c == "\\":
            out.append(text[i + 1 : i + 2].replace("\n", ""))
            kept.append(out[-1])
            i += 2
            continue
        elif text.startswith("$((", i) and (arith := _arith_end(text, i + 1)):
            j = arith
        elif text.startswith("$(", i):
            j = _group_end(text, i + 2)
        elif text.startswith("${", i):
            j = _pair_end(text, i + 2, "{", "}", "first")
        elif text.startswith("$[", i):
            j = _pair_end(text, i + 2, "[", "]")
        elif c == "`":
            j = _pair_end(text, i + 1, "`", "`")
        elif c in "'\"" or text.startswith(("$'", '$"'), i):
            # A $"..." locale string is a double quote, its text as written in the C locale.
            dollar = c == "$"
            mark = text[i + 1] if dollar else c
            ansi = dollar and mark == "'"
            j = _pair_end(text, i + 1 + dollar, mark, mark, "esc" if ansi else "")
            if not _closed(text, i + dollar, j, end):
                i = end
                break
            inner = text[i + 1 + dollar : j - 1]
            if mark == '"':
                # One holding $ or a backtick keeps its escaped ones, so it still holds one.
                escaped = r"\\([\\\"])" if "$" in inner or "`" in inner else r"\\([\\\"$`])"
                inner = re.sub(escaped, r"\1", inner).replace("\\\n", "")
            kept.append(inner)
            out.append(_ansi(inner) if ansi else inner)
            i = j
            continue
        else:
            out.append(c)
            kept.append(c)
            i += 1
            continue
        out.append(text[i : min(j, end)])
        kept.append(out[-1])
        i = j
    word, written = "".join(out), "".join(kept)
    return (word if word == written else Word.of(word, written)), i


class Word(str):
    """A word of the walk that Bash makes otherwise than it is written, by a $'...' escape or a
    brace range: written is the word as written, its quotes removed and its escapes kept, by which
    a reader that does not follow such a word (delete_rules.py) names it."""

    written = None

    @classmethod
    def of(cls, word, written):
        made = cls(word)
        made.written = written
        return made


def _ansi(text):
    """A $'...' string's text with its escapes decoded, as Bash's ansicstr decodes them: \\cX a
    control character, octal one to three digits, \\x one or two hex digits, \\u four, \\U eight."""
    out, i = [], 0
    while (k := text.find("\\", i)) >= 0:
        out.append(text[i:k])
        found = ESCAPE.match(text, k)
        if found is None:
            out.append(text[k : k + 2])
            i = k + 2
            continue
        plain, octal, hex_, short, long_, control = found.groups()
        i = found.end()
        if control:
            following = text[i : i + 1]
            out.append(chr(ord(following) & 0x1F) if following else "\\c")
            i += len(following)
        elif plain:
            out.append(ESCAPES.get(plain, plain))
        elif octal is not None:
            digits = octal[:3]
            out.append(chr(int(digits, 8) & 0xFF))
            i = k + 1 + len(digits)
        else:
            code = int(hex_ or short or long_, 16)
            out.append(chr(code) if code < 0x110000 else found.group())
    return "".join(out) + text[i:]


# A $'...' string in a command's text, its escaped characters inside it.
ANSI_STRING = re.compile(r"\$'((?:[^'\\]|\\.)*)'", re.S)


def unquoted(text):
    """The text as Bash reads the names in it: its line continuations (a backslash-newline)
    dropped, each $'...' string's escapes decoded, the $ of each $"..." dropped, and its quotes and
    backslashes removed; so a name spelled with them (cdable_v''ars, C\\DPATH, $'\\x65xtglob') is
    the name, though the text's words may run together."""
    text = ANSI_STRING.sub(lambda found: _ansi(found.group(1)), text.replace("\\\n", ""))
    return re.sub(r"['\"\\]", "", text.replace('$"', '"'))


# The most words one word's brace expansion may give; past it the walk raises, so a guard refuses.
MAX_BRACED = 4096
# A brace range's ends: two whole numbers, or two letters, and an optional step.
RANGE = re.compile(
    r"([-+]?[0-9]+)\.\.([-+]?[0-9]+)(?:\.\.([-+]?[0-9]+))?|([A-Za-z])\.\.([A-Za-z])(?:\.\.([-+]?[0-9]+))?"
)


def _brace_marks(raw):
    """Where the {, , and } of a word's text stand outside its quotes, escapes, substitutions and
    parameters, the only ones Bash's brace expansion reads."""
    marks, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "\\":
            i += 2
        elif raw.startswith("$((", i) and (arith := _arith_end(raw, i + 1)):
            i = arith
        elif raw.startswith("$(", i):
            i = _group_end(raw, i + 2)
        elif raw.startswith("${", i):
            i = _pair_end(raw, i + 2, "{", "}", "first")
        elif raw.startswith("$[", i):
            i = _pair_end(raw, i + 2, "[", "]")
        elif c == "`":
            i = _pair_end(raw, i + 1, "`", "`")
        elif raw.startswith("$'", i):
            i = _pair_end(raw, i + 2, "'", "'", "esc")
        elif c in "'\"":
            i = _pair_end(raw, i + 1, c, c)
        else:
            if c in "{,}":
                marks.append(i)
            i += 1
    return marks


def _range(body):
    """A brace range's words, as Bash's brace expansion gives them, or None when body is none."""
    found = RANGE.fullmatch(body)
    if not found:
        return None
    first, last, step, low, high, letter_step = found.groups()
    step = abs(int(step or letter_step or 1)) or 1
    if first is not None:
        a, b = int(first), int(last)
        padded = re.match(r"[-+]?0[0-9]", first) or re.match(r"[-+]?0[0-9]", last)
        width = max(len(first), len(last)) if padded else 0
        values = range(a, b + 1, step) if a <= b else range(a, b - 1, -step)
        if len(values) > MAX_BRACED:
            raise ValueError(f"a brace expansion longer than {MAX_BRACED} words")
        return [f"{value:0{width}d}" if width else str(value) for value in values]
    a, b = ord(low), ord(high)
    values = range(a, b + 1, step) if a <= b else range(a, b - 1, -step)
    return [chr(value) for value in values]


def _braced(raw):
    """A word's text brace-expanded as Bash expands it, each piece still as written, and whether a
    range made any: its first {...} holding a , outside a nested one, or a range, expanded, then
    each piece in turn; a { with neither is a character of the word."""
    marks = _brace_marks(raw)
    for k, start in enumerate(marks):
        if raw[start] != "{":
            continue
        depth, commas, close = 0, [], None
        for mark in marks[k:]:
            if raw[mark] == "{":
                depth += 1
            elif raw[mark] == "}":
                depth -= 1
                if depth == 0:
                    close = mark
                    break
            elif depth == 1:
                commas.append(mark)
        if close is None:
            continue
        head, tail = raw[:start], raw[close + 1 :]
        if commas:
            bounds = [start] + commas + [close]
            middles, ranged = [raw[a + 1 : b] for a, b in zip(bounds, bounds[1:])], False
        else:
            middles, ranged = _range(raw[start + 1 : close]), True
            if middles is None:
                continue
        out = []
        for middle in middles:
            pieces, inner = _braced(head + middle + tail)
            out += pieces
            ranged = ranged or inner
            if len(out) > MAX_BRACED:
                raise ValueError(f"a brace expansion longer than {MAX_BRACED} words")
        return out, ranged
    return [raw], False


def _brace_words(raw, word):
    """The words Bash's brace expansion makes of a word whose text is raw: word itself when it
    makes none; each piece's quotes removed as _command_word removes them, an empty one dropped,
    and each a Word, written as word, when a range made them."""
    if "{" not in raw:
        return [word]
    pieces, ranged = _braced(raw)
    if pieces == [raw]:
        return [word]
    out = []
    for piece in pieces:
        if not piece:
            continue
        made, _ = _command_word(piece, 0, len(piece))
        out.append(Word.of(made, getattr(word, "written", None) or word) if ranged else made)
    return out


def _segment_commands(text, start, end, bodies, subscripts, redirects=None):
    """The simple commands of the segment from start to end, each its words, as simple_commands
    says; bodies maps where each heredoc body starts to where its closing line ends, and subscripts
    where each subscript read_command read as one bracket pair starts its word to just past its ].
    With a redirects list, each redirection with a word as its target is appended to it as its
    operator (the fd before it included) and that word."""
    commands, words, i = [], [], start

    def close():
        while words and words[0] in LEADING:
            words.pop(0)
        if words:
            commands.append(list(words))
        words.clear()

    while i < end:
        c = text[i]
        if i in bodies:
            i = bodies[i]
        elif c in " \t":
            i += 1
        elif c == "#" and (i == start or text[i - 1] in " \t\n;&|()"):
            found = text.find("\n", i, end)
            i = end if found < 0 else found
        elif c in "<>" and text[i + 1 : i + 2] == "(":
            # A process substitution, an argument whose commands are a group of their own.
            j = _group_end(text, i + 2)
            words.append(text[i : min(j, end)])
            i = j
        elif (found := REDIRECT.match(text, i)) and found.end() <= end:
            # The operator and its target, a file, an fd or a heredoc's marker, are no words.
            i = _past_blanks(text, found.end())
            if text[i : i + 2] in ("<(", ">("):
                i = _group_end(text, i + 2)
            elif i < end and text[i] not in METACHARACTERS:
                target, i = _command_word(text, i, end)
                if redirects is not None:
                    redirects.append((found.group(), target))
        elif c == "(":
            # A subshell or an arithmetic command, whose commands are a group of their own.
            arith = _arith_end(text, i) if text.startswith("((", i) else None
            i = arith or _group_end(text, i + 1)
        elif c in METACHARACTERS:
            # A separator in a compound command, whose commands are its own pipelines too, or in a
            # quote read_command found open.
            close()
            i += 1
        elif i in subscripts:
            # An element's subscript in an assignment's place, kept as written.
            pair = min(subscripts[i], end)
            rest, after = _command_word(text, pair, end)
            words.append(text[i:pair] + rest)
            i = after
        else:
            word, j = _command_word(text, i, end)
            if ASSIGNMENT.match(word) and all(w in LEADING or ASSIGNMENT.match(w) for w in words):
                # Bash expands no brace in an assignment before a command's name.
                words.append(word)
            else:
                words += _brace_words(text[i:j], word)
            i = j
    close()
    return commands


def simple_commands(command):
    """Each simple command of every pipeline segment of the command, those in its groups and
    substitutions too, as the list of its words with their quotes removed (_command_word) and
    their braces expanded (_brace_words), but for a subscript read_command read as one bracket
    pair, kept as written to its ]: its redirections, their targets, its comments, its heredocs'
    bodies and the reserved words it starts with left out. A word holding a substitution keeps its text, $ or backtick and all; a quote that never
    closes ends its word and the rest of its segment. A segment holding a compound command yields
    its words too, split at its separators, beside the group's own commands."""
    reading = read_command(command)
    bodies = {h.body[0]: h.end for h in reading.heredocs}
    for _, segments in reading.pipelines:
        for start, end in segments:
            yield from _segment_commands(command, start, end, bodies, reading.subscripts)


# An assignment, as a command's word, of a variable or of an array's element (X[0]=1, its
# subscript as written, to its last ] before the =), which Bash refuses before a command as no
# identifier and runs the command all the same.
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*(?:\[.*\])?\+?=", re.DOTALL)
# A wrapper's number, its value with no option before it (timeout 10s).
NUMBER = re.compile(r"[0-9][0-9.]*[smhd]?")
# The commands that run the command after them, past their options.
WRAPPERS = frozenset(
    "env command builtin exec nohup time nice ionice stdbuf timeout setsid sudo doas xargs parallel"
    " watch flock".split()
)
SHELLS = frozenset("bash sh zsh dash ksh".split())
# The commands a wrapper's option never takes as its value: those whose strings the walk reads,
# and the ones outbound.py reads.
TOOLS = frozenset(("curl", "wget", "eval", "su", "script", "find")) | SHELLS

# The tools with an option whose value is the command they run as one string: its short names, its
# long names, all the tool's long options (getopt_long takes one by any prefix that names it
# alone), and its short options that take a value, so a cluster is read as getopt reads it
# (env -uSPATH is -u SPATH). env and flock are wrappers, su and script commands of their own.
STRING_OPTIONS = {
    "env": (
        "S",
        {"split-string"},
        frozenset(
            "ignore-environment null unset chdir split-string block-signal default-signal"
            " ignore-signal list-signal-handling debug help version argv0".split()
        ),
        "aCSu",
    ),
    "flock": (
        "c",
        {"command"},
        frozenset(
            "shared exclusive write unlock nonblock nb timeout wait conflict-exit-code close"
            " command no-fork fcntl verbose help version".split()
        ),
        "Ecw",
    ),
    "su": (
        "cC",
        {"command", "session-command"},
        frozenset(
            "command session-command fast login group supp-group preserve-environment pty shell"
            " whitelist-environment help version".split()
        ),
        "cCgGsw",
    ),
    "script": (
        "c",
        {"command"},
        frozenset(
            "append command echo log-in log-out log-io log-timing logging-format return flush force"
            " quiet timing output-limit help version".split()
        ),
        "BEIOTcmo",
    ),
}
# The wrappers that join their command's words into one string a shell runs.
JOINING = frozenset(("watch", "parallel"))
# find's actions that run a command, its words up to a ; or a +.
FIND_EXEC = frozenset(("-exec", "-execdir", "-ok", "-okdir"))
# parallel's separators, after which its words are inputs, not the command's.
PARALLEL_INPUTS = frozenset((":::", "::::", ":::+", "::::+"))

# A URL's scheme, which keeps a parallel input among its command's words.
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
# How a Command was reached: directly, as a simple command of the text; in a string a tool runs (a
# shell's -c, eval, trap's action, su's and script's -c, env -S, flock -c); by find's -exec; in
# what watch or parallel join; as a shell's script file; or by source or `.`.
DIRECT, STRING, FIND, JOINED = "direct", "string", "find -exec", "joined"
SCRIPT, SOURCE = "script", "source"
# The depth of strings within strings past which commands raises.
DEPTH = 20
# A shell's long options that take a value.
SHELL_VALUE_LONG = frozenset(("--rcfile", "--init-file"))


@dataclass(frozen=True)
class Command:
    """A simple command a Bash call runs: the assignments before its name, env's among them; its
    words from the name of what runs on; the wrappers it ran behind, each its own words, the
    outermost first, the command that ran its string, its find, or the shell or source that ran its
    file among them; and how it was reached (DIRECT and the rest)."""

    assignments: tuple
    words: tuple
    wrappers: tuple
    reached: str


def long_options(name, options):
    """The long options name stands for, as getopt_long takes it: itself, or those it is a prefix
    of."""
    if name in options:
        return {name}
    return {option for option in options if option.startswith(name)} if name else set()


def _string_option(word, shorts, longs, options, values):
    """The value word gives an option that names a command as one string (env's -S, flock's -c):
    the text joined to it, "" when it is the next word, or None when word is not it."""
    if word.startswith("--"):
        name, eq, value = word[2:].partition("=")
        named = long_options(name, options)
        return (value if eq else "") if len(named) == 1 and named <= longs else None
    if word.startswith("-") and word != "-":
        _, flag, joined = short_cluster(word, values)
        return joined if flag and flag in shorts else None
    return None


def _assigned(assignments):
    """The assignments as a command's text puts them, each value quoted."""
    pairs = (assignment.partition("=") for assignment in assignments)
    return "".join(f"{name}={shlex.quote(value)} " for name, _, value in pairs)


def _joined(args, parallel):
    """The command strings watch or parallel may run of its words after its name: its command's
    words joined with blanks, unquoted, as the tool joins them, from its first word that is no
    option, and from the next one too when an option before it may take that word as its value;
    under parallel, only the words before its first ::: and the inputs with a scheme after it."""
    cut = len(args)
    if parallel:
        cut = next((k for k, word in enumerate(args) if word in PARALLEL_INPUTS), cut)
    inputs = [word for word in args[cut:] if SCHEME.match(word)]
    first = next((k for k in range(cut) if not args[k].startswith("-")), None)
    if first is None:
        return []
    starts = [first]
    if first and args[first - 1].startswith("-") and first + 1 < cut:
        starts.append(first + 1)
    return [" ".join(args[start:cut] + inputs) for start in starts]


def _command(words):
    """The assignments before the command's own name, env's among them, the words from that name
    on, past its wrappers, as the header says, the command strings those wrappers run, each with
    how it is reached, and each wrapper's own words: a word after a wrapper's option is its value
    unless it names a command read here; env -S's and flock -c's value is a command string, and so
    is what watch and parallel join; under parallel, the words from its first ::: on are its
    inputs, left out but for those with a scheme, which its command takes as URLs."""
    i, n, inputs, strings, wrappers = 0, len(words), False, [], []
    while i < n and ASSIGNMENT.match(words[i]):
        i += 1
    assignments = words[:i]
    while i < n and os.path.basename(words[i]) in WRAPPERS:
        start, wrapper = i, os.path.basename(words[i])
        file_left, option = wrapper == "flock", False
        # command's options (-p, -v, -V) take no value, and builtin takes none, so the word after
        # one may be the builtin they run (source, ., trap); so does time's -p, the reserved word's
        # only option, or --, but the external time's other options, as -o FILE, take a value.
        valueless = wrapper in ("command", "builtin")
        timeless = ("-p", "--") if wrapper == "time" else ()
        inputs = inputs or wrapper == "parallel"
        if wrapper in JOINING:
            joined = _joined(words[i + 1 :], wrapper == "parallel")
            strings += [(JOINED, _assigned(assignments) + text) for text in joined]
        i += 1
        while i < n:
            word = words[i]
            string = None
            if wrapper in STRING_OPTIONS:
                string = _string_option(word, *STRING_OPTIONS[wrapper])
            if string is not None:
                # The option's value, the rest of the word or the next word, is the command, the
                # words after it its arguments.
                after = i + 1 if string else i + 2
                rest = words[after:]
                string = string or (words[i + 1] if i + 1 < n else "")
                tail = " " + shlex.join(rest) if wrapper == "env" and rest else ""
                wrappers.append(tuple(words[start:after]))
                strings.append((STRING, _assigned(assignments) + string + tail))
                return assignments, [], strings, wrappers
            if ASSIGNMENT.match(word):
                assignments.append(word)
                option = False
            elif os.path.basename(word) in TOOLS | WRAPPERS:
                break
            elif wrapper == "env" and word == "-":
                # env's lone -, -i's other name, takes no value.
                option = False
            elif word.startswith("-") and word != "-":
                option = not valueless and word not in timeless
            elif NUMBER.fullmatch(word):
                option = False
            elif option:
                option = False
            elif file_left:
                file_left = False
            else:
                break
            i += 1
        wrappers.append(tuple(words[start:i]))
    words = words[i:]
    if inputs:
        cut = next((k for k, word in enumerate(words) if word in PARALLEL_INPUTS), len(words))
        words = words[:cut] + [word for word in words[cut:] if SCHEME.match(word)]
    return assignments, words, strings, wrappers


def _option_string(args, shorts, longs, options, values):
    """The value of the option of su or script that names the command they run as one string (-c
    alone or in a cluster, or a long one by its name or a prefix, with its value joined by = or
    next), or None."""
    for k, word in enumerate(args):
        if word == "--":
            break
        string = _string_option(word, shorts, longs, options, values)
        if string is not None:
            return string or (args[k + 1] if k + 1 < len(args) else "")
    return None


def _exec_commands(args):
    """The commands find's -exec, -execdir, -ok and -okdir run, each its words up to its ; or +."""
    commands, k = [], 0
    while k < len(args):
        if args[k] in FIND_EXEC:
            end = next((j for j in range(k + 1, len(args)) if args[j] in (";", "+")), len(args))
            commands.append(args[k + 1 : end])
            k = end
        k += 1
    return commands


def _shell_string(args):
    """The string a shell's -c runs, its first word after the options, or None when it has none."""
    runs, k = False, 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            break
        if word.startswith("--"):
            continue
        if len(word) > 1 and word[0] in "-+":
            runs = runs or (word[0] == "-" and "c" in word)
            # -o and -O take an option's name.
            k += word[-1] in "oO"
            continue
        return word if runs else None
    return args[k] if runs and k < len(args) else None


def short_cluster(word, value_flags):
    """A cluster of short options read as getopt reads it: its flags up to the first that takes a
    value, that flag or None, and the value joined to it ("" when it is the next word)."""
    for k, flag in enumerate(word[1:], 1):
        if flag in value_flags:
            return word[1:k], flag, word[k + 1 :]
    return word[1:], None, ""


def _shell_script(args):
    """Where the script file is among a shell's words after its name, when it runs one: its first
    operand, past its options (-o and -O, --rcfile and --init-file with their value) and a -- or -
    that ends them; None when it has none, or a -c or -s, so it reads a string or stdin."""
    k = 0
    while k < len(args):
        word = args[k]
        if word in ("--", "-"):
            k += 1
            break
        if word.startswith("--"):
            k += 1 + (word in SHELL_VALUE_LONG)
            continue
        if len(word) > 1 and word[0] in "-+":
            if word[0] == "-" and ("c" in word or "s" in word):
                return None
            k += 1 + (word[-1] in "oO")
            continue
        break
    return k if k < len(args) else None


def _trap_action(args):
    """The action trap sets, its first operand past a --, when a signal follows it and it is no -;
    None when it has none, or an option (-p, -l or -P) makes it print."""
    if args[:1] == ["--"]:
        args = args[1:]
    elif args[:1] and args[0].startswith("-") and args[0] != "-":
        return None
    return args[0] if len(args) > 1 and args[0] != "-" else None


def _walk(words, text, depth, outer, reached):
    """The Commands of one simple command's words, of the text being walked at depth, behind the
    outer wrappers: the command itself, then what it runs, as commands says."""
    assignments, words, strings, wrappers = _command(list(words))
    behind = outer + tuple(wrappers)
    yield Command(tuple(assignments), tuple(words), behind, reached)

    def run(string, how, ran):
        if string is not None and string != text:
            yield from _commands(string, depth + 1, ran, how)

    for how, string in strings:
        yield from run(string, how, behind)
    if not words:
        return
    name, args = os.path.basename(words[0]), words[1:]
    here = behind + (tuple(words),)
    if name == "find":
        for found in _exec_commands(args):
            yield from _walk(found, text, depth, here, FIND)
    elif name in SHELLS:
        string = _shell_string(args)
        script = None if string is not None else _shell_script(args)
        if script is not None:
            shell = behind + (tuple(words[: script + 1]),)
            yield Command((), tuple(args[script:]), shell, SCRIPT)
        yield from run(string, STRING, here)
    elif name in ("source", "."):
        files = args[1:] if args[:1] == ["--"] else args
        if files:
            source = behind + (tuple(words[: len(words) - len(files)]),)
            yield Command((), tuple(files), source, SOURCE)
    elif name in STRING_OPTIONS:
        yield from run(_option_string(args, *STRING_OPTIONS[name]), STRING, here)
    elif name == "eval":
        yield from run(" ".join(args), STRING, here)
    elif name == "trap":
        yield from run(_trap_action(args), STRING, here)


def _commands(text, depth, outer, reached):
    if depth > DEPTH:
        raise ValueError(f"a command string nested deeper than {DEPTH}")
    for words in simple_commands(text):
        yield from _walk(words, text, depth, outer, reached)


def commands(text):
    """Each Command the text runs, as the header says: each simple command (simple_commands), then
    the commands of each string, find -exec, script file or sourced file it runs, in turn."""
    return _commands(text, 0, (), DIRECT)


# What runs the command after it, past its options, as a reading of where a command starts takes
# it: the wrappers and the shells.
RUNNERS = WRAPPERS | SHELLS


def command_name(word):
    """A word's name as a command: its basename."""
    return os.path.basename(word)


def has_blank(word):
    """Whether a word holds a blank, so a reading of the command's text as written took it as
    more than one word."""
    return re.search(r"\s", word) is not None


def leads(words, starts=(0,), wrappers=True):
    """Where a command's name may stand among words, from the starts on, as a reading of where a
    command starts takes them: past options (each with or without the next word as its value,
    when that word is no option), numbers and assignments, and, with wrappers, past a wrapper or
    a shell (flock with its options and file); a word holding a blank ends the reading.
    It is a second reader of the wrappers' options beside _command, which knows
    which option takes a value and so reads one name; this one reads each name an option's value
    may hide. A wrapper or option _command learns may need reading here too."""
    reach, n = set(starts), len(words)
    for k, word in enumerate(words):
        if k not in reach:
            continue
        yield k
        if has_blank(word):
            continue
        if word.startswith("-"):
            reach.add(k + 1)
            if k + 1 < n and not words[k + 1].startswith("-") and not has_blank(words[k + 1]):
                reach.add(k + 2)
        elif NUMBER.fullmatch(word) or ASSIGNMENT.match(word):
            reach.add(k + 1)
        elif wrappers and command_name(word) == "flock":
            j = k + 1
            while j < n and words[j].startswith("-") and not has_blank(words[j]):
                j += 1
            reach.add(j + 1)
        elif wrappers and command_name(word) in RUNNERS:
            reach.add(k + 1)


def from_wrappers(command: Command):
    """Each of the command's wrappers (a shell's too) with the words after it: its own, the later
    wrappers' and the command's."""
    for t, wrapper in enumerate(command.wrappers):
        if wrapper and command_name(wrapper[0]) in RUNNERS:
            yield wrapper + tuple(word for words in command.wrappers[t + 1 :] for word in words) + command.words


def heads_behind(command: Command):
    """Each way of reading the command's words from its name on, with the names of what it ran
    behind: the walk's own words behind every wrapper's name, and from each word after a wrapper
    that may be the name of what it runs, where the walk took it as an option's value, behind the
    wrappers before that one and each wrapper or shell named before that word; a word holding a
    blank, or an option, is never a name."""
    names = tuple(command_name(wrapper[0]) for wrapper in command.wrappers if wrapper)
    yield command.words, names
    for t, wrapper in enumerate(command.wrappers):
        if not wrapper or command_name(wrapper[0]) not in RUNNERS:
            continue
        words = wrapper + tuple(word for later in command.wrappers[t + 1 :] for word in later) + command.words
        outer = tuple(command_name(before[0]) for before in command.wrappers[:t] if before)
        for k in leads(words):
            if k and not words[k].startswith("-") and not has_blank(words[k]):
                ran = tuple(command_name(word) for word in words[:k] if command_name(word) in RUNNERS)
                yield words[k:], outer + ran


def heads(command: Command):
    """Each way of reading the command's words from its name on, as heads_behind reads them."""
    for words, _ in heads_behind(command):
        yield words


def main():
    if sys.argv[1:] == ["--commands"]:
        try:
            for command in commands(sys.stdin.read()):
                fields = {"reached": command.reached, "assignments": command.assignments}
                fields.update(wrappers=command.wrappers, words=command.words)
                line = json.dumps(fields, ensure_ascii=False, separators=(",", ":"))
                sys.stdout.write(line + "\n")
        except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
            sys.stderr.write(f"command_text.py: {type(error).__name__}: {error}\n")
            return 1
        return 0
    if sys.argv[1:]:
        sys.stderr.write("usage: python3 -I command_text.py [--commands]   (the command on stdin)\n")
        return 2
    sys.stdout.write(code_text(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
