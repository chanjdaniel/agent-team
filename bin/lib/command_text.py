#!/usr/bin/env python3
"""The text of a Bash command that runs as code, for a guard that reads where a command starts.

Usage: python3 -I command_text.py              (the command on stdin; prints the text on stdout)
       python3 -I command_text.py --commands   (the command on stdin; prints its walk, below)

bin/lib/command_rules.py, the rule table bin/hooks/command-guard runs, imports code_text,
read_command and commands, the walk of each simple command, from it; outbound.py imports commands
and team-tokens without_heredocs. It reads
the command far enough to know its quotes ('...', "..." and $'...'), backslashes, comments,
arithmetic ($[, and $(( or (( whose two closing parentheses are adjacent, matched as Bash's
parse_matched_pair does, past quotes, backticks and a $(...) read by this scan: ((cmd) ) is two
subshells), groups ((, $(, a backtick, ${ in which quotes nest up to its first }, [[ ... ]], in
which a comment and a newline's heredoc bodies are read as outside it, a { ... }, and after = an
array assignment's list, a word's part in which no word is reserved), case's patterns,
pipelines, here-strings and heredocs, whose marker is its word up to a blank or an operator with
its quotes removed, as Bash takes it; a << inside quotes, a comment, arithmetic, ${ or [[ opens
none.
A reserved word ({, }, case, esac, [[ and the rest) is one where Bash takes it as one, as its
reserved_word_acceptable does: after a separator, a pipe, (, ), {, }, an opening reserved word,
a compound command's end (fi, done, esac, }, ), (( ... )) or ]]), time, its -p or the -- after
either, coproc, or coproc's or function's name; after any other word it is a word.
The text it prints is the command with:
  - each heredoc's body left out, through its closing line, its marker's line kept. A body is kept
    whole, as code, when a shell may read it as its script: the heredoc is a shell's own, or its
    command, or a group it is in, is piped into a shell. Else a body under an unquoted marker
    keeps, each on a line of its own, the text of each of its lines from its first command
    substitution ($( or a backtick) on, since Bash runs those. A heredoc with no closing line is
    left as it is, all of it read as code;
  - the string after a shell's -c (bash, sh, zsh, dash or ksh, by any path), su's, script's and
    flock's -c, eval, env's -S or --split-string and find's -exec, -execdir, -ok and -okdir, to
    the end of its line, added on a line of its own with a leading -- and its opening quotes
    dropped, and so for each such string inside another (its later lines already start lines);
  - a shell's here-string, or one in a command piped into a shell, its quotes removed; and for
    each command piped into a shell, the text of each of its quoted strings and of each of its
    simple commands' words after the first, quotes dropped; each added on a line of its own.
A shell here is bash, sh, zsh, dash, ksh, source or . where a pipeline's command starts, past
reserved words, assignments and the wrappers env, nohup, command, exec, time, nice, ionice,
stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch and flock with its file, each word
read with its quotes removed (a backslash in $'...' quoting the next character, as in \\', so an
escape such as \\x62 is not decoded); or a command a group or substitution in which starts one, as
(bash) or tee >(bash) does; so a shell or . named as an argument feeds it nothing.
It reads no quoting beyond that: a guard matching the text sees a separator inside quotes as one,
which refuses more, never less.

commands(text), which --commands prints as one JSON line each, yields a Command for each simple
command the text runs (simple_commands: those in a group, a substitution, a pipeline or a list
too): the assignments before its name, env's among them; its words from the name of what runs on,
past the wrappers env, command, exec, nohup, time, nice, ionice, stdbuf, timeout, setsid, sudo,
doas, xargs, parallel, watch and flock with their options, numbers and flock's file, parallel's
inputs after its ::: or :::: left out but for those with a scheme (https://host/u), read as URLs;
the wrappers it ran behind, each its own words, the outermost first, with the command that ran
its string, its find, or the shell or source that ran its file; and how it was reached: directly,
in a string a tool runs, by find -exec, in a string watch or parallel join, as a shell's script
file or by source.
A command string is walked in turn, its commands yielded after the command that runs it, where
the tool itself takes one: what watch and parallel join of their command's words (from the first
word that is no option, and the next too when an option may take that one), env's -S or
--split-string value with the words after it, and flock's -c or --command value, each after the
assignments before it, quoted; a shell's -c string (bash, sh, zsh, dash or ksh), su's -c, -C,
--command or --session-command, script's -c or --command and eval's words; and each command
find's -exec, -execdir, -ok or -okdir runs is walked as a simple command of its own.
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
arguments (nsenter, chroot, unshare, systemd-run, tmux send-keys).
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
# The reserved words a command may follow where it starts.
RESERVED = r"(?:!|\{|if|then|else|elif|do|while|until|time|coproc)"
# A shell that may read its script from stdin, where a pipeline's command starts, in a segment's
# text with its words' quotes removed (_dequoted).
SHELL_START = re.compile(
    rf"\s*(?:{RESERVED}[ \t]+)*(?:[A-Za-z_]\w*=\S*[ \t]+)*"
    r"(?:(?:(?:env|nohup|command|exec|time|nice|ionice|stdbuf|timeout|setsid|sudo|doas|xargs|parallel|watch)"
    r"(?:[ \t]+(?:-[^\s;&|]*(?:[ \t]+[^-\s;&|][^\s;&|]*)?|[0-9][0-9.]*[smhd]?|[A-Za-z_]\w*=\S*))*"
    r"|flock(?:[ \t]+-[^\s;&|]*)*[ \t]+[^-\s;&|][^\s;&|]*)[ \t]+)*"
    r"(?:(?:[^\s;&|]*/)?(?:(?:ba|z|da|k)?sh|source)(?=[\s;&|()<>]|$)|\.(?=[ \t]))"
)
# A word, from where it starts to a metacharacter.
WORD = re.compile(r"[^\s;&|()<>]+")
# The reserved words after which another may come, each with the state it leaves: function's and
# coproc's name lets one follow, as do time's -p and the -- after either (Bash's
# reserved_word_acceptable).
OPENS = {word: True for word in ("!", "if", "then", "else", "elif", "do", "while", "until", "fi", "done")}
OPENS.update(function="name", coproc="coproc", time="time")
# Where a heredoc body's line starts a command substitution.
SUBSTITUTION = re.compile(r"\$\(|`")
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
    and where its reading ended: past the ) that closes a group's reading, else the text's end."""

    pipelines: list
    heredocs: list
    strings: list
    end: int


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


def _dequoted(text, start, end):
    """The text from start to end with each word's quotes removed, as _word reads it; from a quote
    that never closes on, the text as written."""
    out, i = [], start
    while i < end:
        if text[i] in METACHARACTERS:
            out.append(text[i])
            i += 1
            continue
        word, _, after = _word(text, i)
        if word is None or after > end:
            out.append(text[i:end])
            break
        out.append(word)
        i = after
    return "".join(out)


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
    # Each group open at i: its kind (root, (, `, {, ${, [[, an array assignment's list, or a
    # case's case-word, case-pattern or case-body), its pipeline, where its segment starts,
    # whether a pipe began that segment, the quote it sits in, whether a reserved word may come
    # next (True, False, or "name", "coproc", "time" or "time -p" after function, coproc, time or
    # time's -p), and that state for its parent once it ends: a compound command's end lets one
    # come, a word's part does not.
    frames = []
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
            frames[-1][5] = frame[6]
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
        as function's or coproc's name."""
        if at == 0 or text[at - 1] in METACHARACTERS:
            frames[-1][5] = frames[-1][5] in ("name", "coproc")

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
                i = arith
            elif text.startswith("$(", i) or text.startswith("${", i) or c == "`":
                push("`" if c == "`" else "(" if text[i + 1] == "(" else "${", i + 1 + (c == "$"), '"')
                quote, i = None, i + 1 + (c == "$")
            else:
                quote, i = None if c == '"' else quote, i + 1
            continue
        if c in "'\"" or text.startswith("$'", i):
            word_at(i)
            quote, i = "$'" if c == "$" else c, i + 1 + (c == "$")
        elif text.startswith("$((", i) and (arith := _arith_end(text, i + 1)) or text.startswith("$[", i):
            word_at(i)
            i = arith if text[i + 1] == "(" else _pair_end(text, i + 2, "[", "]")
        elif kind not in ("${", "[[") and text.startswith("((", i) and (arith := _arith_end(text, i)):
            # An arithmetic command, a compound one.
            i = arith
            frames[-1][5] = True
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
            # A subshell, a function's () or body, or a word's part: a process substitution or an
            # array assignment's list.
            substitution = text[i - 1 : i] in ("<", ">", "=")
            if substitution:
                frames[-1][5] = False
            push("array" if text[i - 1 : i] == "=" else "(", i + 1, ends=not substitution)
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
            elif word in OPENS and reserved():
                frames[-1][5] = OPENS[word]
            elif word == "-p" and frames[-1][5] == "time":
                frames[-1][5] = "time -p"
            elif word == "--" and frames[-1][5] in ("time", "time -p"):
                frames[-1][5] = True
            else:
                if word:
                    word_at(i)
                word = None
            i += len(word) if word else 1
    end = n if frames else i
    while frames:
        pop(n)
    return Reading(pipelines, heredocs, strings, end)


def without_heredocs(command):
    """The command with each closed heredoc's marker and body left out, the rest of its marker's
    line kept."""
    reading = read_command(command)
    out, start = [], 0
    for begin, end in sorted([h.marker for h in reading.heredocs] + [(h.body[0] - 1, h.end) for h in reading.heredocs]):
        out.append(command[start:begin])
        start = end
    return "".join(out) + command[start:]


def _fed(reading, shells, pipeline, segment):
    """Whether a shell may read what the segment's command writes or reads as its script."""
    while not any(shells[pipeline][segment:]):
        if reading.pipelines[pipeline][0] is None:
            return False
        pipeline, segment = reading.pipelines[pipeline][0]
    return True


def code_text(command):
    """The command's text as code: heredoc bodies out, run strings and fed text added, as the
    header says."""
    reading = read_command(command)
    shells = [[bool(SHELL_START.match(_dequoted(command, s, e))) for s, e in segments] for _, segments in reading.pipelines]
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
            code = [line[found.start() :] for line in lines if (found := SUBSTITUTION.search(line))]
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
    return "\n".join([text] + [inner for inner in added if inner])


# A redirection operator where a word would start, with the fd or {name} before it.
REDIRECT = re.compile(r"(?:[0-9]+|\{[A-Za-z_]\w*\})?(?:&>>?|<<<|<<-?|<>|[<>]&|>\||>>|[<>])")
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
    undone all the same, an escaped $ or backtick kept); a quote that does not close before end
    ends the word, and the segment with it (end is where it returns): code_text adds a -c string's
    line with its closing quote left on, and what follows that quote is the outer command's, never
    the string's."""
    out = []
    while i < end:
        c = text[i]
        if c in METACHARACTERS:
            if c != "(" or not out or text[i - 1] != "=":
                break
            # An array assignment's list.
            j = _group_end(text, i + 1)
        elif c == "\\":
            out.append(text[i + 1 : i + 2].replace("\n", ""))
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
        elif c in "'\"" or text.startswith("$'", i):
            ansi = c == "$"
            mark = "'" if ansi else c
            j = _pair_end(text, i + 1 + ansi, mark, mark, "esc" if ansi else "")
            if not _closed(text, i + ansi, j, end):
                return "".join(out), end
            inner = text[i + 1 + ansi : j - 1]
            if c == '"':
                # One holding $ or a backtick keeps its escaped ones, so it still holds one.
                escaped = r"\\([\\\"])" if "$" in inner or "`" in inner else r"\\([\\\"$`])"
                inner = re.sub(escaped, r"\1", inner).replace("\\\n", "")
            out.append(inner)
            i = j
            continue
        else:
            out.append(c)
            i += 1
            continue
        out.append(text[i : min(j, end)])
        i = j
    return "".join(out), i


def _segment_commands(text, start, end, bodies):
    """The simple commands of the segment from start to end, each its words, as simple_commands
    says; bodies maps where each heredoc body starts to where its closing line ends."""
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
                i = _command_word(text, i, end)[1]
        elif c == "(":
            # A subshell or an arithmetic command, whose commands are a group of their own.
            arith = _arith_end(text, i) if text.startswith("((", i) else None
            i = arith or _group_end(text, i + 1)
        elif c in METACHARACTERS:
            # A separator in a compound command, whose commands are its own pipelines too, or in a
            # quote read_command found open.
            close()
            i += 1
        else:
            word, i = _command_word(text, i, end)
            words.append(word)
    close()
    return commands


def simple_commands(command):
    """Each simple command of every pipeline segment of the command, those in its groups and
    substitutions too, as the list of its words with their quotes removed (_command_word): its
    redirections, their targets, its comments, its heredocs' bodies and the reserved words it
    starts with left out. A word holding a substitution keeps its text, $ or backtick and all; a
    quote that never closes ends its word and the rest of its segment. A segment holding a compound
    command yields its words too, split at its separators, beside the group's own commands."""
    reading = read_command(command)
    bodies = {h.body[0]: h.end for h in reading.heredocs}
    for _, segments in reading.pipelines:
        for start, end in segments:
            yield from _segment_commands(command, start, end, bodies)


# An assignment, as a command's word.
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*\+?=")
# A wrapper's number, its value with no option before it (timeout 10s).
NUMBER = re.compile(r"[0-9][0-9.]*[smhd]?")
# The commands that run the command after them, past their options.
WRAPPERS = frozenset(
    "env command exec nohup time nice ionice stdbuf timeout setsid sudo doas xargs parallel watch"
    " flock".split()
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

def _long_options(name, options):
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
        named = _long_options(name, options)
        return (value if eq else "") if len(named) == 1 and named <= longs else None
    if word.startswith("-") and word != "-":
        _, flag, joined = _short(word, values)
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
            elif word.startswith("-") and word != "-":
                option = True
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



def _short(word, value_flags):
    """A cluster of short options read as getopt reads it: its flags up to the first that takes a
    value, that flag or None, and the value joined to it ("" when it is the next word)."""
    for k, flag in enumerate(word[1:], 1):
        if flag in value_flags:
            return word[1:k], flag, word[k + 1 :]
    return word[1:], None, ""

# How a Command was reached: directly, as a simple command of the text; in a string a tool runs (a
# shell's -c, eval, su's and script's -c, env -S, flock -c); by find's -exec; in what watch or
# parallel join; as a shell's script file; or by source or `.`.
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


def _commands(text, depth, outer, reached):
    if depth > DEPTH:
        raise ValueError(f"a command string nested deeper than {DEPTH}")
    for words in simple_commands(text):
        yield from _walk(words, text, depth, outer, reached)


def commands(text):
    """Each Command the text runs, as the header says: each simple command (simple_commands), then
    the commands of each string, find -exec, script file or sourced file it runs, in turn."""
    return _commands(text, 0, (), DIRECT)


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
