#!/usr/bin/env python3
"""The text of a Bash command that runs as code, for a guard that reads where a command starts.

Usage: python3 -I command_text.py   (the command on stdin; prints the text on stdout)

bin/hooks/command-guard runs this file on a Bash call's command, team-tokens imports
without_heredocs from it, and outbound.py simple_commands, each simple command's words. It reads the command far enough to know its quotes ('...', "..." and
$'...'), backslashes, comments, arithmetic ($[, and $(( or (( whose two closing parentheses are
adjacent, matched as Bash's parse_matched_pair does, past quotes, backticks and a $(...) read
by this scan: ((cmd) ) is two subshells), groups ((, $(, a backtick, ${ in which quotes
nest up to its first }, [[ ... ]], in which a comment and a newline's heredoc bodies are read as
outside it, a { ... }, and after = an array assignment's list, a word's part in which no word is
reserved), case's patterns, pipelines, here-strings and heredocs, whose marker is its word up to
a blank or an operator with its quotes removed, as Bash takes it; a << inside quotes, a comment,
arithmetic, ${ or [[ opens none.
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
"""

import functools
import re
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
LEADING = frozenset(("!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "coproc"))


def _closed(text, i, j, end):
    """Whether the quote opened at i and read to j, just past what closes it, closes before end."""
    return i + 1 < j <= end and text[j - 1] == text[i]


def _command_word(text, i, end):
    """The word at i, before end, as a command's argument, and where it ends: its quotes removed,
    as _word reads them, but for a quote's text holding $ or a backtick and a substitution, $(...),
    `...`, ${...}, $((...)) or $[...], which are kept as written, so a word built by one still holds
    its $ or backtick; a quote that does not close before end is dropped, its text read as unquoted."""
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
            j = _pair_end(text, i + 1 + ansi, "'" if ansi else c, "'" if ansi else c, "esc" if ansi else "")
            if not _closed(text, i + ansi, j, end):
                i += 1 + ansi
                continue
            inner = text[i + 1 + ansi : j - 1]
            if c == '"' and not ("$" in inner or "`" in inner):
                inner = re.sub(r"\\([\\\"$`])", r"\1", inner).replace("\\\n", "")
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
    starts with left out. A word holding a substitution keeps its text, $ or backtick and all; one
    whose quote never closes keeps its text, unquoted. A segment holding a compound command yields
    its words too, split at its separators, beside the group's own commands."""
    reading = read_command(command)
    bodies = {h.body[0]: h.end for h in reading.heredocs}
    found = [words for _, segments in reading.pipelines for start, end in segments for words in _segment_commands(command, start, end, bodies)]
    yield from found


if __name__ == "__main__":
    sys.stdout.write(code_text(sys.stdin.read()))
