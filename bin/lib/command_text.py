#!/usr/bin/env python3
"""The text of a Bash command that runs as code, for a guard that reads where a command starts.

Usage: python3 -I command_text.py   (the command on stdin; prints the text on stdout)

team-tokens imports HEREDOC from here, and bin/hooks/command-guard runs this file on a Bash call's
command. The text it prints is the command with:
  - each heredoc's body left out, from its marker through its closing line, the rest of the
    marker's line kept, the bodies of a line's heredocs one after another; a << inside quotes, a
    comment or (( )) opens none, and the marker is its whole word, as Bash takes it. A body is
    kept whole, as code, when its marker's line names a shell (bash, sh, zsh, dash, ksh, source
    or .), which may read it as its script; else a body under an unquoted marker keeps, each on
    a line of its own, the text of each of its lines from its first command substitution ($( or
    a backtick) on, since Bash runs those. A heredoc with no closing line is left as it is, all
    of it read as code;
  - the string after a shell's -c (bash, sh, zsh, dash or ksh, by any path), su's, script's and
    flock's -c, eval, env's -S or --split-string and find's -exec, -execdir, -ok and -okdir, to
    the end of its line, added on a line of its own with a leading -- and its opening quotes
    dropped, and so for each such string inside another (its later lines already start lines);
  - on a line that names a shell, the string after each here-string's <<<, and, when the line
    has a pipe, the text of each quoted string and each piped command's words after its first,
    quotes dropped, each added on a line of its own, since the shell may read them as its script.
It reads no quoting beyond that: a guard matching the text sees a separator inside quotes as one,
which refuses more, never less.
"""

import re
import sys

# A heredoc's marker: <<, or <<- , and its word, quoted or not (group 1 the quote, 2 the word).
MARKER = r"(?<!<)<<(?!<)-?[ \t]*(['\"]?)([^\s'\";&|<>()]+)\1"
# A heredoc, from its marker through its closing line, the rest of the marker's line kept; a
# here-string (<<<) is none. Group 3 is the rest of the marker's line.
HEREDOC = re.compile(MARKER + r"([^\n]*)\n(?:.*?\n)??[ \t]*\2[ \t]*(?=\n|$)", re.S)
MARKERS = re.compile(MARKER)

# Where a heredoc body's line starts a command substitution.
SUBSTITUTION = re.compile(r"\$\(|`")
# A word naming a shell that may read its script from stdin.
SHELL = re.compile(r"(?<![\w.-])(?:(?:ba|z|da|k)?sh|source)(?![\w.-])|(?:^|(?<=[\s;&|(]))\.(?=[ \t])")

# A string the shell runs as a command: what follows a shell's -c, eval, env's -S or find's -exec.
RUNS_STRING = re.compile(
    r"(?<![\w.-])(?:(?:(?:ba|z|da|k)?sh|su|script|flock)(?:[ \t]+[^\s;&|]+)*?[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+"
    r"|eval[ \t]+|env(?:[ \t]+[^\s;&|]+)*?[ \t]+(?:-[A-Za-z]*S[ \t]*|--split-string(?:=|[ \t]+))"
    r"|-(?:exec|execdir|ok|okdir)[ \t]+)"
)
OPENING = re.compile(r"^(?:--[ \t]+)?(?:\$?['\"])*")
HERE_STRING = re.compile(r"<<<[ \t]*")
QUOTED = re.compile(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"")


def _line_of(text, i):
    start = text.rfind("\n", 0, i) + 1
    end = text.find("\n", i)
    return text[start : len(text) if end < 0 else end]


def _body_code(body, quoted, fed):
    """What of a heredoc's body runs as code: all of it fed to a shell, else its substitutions."""
    if fed:
        return body.split("\n")
    if quoted:
        return []
    kept = []
    for line in body.split("\n"):
        found = SUBSTITUTION.search(line)
        if found:
            kept.append(line[found.start() :])
    return kept


def _closing(text, pos, word):
    """The end of the body starting at pos that closes on a line of word, or None."""
    found = re.compile(r"(?:.*?\n)??[ \t]*" + re.escape(word) + r"[ \t]*(?=\n|$)", re.S).match(text, pos)
    return found.end() if found else None


def drop_heredocs(text):
    """The text with each heredoc's body left out but what runs as code, as the header says."""
    out, start, i, quote, arith = [], 0, 0, None, 0
    while i < len(text):
        c = text[i]
        if quote == "'":
            quote = None if c == "'" else quote
        elif quote == '"':
            if c == "\\":
                i += 2
                continue
            quote = None if c == '"' else quote
        elif c == "\\":
            i += 2
            continue
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        elif text.startswith("((", i):
            arith, i = arith + 1, i + 2
            continue
        elif text.startswith("))", i) and arith:
            arith, i = arith - 1, i + 2
            continue
        elif text.startswith("<<<", i):
            i += 3
            continue
        elif text.startswith("<<", i) and not arith:
            match = HEREDOC.match(text, i)
            if match:
                fed = bool(SHELL.search(_line_of(text, i)))
                first = match.group(0)
                code = _body_code(first[first.index("\n") + 1 : first.rfind("\n") + 1], match.group(1), fed)
                end, rest = match.end(), match.group(3)
                # The line's later heredocs, each body after the one before's closing line.
                for marker in MARKERS.finditer(rest):
                    if end >= len(text) or text[end] != "\n":
                        break
                    close = _closing(text, end + 1, marker.group(2))
                    if close is None:
                        break
                    body = text[end + 1 : close]
                    code += _body_code(body[: body.rfind("\n") + 1], marker.group(1), fed)
                    end = close
                out.append(text[start:i])
                out.append("\n".join([rest] + code))
                start = i = end
                continue
        i += 1
    out.append(text[start:])
    return "".join(out)


def _fed_lines(text):
    """The strings a line naming a shell may feed it on stdin, as the header says."""
    added = []
    for line in text.split("\n"):
        if not SHELL.search(line):
            continue
        added += [OPENING.sub("", line[m.end() :]) for m in HERE_STRING.finditer(line)]
        if "|" in line:
            added += [single or double for single, double in QUOTED.findall(line)]
            for part in line.split("|")[:-1]:
                words = part.split(None, 1)
                if len(words) == 2:
                    added.append(words[1].replace("'", "").replace('"', ""))
    return added


def code_text(command):
    """The command's text as code: heredoc bodies out, run strings added, as the header says."""
    text = drop_heredocs(command)
    # One pass finds a string inside another too, since a quote before a shell or eval is no
    # word character: bash -c "bash -c 'x'" adds both strings. Each is added to its line's end
    # only: its later lines already start lines of the text.
    added = [OPENING.sub("", text[match.end() :].split("\n", 1)[0]) for match in RUNS_STRING.finditer(text)]
    added += _fed_lines(text)
    return "\n".join([text] + [inner for inner in added if inner])


if __name__ == "__main__":
    sys.stdout.write(code_text(sys.stdin.read()))
