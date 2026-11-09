#!/usr/bin/env python3
"""The text of a Bash command that runs as code, for a guard that reads where a command starts.

Usage: python3 -I command_text.py   (the command on stdin; prints the text on stdout)

bin/hooks/command-guard runs this file on a Bash call's command, and team-tokens imports
without_heredocs from it. It reads the command far enough to know its quotes ('...', "..." and
$'...'), backslashes, comments, arithmetic ($((, (( and $[), groups ((, $(, a backtick, ${ in
which quotes nest up to its first }, [[ ... ]] and a { ... }), case's patterns, pipelines,
here-strings and heredocs, whose marker is its word up to a blank or an operator with its quotes
removed, as Bash takes it; a << inside quotes, a comment, arithmetic, ${ or [[ opens none.
A reserved word ({, }, case, esac, [[ and the rest) is one where Bash takes it as one, as its
reserved_word_acceptable does: after a separator, a pipe, (, ), {, }, an opening reserved word,
a compound command's end (fi, done, esac, }, ), (( ... )) or ]]), time or its -p, coproc, or
coproc's or function's name; after any other word it is a word.
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
# coproc's name lets one follow, as does time's -p (Bash's reserved_word_acceptable).
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
    spans), its closed heredocs, and its here-strings (each its pipeline, its segment and its word)."""

    pipelines: list
    heredocs: list
    strings: list


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


def _arith_end(text, i, pair="()"):
    """The end of the arithmetic whose (( starts at i, or with pair "[]" whose $[ does."""
    depth = 0
    for j in range(i, len(text)):
        depth += {pair[0]: 1, pair[1]: -1}.get(text[j], 0)
        if depth == 0:
            return j + 1
    return len(text)


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


def read_command(text):
    """The command's reading, as Reading says, from one pass over its text."""
    pipelines, heredocs, strings, pending = [], [], [], []
    # Each group open at i: its kind (root, (, `, {, ${, [[, or a case's case-word, case-pattern
    # or case-body), its pipeline, where its segment starts, whether a pipe began that segment,
    # the quote it sits in, whether a reserved word may come next (True, False, or after
    # function's or coproc's name or time, "name", "coproc" or "time"), and that state for its
    # parent once it ends: a compound command's end lets one come, a word's part does not.
    frames = []
    quote, i, n = None, 0, len(text)

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
        """Whether a reserved word may come here."""
        return frames[-1][5] in (True, "coproc", "time")

    def word_at(at):
        """A word that is no reserved word starts at at, or goes on there: one may follow it only
        as function's or coproc's name."""
        if at == 0 or text[at - 1] in METACHARACTERS:
            frames[-1][5] = frames[-1][5] in ("name", "coproc")

    push("root", 0)
    while i < n:
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
            if text.startswith("$((", i):
                i = _arith_end(text, i + 1)
            elif text.startswith("$(", i) or text.startswith("${", i) or c == "`":
                push("`" if c == "`" else "(" if text[i + 1] == "(" else "${", i + 1 + (c == "$"), '"')
                quote, i = None, i + 1 + (c == "$")
            else:
                quote, i = None if c == '"' else quote, i + 1
            continue
        if c in "'\"" or text.startswith("$'", i):
            word_at(i)
            quote, i = "$'" if c == "$" else c, i + 1 + (c == "$")
        elif text.startswith("$((", i) or text.startswith("$[", i):
            word_at(i)
            i = _arith_end(text, i + 1, "()" if text[i + 1] == "(" else "[]")
        elif kind not in ("${", "[[") and text.startswith("((", i):
            # An arithmetic command, a compound one.
            i = _arith_end(text, i)
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
        elif kind == "[[":
            # In [[ ... ]] nothing is an operator but its ]].
            if text.startswith("]]", i) and text[i - 1] in METACHARACTERS and text[i + 2 : i + 3] in METACHARACTERS | {""}:
                pop(i)
                i += 1
            i += 1
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif kind == "case-pattern" and c in "(|":
            # A pattern's opening parenthesis or its alternatives' bar.
            i += 1
        elif c == "(":
            # A subshell, a function's () or body, or a process substitution, a word's part.
            substitution = text[i - 1 : i] in ("<", ">")
            if substitution:
                frames[-1][5] = False
            push("(", i + 1, ends=not substitution)
            i += 1
        elif c == ")":
            if kind == "(":
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
                pos, last = i + 1, None
                for pipeline, segment, start, marker_end, word, quoted, tabs in pending:
                    found = _closing(text, pos, word, tabs) if pos <= n else None
                    if found is None:
                        break
                    heredocs.append(Heredoc(pipeline, segment, (start, marker_end), (pos, found[0]), found[1], quoted))
                    pos, last = found[1] + 1, found[1]
                pending = []
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
                frames[-1][5] = True
            else:
                if word:
                    word_at(i)
                word = None
            i += len(word) if word else 1
    while frames:
        pop(n)
    return Reading(pipelines, heredocs, strings)


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


if __name__ == "__main__":
    sys.stdout.write(code_text(sys.stdin.read()))
