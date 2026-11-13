"""command-guard's kill rows: a kill that reaches what is not the session's own.

bin/lib/command_rules.py appends ROWS to its table after the upload row, before the delete rows
(bin/lib/delete_rules.py). Each row's test takes one command_text.Command and the call's context,
and returns its reason when it refuses, else None; each names its allowed way, which command-guard
puts in the refusal. A command's name is its first word's basename, its quotes removed, read
past its wrappers as command_text.heads_behind reads it, so a path, a quoted name, sudo, env,
nohup, xargs -r and the rest are no way around a row; builtin kill and command kill are kill.
The rows, in order:
  kill-by-name: a command named pkill, killall, killall5 or skill, or fuser with k in a short
    option cluster or --kill.
  tmux-kill: tmux with a word starting kill- (kill-server, kill-session, kill-window, kill-pane),
    or killp or killw, their aliases, with or without -L or -S.
  kill-from-input: kill behind xargs or parallel, or run by find's -exec, -execdir, -ok or
    -okdir, a string they run included.
  kill-unread-pid: kill with a PID word that is not a literal: digits, or the session's own job
    (a job spec, % and anything; $!, ${!}, $$, $(jobs -p) or `jobs -p`; or a variable, $P or
    ${P}, whose every mention in the command's text, the first among them, is an assignment from
    $! or ${!}).
  kill-group: kill with a PID word 0, 1, -1 or -<digits>, a process group, every process or PID 0
    or 1; a kill with no PID word whose signal is given as -<digits> (kill -1) is read as naming
    that word as its PID, since it sends nothing to anything else.
kill's words are read as Bash's builtin reads them: -l and -L list, and pass; -s <signal>, -n
<number>, -s<name>, -n<digits> and one -<signal> set the signal; -- ends the options; after the
signal, a word starting with - is a PID. A signal of 0 (-0, -s 0, -n 0) only checks, and passes
for any PID. A literal PID above 1 passes here.
"""

import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import command_name, heads_behind  # noqa: E402

BY_NAME = frozenset(("pkill", "killall", "killall5", "skill"))
# What runs a kill on PIDs read from its input.
FEEDERS = {"xargs": "xargs kill", "parallel": "parallel kill", "find": "find -exec kill"}
# The session's own jobs, as a PID word with its quotes removed.
OWN = re.compile(r"%.*|\$!|\$\{!\}|\$\$|\$\(\s*jobs\s+-p\s*\)|`\s*jobs\s+-p\s*`", re.DOTALL)
# An assignment's = and value, $! or ${!}, alone or double-quoted, to the end of its word.
FROM_JOB = re.compile(r'''=("?)(?:\$!|\$\{!\})\1(?=$|[\s;&|)`])''')
# A variable as a whole PID word.
VARIABLE = re.compile(r"\$([A-Za-z_]\w*)|\$\{([A-Za-z_]\w*)\}")
DIGITS = re.compile(r"[0-9]+")
GROUP = re.compile(r"-[0-9]+")

ALLOWED_KILL = (
    "find your own process's PID (pgrep -af <pattern>, or the $! you noted when you started it) and kill that"
    " literal PID in a call of its own, which passes when the process is yours and its working directory is"
    " inside your worktree or your job's tmp"
)
ALLOWED_READ = (
    "read the PID first (pgrep -af, ps -o pid,args), then kill that literal PID in a call of its own; your own"
    " jobs ($!, %1, $(jobs -p)) pass as they are"
)


def _named(command, names):
    """Each reading of the command whose name is one of names: its words and what it ran behind."""
    for words, behind in heads_behind(command):
        if words and command_name(words[0]) in names:
            yield list(words), behind


def _kill_words(args):
    """kill's words after its name read as Bash's builtin reads them: whether it lists, its signal
    (None when none is given, "0" for a signal of 0), and its PID words."""
    signal, given, k = None, None, 0
    while k < len(args):
        word = args[k]
        if word in ("-l", "-L"):
            return True, signal, []
        if word in ("-s", "-n"):
            if k + 1 >= len(args):
                return False, signal, []
            signal, given, k = args[k + 1], None, k + 2
            continue
        if re.fullmatch(r"-s[A-Za-z].*|-n[0-9].*", word):
            signal, given, k = word[2:], None, k + 1
            continue
        if word == "--":
            k += 1
            break
        if word.startswith("-") and len(word) > 1 and signal is None:
            signal, given, k = word[1:], word, k + 1
            continue
        break
    pids = args[k:]
    if not pids and given is not None and DIGITS.fullmatch(given[1:]):
        # kill -1 sends nothing as a signal with no PID; read it as the PID it names.
        return False, None, [given]
    return False, signal, pids


def _kill_pids(command):
    """Each reading of a kill command that sends a signal other than 0: its PID words and what it
    ran behind."""
    for words, behind in _named(command, {"kill"}):
        lists, signal, pids = _kill_words(words[1:])
        if not lists and signal != "0":
            yield pids, behind


def _by_name(command, context):
    reason = "a kill by name or pattern ({}), which reaches every task's processes and the team's own sessions"
    for words, _ in _named(command, BY_NAME | {"fuser"}):
        name = command_name(words[0])
        if name in BY_NAME:
            return reason.format(name)
        if any(word == "--kill" or (re.fullmatch(r"-[^-].*", word) and "k" in word) for word in words[1:]):
            return reason.format("fuser -k")
    return None


def _tmux(command, context):
    for words, _ in _named(command, {"tmux"}):
        for word in words[1:]:
            if word.startswith("kill-") or word in ("killp", "killw"):
                return f"tmux {word}, which reaches other sessions' terminals and the team's own"
    return None


def _from_input(command, context):
    for _, behind in _kill_pids(command):
        for name in reversed(behind):
            if name in FEEDERS:
                return (
                    f"a kill of PIDs read from input ({FEEDERS[name]}), which the guard cannot read before it runs"
                )
    return None


def _set_from_job(variable, text):
    """Whether the variable is set from $! or ${!} wherever the command's text names it: its first
    mention an assignment from one of them, and each later one too, or a use ($P, ${P}, ${P:-x}),
    never an assignment of another kind (P+=x, read P, for P in, ${P:=x})."""
    first = True
    for mention in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(variable) + r"(?![A-Za-z0-9_])", text):
        start, end = mention.span()
        used = text.endswith("$", 0, start) or (text.endswith("${", 0, start) and not re.match(r":?=", text[end:]))
        if used and first:
            return False
        if not used and not FROM_JOB.match(text, end):
            return False
        first = False
    return not first


def _unread(command, context):
    for pids, _ in _kill_pids(command):
        for pid in pids:
            if DIGITS.fullmatch(pid) or GROUP.fullmatch(pid) or OWN.fullmatch(pid):
                continue
            variable = VARIABLE.fullmatch(pid)
            if variable and _set_from_job(variable.group(1) or variable.group(2), context.text):
                continue
            return f"a kill of {pid}, a PID the guard cannot read before it runs (a variable or a substitution)"
    return None


def _group(command, context):
    for pids, _ in _kill_pids(command):
        for pid in pids:
            if pid in ("0", "1") or GROUP.fullmatch(pid):
                return f"a kill of {pid}, a process group, every process or PID 0 or 1"
    return None


# The rows, in order: each its id, its test and its allowed way.
ROWS = (
    ("kill-by-name", _by_name, ALLOWED_KILL),
    ("tmux-kill", _tmux, ALLOWED_KILL),
    ("kill-from-input", _from_input, ALLOWED_READ),
    ("kill-unread-pid", _unread, ALLOWED_READ),
    ("kill-group", _group, ALLOWED_KILL),
)
