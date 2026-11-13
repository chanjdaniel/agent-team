#!/usr/bin/env python3
"""command-guard's rule table: whether a worker's Bash call runs a guarded thing.

Usage: python3 -I command_rules.py   (the hook's input JSON on stdin)

bin/hooks/command-guard runs this file once per Bash call it does not pass at once, and refuses
the call when it prints a line. It reads tool_input.command from the hook's input, takes its code
text as command_text.code_text prints it (each heredoc's body left out unless a shell may read it,
and the strings a shell, eval, env -S and find -exec run, and what is piped into a shell, added as
code), each heredoc that text still opens blanked so that every line of it is code, and walks
each simple command that text runs, then each one the command's own text runs (its heredocs'
bodies left out as Bash reads them, so a substitution a body leaves open in the code text hides
no line after it), as command_text.commands yields them: past the wrappers env, nohup, command,
builtin, exec, time, nice, ionice, stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch
and flock with its file, their options and env's assignments, into the substitutions in
arithmetic, and into the strings a shell's -c, eval, trap's action, su's and script's -c, env -S,
flock -c, watch and parallel, and find -exec run, a shell's script file and what source or .
reads among them, by its name.
For each row of the table in order, and each command in the walk's order, the first command a
row refuses ends the walk: it prints one JSON line, {"rule": <id>, "reason": <text>, "allowed":
<text or null>}, the reason being the text command-guard puts after "Blocked by command-guard: ",
and the allowed way null for every row here. It prints nothing when no row refuses, and exits 0
either way. Any error of its own exits 1 with one line on stderr, "command_rules.py: <ErrorType>:
<message>", or "<row id>: <ErrorType>: <message>" when a row raised, so the hook refuses: a guard
that cannot decide refuses.

A command's name is its first word's basename, its quotes removed, so a path or a quoted name is
the name; and as a reading of where a command starts took it, a word past a wrapper's options
(and flock's file) that the walk took as an option's value may be the name too, the words after
it its arguments; a word holding a blank never is.
The rows, in order:
  ops-launch: team-worker or team-load-check with ops among its words before team-worker's --, or
    a word ending in =ops (--role=ops). Reason: an ops session is the coordinator's to launch, on
    Daniel's request.
  capture-script: the frontend toolkit's capture script, a command named ui-capture, or run by
    node, deno (run), bun (run), npx, source or . past their options. Reason: it is Daniel's own
    sessions'.
  role-assigned: an assignment of AGENT_TEAM_ROLE or AGENT_TEAM_TASK (+= too), or of an element
    of either (AGENT_TEAM_ROLE[0]=x), alone, before a command or through env; either, or an
    element, named by export, declare, typeset, local, readonly, let, read, mapfile or readarray;
    or by printf -v. Reason: a worker's role and task are its settings' (bin/lib/team.sh's
    worker_refusal reads them).
  role-unset: either, or an element of either, named by unset, or either by env's -u (alone or
    ending a short cluster, its value joined or next) or --unset. The same reason.
  environment-emptied: a command named team-<anything> or claude-coordinator behind env -i (alone
    or among env's short options), env --ignore-environment (or a prefix GNU takes), env - or
    exec -c, past any wrappers between or in a string a shell runs there: it would run with no
    AGENT_TEAM_ROLE, so its own worker_refusal would not see the worker.
  lease-steal: team-lease or team-resume with --steal among its words before its --. Reason: a
    lease steal is Daniel's word, through the coordinator.
  coordinator-commands: team-ask, team-answer, team-inbox or team-run-approved with any words or
    none, or team-thread with a task id (T and digits) as its first word (team-thread wait T<n>
    passes, which each role's settings allow or deny).
  upload: a curl or wget sending a file or body to a literal host outside the team's own,
    directly or through a proxy, as bin/lib/outbound.py decides each command (its header says
    which flags and hosts); a host held in a variable is not seen.
A row reads every command the walk yields, a shell's script file and a sourced one among them (a
file named team-worker that bash runs is team-worker), but for the upload row, which reads no
file's name as curl.
Not seen: a name built by a substitution or held in a variable; a script or function of one's
own, or a copy or link of a guarded one; a string another interpreter runs (python3 -c, node -e,
perl -e, a require of the capture script); a file a shell reads on stdin (cat x | bash); what
command_text.commands does not walk (its header lists it: ssh's remote command, nsenter, chroot,
unshare, systemd-run, tmux send-keys, git rebase's --exec); each under an emptied environment
too, so a team script one of those runs there goes unseen. It is a speed bump, as a deny rule is,
which the role's rule against reaching a refused thing another way holds.
"""

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Callable

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import (  # noqa: E402
    ASSIGNMENT, NUMBER, SHELLS, WRAPPERS, Command, code_text, commands, read_command,
)
import outbound  # noqa: E402

ROLE_VARIABLES = ("AGENT_TEAM_ROLE", "AGENT_TEAM_TASK")
DECLARERS = frozenset("export declare typeset local readonly let read mapfile readarray".split())
# What runs a script by its path, with its options before it.
INTERPRETERS = frozenset(("node", "deno", "bun", "npx", "source", "."))
COORDINATOR = frozenset(("team-ask", "team-answer", "team-inbox", "team-run-approved"))
TASK_ID = re.compile(r"T[0-9]+")
# What runs the command after it, past its options, as a reading of where a command starts takes
# it: the wrappers and the shells.
RUNNERS = WRAPPERS | SHELLS
# env's -u, alone or ending a short cluster, with its value joined (-uAGENT_TEAM_ROLE) or next.
ENV_UNSET = re.compile(r"-[A-Za-z0-9]*u")
# The options that empty the environment of what a command runs, each with the form of it whose
# value is the next word: env's -i among its short options (one after it that takes a value
# with it), its --ignore-environment by a prefix, or a lone -; exec's -c among its short options.
EMPTIES = {
    "env": (
        re.compile(r"-[A-Za-z0-9]*i(?:[A-Za-z0-9]*[CuS].*|[A-Za-z0-9]*)|--ignore-e[a-z-]*|-"),
        re.compile(r"-[A-Za-z0-9]*i[A-Za-z0-9]*[CuS]"),
    ),
    "exec": (
        re.compile(r"-[A-Za-z0-9]*c(?:[A-Za-z0-9]*a.*|[A-Za-z0-9]*)"),
        re.compile(r"-[A-Za-z0-9]*c[A-Za-z0-9]*a"),
    ),
}


@dataclass(frozen=True)
class Row:
    """A rule: its id, its test over one Command and the call's context, its reason and its
    allowed way (None: the refusal names none)."""

    id: str
    test: Callable
    reason: str
    allowed: str | None = None


def _name(word):
    """A word's name as a command: its basename."""
    return os.path.basename(word)


def _blank(word):
    """Whether a word holds a blank, so a reading of the command's text as written took it as
    more than one word."""
    return re.search(r"\s", word) is not None


def _leads(words, starts=(0,), wrappers=True):
    """Where a command's name may stand among words, from the starts on, as a reading of where a
    command starts takes them: past options (each with or without the next word as its value,
    when that word is no option), numbers and assignments, and, with wrappers, past a wrapper or
    a shell (flock with its options and file); a word holding a blank ends the reading.
    It is a second reader of the wrappers' options beside command_text._command, which knows
    which option takes a value and so reads one name; this one reads each name an option's value
    may hide, as the regexes did. A wrapper or option _command learns may need reading here too."""
    reach, n = set(starts), len(words)
    for k, word in enumerate(words):
        if k not in reach:
            continue
        yield k
        if _blank(word):
            continue
        if word.startswith("-"):
            reach.add(k + 1)
            if k + 1 < n and not words[k + 1].startswith("-") and not _blank(words[k + 1]):
                reach.add(k + 2)
        elif NUMBER.fullmatch(word) or ASSIGNMENT.match(word):
            reach.add(k + 1)
        elif wrappers and _name(word) == "flock":
            j = k + 1
            while j < n and words[j].startswith("-") and not _blank(words[j]):
                j += 1
            reach.add(j + 1)
        elif wrappers and _name(word) in RUNNERS:
            reach.add(k + 1)


def _from_wrappers(command: Command):
    """Each of the command's wrappers (a shell's too) with the words after it: its own, the later
    wrappers' and the command's."""
    for t, wrapper in enumerate(command.wrappers):
        if wrapper and _name(wrapper[0]) in RUNNERS:
            yield wrapper + tuple(word for words in command.wrappers[t + 1 :] for word in words) + command.words


def _heads(command: Command):
    """Each way of reading the command's words from its name on: the walk's own, and from each word
    after a wrapper that may be the name of what it runs, where the walk took it as an option's
    value; a word holding a blank, or an option, is never a name."""
    yield command.words
    for words in _from_wrappers(command):
        for k in _leads(words):
            if k and not words[k].startswith("-") and not _blank(words[k]):
                yield words[k:]


def _before_end(args):
    """A command's words up to its first --."""
    return args[: args.index("--")] if "--" in args else args


def _named(names, test=None):
    """A test refusing a command named one of names, whose words after the name pass test."""

    def named(command, context):
        for words in _heads(command):
            if words and _name(words[0]) in names and (test is None or test(list(words[1:]))):
                return True
        return False

    return named


def _ops(args):
    return any(word == "ops" or word.endswith("=ops") for word in _before_end(args))


def _capture(command, context):
    for words in _heads(command):
        if not words:
            continue
        name = _name(words[0])
        if name == "ui-capture":
            return True
        if name in INTERPRETERS:
            args = list(words[1:])
            if name in ("deno", "bun") and args[:1] == ["run"]:
                args = args[1:]
            if any(_name(args[k]) == "ui-capture" and not _blank(args[k]) for k in _leads(args, wrappers=False)):
                return True
    return False


def _role_word(word, ends):
    """Whether word names AGENT_TEAM_ROLE or AGENT_TEAM_TASK, followed by nothing or by one of
    ends."""
    for variable in ROLE_VARIABLES:
        if word.startswith(variable):
            rest = word[len(variable) :]
            if not rest or rest[0] in ends:
                return True
    return False


def _assigned(command, context):
    if any(_role_word(word, "=+[") and ASSIGNMENT.match(word) for word in command.assignments):
        return True
    for words in _heads(command):
        if not words:
            continue
        name, args = _name(words[0]), list(words[1:])
        if name in DECLARERS and any(_role_word(word, "=+[<) \t\n'\";&|") for word in args):
            return True
        if name == "printf":
            for k, word in enumerate(args):
                if word == "-v" and k + 1 < len(args) and args[k + 1].startswith(ROLE_VARIABLES):
                    return True
                if word.startswith(tuple("-v" + variable for variable in ROLE_VARIABLES)):
                    return True
    return False


def _env_unsets(words):
    """Whether env's words unset either variable: -u or --unset with it, joined or next."""
    for k, word in enumerate(words):
        following = words[k + 1] if k + 1 < len(words) else ""
        unset = ENV_UNSET.fullmatch(word) or word == "--unset"
        if unset and following.startswith(ROLE_VARIABLES):
            return True
        joined = ENV_UNSET.match(word)
        if joined and word[joined.end() :].startswith(ROLE_VARIABLES):
            return True
        if word.startswith("--unset=") and word[len("--unset=") :].startswith(ROLE_VARIABLES):
            return True
    return False


def _unset(command, context):
    for words in _heads(command):
        if words and _name(words[0]) == "unset" and any(_role_word(word, "[") for word in words[1:]):
            return True
        if words and _name(words[0]) == "env" and _env_unsets(list(words[1:])):
            return True
    return any(_name(words[0]) == "env" and _env_unsets(list(words[1:])) for words in _from_wrappers(command))


def _team_script(word):
    """Whether a word names a team script: team-<anything> or claude-coordinator, by any path."""
    name = _name(word)
    if _blank(word) or word.startswith("-"):
        return False
    return name == "claude-coordinator" or (name.startswith("team-") and len(name) > len("team-"))


def _empties(wrapper):
    """Whether a wrapper's words empty the environment of what it runs: env -i, env
    --ignore-environment, env - or exec -c."""
    pattern = EMPTIES.get(_name(wrapper[0])) if wrapper else None
    return pattern is not None and any(pattern[0].fullmatch(word) for word in wrapper[1:])


def _emptied(command, context):
    # What runs behind an emptied environment, a string a shell runs there among it.
    if command.words and _team_script(command.words[0]) and any(_empties(w) for w in command.wrappers):
        return True
    # A team script past env's or exec's options where the walk took it as an option's value.
    for words in _from_wrappers(command):
        for k in _leads(words):
            pattern = EMPTIES.get(_name(words[k]))
            if pattern is None:
                continue
            empties, valued = pattern
            rest = words[k + 1 :]
            for e in _leads(rest, wrappers=False):
                if not empties.fullmatch(rest[e]):
                    continue
                after = rest[e + 1 :]
                starts = (0, 1) if valued.fullmatch(rest[e]) else (0,)
                if any(_team_script(after[j]) for j in _leads(after, starts)):
                    return True
    return False


def _steal(args):
    return "--steal" in _before_end(args)


def _thread(args):
    return bool(args) and TASK_ID.fullmatch(args[0]) is not None


def _coordinator(command, context):
    return _named(COORDINATOR)(command, context) or _named({"team-thread"}, _thread)(command, context)


def _upload(command, context):
    return outbound.uploads_outside(command)


ROLE_REASON = "a worker's role and task are its settings' ({})"

ROWS = (
    Row(
        "ops-launch",
        _named({"team-worker", "team-load-check"}, _ops),
        "an ops session is the coordinator's to launch, on Daniel's request (team-worker or team-load-check with ops)",
    ),
    Row(
        "capture-script",
        _capture,
        "the frontend toolkit's capture script is Daniel's own sessions' (run by its path or by an interpreter)",
    ),
    Row("role-assigned", _assigned, ROLE_REASON.format("an assignment of AGENT_TEAM_ROLE or AGENT_TEAM_TASK")),
    Row("role-unset", _unset, ROLE_REASON.format("an unset of AGENT_TEAM_ROLE or AGENT_TEAM_TASK")),
    Row(
        "environment-emptied",
        _emptied,
        ROLE_REASON.format(
            "a team script run with its environment emptied, by env -i, env --ignore-environment, env - or exec -c"
        ),
    ),
    Row(
        "lease-steal",
        _named({"team-lease", "team-resume"}, _steal),
        "a lease steal is Daniel's word, through the coordinator (team-lease or team-resume with --steal)",
    ),
    Row(
        "coordinator-commands",
        _coordinator,
        "the coordinator's commands (team-ask, team-answer, team-inbox, team-thread T<n> and team-run-approved)",
    ),
    Row("upload", _upload, outbound.REASON),
)


def _code(command):
    """The command's code text, with the operator and marker of each heredoc it still opens
    blanked, so the walk reads every line of it as code: a body a shell reads, kept whole, and the
    lines after a heredoc whose body is left out."""
    code = code_text(command)
    out, start = [], 0
    for heredoc in sorted(read_command(code).heredocs, key=lambda heredoc: heredoc.marker[0]):
        begin, end = heredoc.marker
        out += [code[start:begin], " " * (end - begin)]
        start = end
    return "".join(out) + code[start:]


class RowError(Exception):
    """A row that raised, named."""


def refusal(command, context=None):
    """The first row, in table order, that refuses any command the text runs, with its reason and
    allowed way, or None."""
    # The command's own text too, whose heredoc bodies the walk leaves out as Bash reads them: a
    # line of the code text that an unquoted body keeps from its first $( or backtick on may open
    # a substitution that never closes (an escaped backtick), which would hide the lines after it.
    walked = list(commands(_code(command))) + list(commands(command))
    for row in ROWS:
        for found in walked:
            try:
                refused = row.test(found, context)
            except Exception as error:  # noqa: BLE001 - named, then refused by the caller
                raise RowError(f"{row.id}: {type(error).__name__}: {error}") from error
            if refused:
                return {"rule": row.id, "reason": row.reason, "allowed": row.allowed}
    return None


def main():
    if sys.argv[1:]:
        sys.stderr.write("usage: python3 -I command_rules.py   (the hook's input JSON on stdin)\n")
        return 2
    try:
        call = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        command = call["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError("tool_input.command is not a string")
        found = refusal(command)
    except RowError as error:
        sys.stderr.write(f"{error}\n")
        return 1
    except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
        sys.stderr.write(f"command_rules.py: {type(error).__name__}: {error}\n")
        return 1
    if found:
        sys.stdout.write(json.dumps(found, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
