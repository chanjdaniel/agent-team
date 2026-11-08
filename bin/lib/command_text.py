#!/usr/bin/env python3
"""The text of a Bash command that runs as code, for a guard that reads where a command starts.

Usage: python3 -I command_text.py   (the command on stdin; prints the text on stdout)

team-tokens imports HEREDOC from here, and bin/hooks/command-guard runs this file on a Bash call's
command. The text it prints is the command with:
  - each heredoc's body left out, from its marker through its closing line, the rest of the
    marker's line kept; a body under an unquoted marker keeps, each on a line of its own, the text
    of each of its lines from its first command substitution ($( or a backtick) on, since Bash
    runs those; a heredoc with no closing line is left as it is, all of it read as code;
  - the string after a shell's -c (bash, sh, zsh, dash or ksh, by any path, past its other
    options), after eval and after env's -S or --split-string, to the end of its line, added on
    a line of its own with its opening quotes dropped, and so for each such string inside
    another, since the shell runs it as a command (its later lines already start lines).
It reads no quoting beyond that: a guard matching the text sees a separator inside quotes as one,
which refuses more, never less.
"""

import re
import sys

# A heredoc, from its marker through its closing line, the rest of the marker's line kept; a
# here-string (<<<) is none. Group 1 is the marker's quote, 2 the marker, 3 the rest of its line.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1([^\n]*)\n(?:.*?\n)??[ \t]*\2[ \t]*(?=\n|$)", re.S)

# Where a heredoc body's line starts a command substitution.
SUBSTITUTION = re.compile(r"\$\(|`")

# A string the shell runs as a command: what follows a shell's -c, eval, or env's -S.
RUNS_STRING = re.compile(
    r"(?<![\w.-])(?:(?:ba|z|da|k)?sh(?:[ \t]+-[^\s;&|]*)*?[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+"
    r"|eval[ \t]+|env(?:[ \t]+[^\s;&|]+)*?[ \t]+(?:-[A-Za-z]*S[ \t]*|--split-string(?:=|[ \t]+)))"
)
OPENING_QUOTES = re.compile(r"^(?:\$?['\"])+")


def _drop_body(match):
    whole, rest = match.group(0), match.group(3)
    if match.group(1):
        return rest
    after = whole[whole.index("\n") + 1 :]
    body = after[: after.rfind("\n") + 1]
    kept = []
    for line in body.split("\n"):
        found = SUBSTITUTION.search(line)
        if found:
            kept.append(line[found.start() :])
    return "\n".join([rest] + kept)


def code_text(command):
    """The command's text as code: heredoc bodies out, run strings added, as the header says."""
    text = HEREDOC.sub(_drop_body, command)
    # One pass finds a string inside another too, since a quote before a shell or eval is no
    # word character: bash -c "bash -c 'x'" adds both strings. Each is added to its line's end
    # only: its later lines already start lines of the text.
    added = [
        OPENING_QUOTES.sub("", text[match.end() :].split("\n", 1)[0]) for match in RUNS_STRING.finditer(text)
    ]
    return "\n".join([text] + [inner for inner in added if inner])


if __name__ == "__main__":
    sys.stdout.write(code_text(sys.stdin.read()))
