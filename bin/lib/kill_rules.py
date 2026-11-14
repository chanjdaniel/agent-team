"""command-guard's kill rows: a kill that reaches what is not the session's own.

bin/lib/command_rules.py appends ROWS to its table after the upload row, before the delete rows
(bin/lib/delete_rules.py). Each row's test takes one command_text.Command and the call's context,
and returns its reason when it refuses, else None; each names its allowed way, which command-guard
puts in the refusal. A command's name is its first word's basename, its quotes removed, its
$'...' escapes decoded and its braces expanded as the walk gives it, read past its wrappers as
command_text.heads_behind reads it, so a path, a quoted name, sudo, env, nohup, xargs -r and the
rest are no way around a row; builtin kill and command kill are kill.
The rows, in order:
  kill-by-name: a command named pkill, killall, killall5 or skill, or fuser with k in a short
    option cluster or --kill.
  tmux-kill: tmux with a word starting kill- (kill-server, kill-session, kill-window, kill-pane),
    or killp or killw, their aliases, with or without -L or -S.
  kill-from-input: kill behind xargs or parallel, or run by find's -exec, -execdir, -ok or
    -okdir, a string they run included, whatever its own signal, since what they read may add
    options (-s 9); only a listing (-l, -L) passes.
  kill-unread-pid: kill with a PID word that is not a literal: digits, or the session's own job
    (a job spec, % and anything; $!, ${!}, $$, $(jobs -p) or `jobs -p`; or a variable, $P or
    ${P}, whose first mention in the command's text is an assignment from $! or ${!}, and every
    later one another such assignment or a use, $P, ${P} or ${P:-x}).
  kill-group: kill with a PID word Bash reads as 0 or 1 (0, 1, 00, 01), -1 or -<digits>, a
    process group, every process or PID 0 or 1; a kill with no PID word whose signal is given as
    -<digits> (kill -1) is read as naming that word as its PID, since it sends nothing else.
  kill-literal-pid: kill with a literal PID above 1 that proof() does not prove the session's to
    stop.
kill's words are read as Bash's builtin reads them: -l and -L list, and pass; -s <signal>, -n
<number>, -s<name>, -n<digits> and one -<signal> set the signal; -- ends the options; after the
signal, a word starting with - is a PID. A signal of 0 (-0, -s 0, -n 0) only checks, and passes
for any PID, but behind a feeder.
A literal PID's proof, proof(pid, roots), reads the process table at the time of the call, in
order: a process that is gone (os.kill(pid, 0) finds none) passes; one os.kill may not signal, or
whose real uid (/proc/<pid>/status on Linux, ps -o ruid= on macOS) is not the user's, is another
user's; one that is the guard's own process, its parent or any ancestor, walked by parent PID
(/proc/<pid>/stat, ps -o ppid=) to PID 1, is the session's own or its shell; then its working
directory (/proc/<pid>/cwd, lsof -a -p <pid> -d cwd -Fn), resolved, passes when it is a root or
inside one (the worktree and the job tmp), and is outside otherwise. A fact it cannot read (a
permission error, no lsof, a process that ends mid-check) and a PID too large for a process id are
unproven, and refused. Its command line is never read: its working directory is the proof.
"""

import functools
import os
import re
import subprocess
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
ALLOWED_LITERAL = (
    "kill only a process you started whose working directory is inside your worktree or your job's tmp, and"
    " leave the rest to their owner"
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
    # What a feeder reads may add options, -s 9 among them, so any kill but a listing signals.
    for words, behind in _named(command, {"kill"}):
        if _kill_words(words[1:])[0]:
            continue
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
            if (DIGITS.fullmatch(pid) and int(pid) <= 1) or GROUP.fullmatch(pid):
                return f"a kill of {pid}, a process group, every process or PID 0 or 1"
    return None


# The process table's readings: /proc on Linux, ps and lsof on macOS; a test may set either.
PLATFORM = sys.platform
PROC = "/proc"
# The largest process id: a larger PID word is no process's.
MAX_PID = 2**31 - 1
# How long ps or lsof may take, in seconds.
READ_SECONDS = 5
OTHER_USER = "another user's"
OWN_SESSION = "your own session or its shell"
UNPROVEN = "its owner or working directory cannot be read, so it is not proven yours"


class Unread(Exception):
    """A fact of a process that cannot be read."""


def _ps(pid, field):
    """One numeric field of ps -o for pid, as macOS's ps reads it."""
    try:
        found = subprocess.run(
            ["ps", "-o", f"{field}=", "-p", str(pid)],
            capture_output=True, text=True, timeout=READ_SECONDS, check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise Unread from error
    value = found.stdout.strip()
    if found.returncode != 0 or not value.isdigit():
        raise Unread
    return int(value)


def _uid(pid):
    """The process's real uid."""
    if PLATFORM == "darwin":
        return _ps(pid, "ruid")
    with open(os.path.join(PROC, str(pid), "status"), encoding="utf-8") as status:
        for line in status:
            if line.startswith("Uid:"):
                return int(line.split()[1])
    raise Unread


def _parent(pid):
    """The process's parent PID."""
    if PLATFORM == "darwin":
        return _ps(pid, "ppid")
    with open(os.path.join(PROC, str(pid), "stat"), encoding="utf-8") as stat:
        # Its name, in parentheses, may hold anything: the fields after its last ) are its state,
        # then its parent PID.
        return int(stat.read().rpartition(")")[2].split()[1])


@functools.cache
def _ancestors():
    """The guard's own PID, its parent's and every ancestor's, walked by parent PID to PID 1."""
    found, pid = {os.getpid()}, os.getppid()
    while pid > 1 and pid not in found:
        found.add(pid)
        pid = _parent(pid)
    return frozenset(found)


def _cwd(pid):
    """The process's working directory, resolved."""
    if PLATFORM == "darwin":
        try:
            found = subprocess.run(
                ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                capture_output=True, text=True, timeout=READ_SECONDS, check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise Unread from error
        names = [line[1:] for line in found.stdout.splitlines() if line.startswith("n")]
        if found.returncode != 0 or len(names) != 1 or not names[0].startswith("/"):
            raise Unread
        return os.path.realpath(names[0])
    return os.path.realpath(os.readlink(os.path.join(PROC, str(pid), "cwd")))


def _inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def proof(pid, roots):
    """None when the kill of pid is the session's to send (its process gone, or the user's, not
    the session's own, working inside a root), else why not."""
    if pid > MAX_PID:
        return UNPROVEN
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return OTHER_USER
    except OSError:
        return UNPROVEN
    try:
        if _uid(pid) != os.getuid():
            return OTHER_USER
        if pid in _ancestors():
            return OWN_SESSION
        cwd = _cwd(pid)
    except (Unread, OSError, ValueError, IndexError):
        return UNPROVEN
    if any(_inside(cwd, root) for root in roots):
        return None
    return f"its working directory, {cwd}, is outside your worktree and your job's tmp"


def _literal(command, context):
    for pids, _ in _kill_pids(command):
        for pid in pids:
            if DIGITS.fullmatch(pid) and int(pid) > 1:
                why = proof(int(pid), context.roots)
                if why:
                    return f"a kill of PID {pid}, which is not yours to stop: {why}"
    return None


# The rows, in order: each its id, its test and its allowed way.
ROWS = (
    ("kill-by-name", _by_name, ALLOWED_KILL),
    ("tmux-kill", _tmux, ALLOWED_KILL),
    ("kill-from-input", _from_input, ALLOWED_READ),
    ("kill-unread-pid", _unread, ALLOWED_READ),
    ("kill-group", _group, ALLOWED_KILL),
    ("kill-literal-pid", _literal, ALLOWED_LITERAL),
)
