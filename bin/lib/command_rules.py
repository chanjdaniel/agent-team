#!/usr/bin/env python3
"""command-guard's rule table: whether a worker's Bash call runs a guarded thing.

Usage: python3 -I command_rules.py   (the hook's input JSON on stdin)

bin/hooks/command-guard runs this file once per Bash call it does not pass at once, and refuses
the call when it prints a line. It reads tool_input.command from the hook's input, takes its code
text in parts as command_text.code_parts gives them (the command with each heredoc's body left
out unless a shell may read it, then each string a shell, eval, env -S and find -exec run, and
what is piped into a shell, a part of its own, so a quote one leaves open hides no other), each
heredoc a part still opens blanked so that every line of it is code, and walks each simple
command each part runs, then each one the command's own text runs (its heredocs'
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
and the allowed way the row's, null for every row but the kill and delete rows. It prints nothing
when no row refuses, and exits 0
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
  The kill rows, bin/lib/kill_rules.py's (its header holds their wording): a kill by name or
    pattern, tmux's kill-*, a kill of PIDs read from input, of a PID the guard cannot read before
    it runs, and of a process group, every process or PID 0 or 1, each naming its allowed way.
  The delete rows, bin/lib/delete_rules.py's: none yet.
Each row is given the call's context (Context): the command's text, the hook input's cwd, the
worktree, the job tmp, the roots, the kept paths and the role, each read on a row's first use of
it; only the kill and delete rows use it, so a call with neither reads no process or file for it.
A row reads every command the walk yields, a shell's script file and a sourced one among them (a
file named team-worker that bash runs is team-worker), but for the upload row, which reads no
file's name as curl.
Not seen: a name built by a substitution or held in a variable; a script or function of one's
own, or a copy or link of a guarded one; a string another interpreter runs (python3 -c, node -e,
perl -e, a require of the capture script); a file a shell reads on stdin (cat x | bash); what
command_text.commands does not walk (its header lists it: ssh's remote command, nsenter, chroot,
unshare, systemd-run, tmux send-keys, git rebase's --exec); each under an emptied environment
too, so a team script one of those runs there goes unseen. Of a kill or a delete, not seen: one in
a script file written by an earlier call or the Write tool, a package script (npm run, make), an
interpreter's own code (python3 -c "os.kill(...)"), systemctl, launchctl, docker kill or docker
rm, ssh's remote command, a single file's rm and git clean (which the worker settings deny).
It is a speed bump, as a deny rule is, which the role's rule against reaching a refused thing
another way holds.
"""

import functools
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import (  # noqa: E402
    ASSIGNMENT, code_parts, command_name, commands, from_wrappers, has_blank, heads, leads, read_command,
)
import delete_rules  # noqa: E402
import kill_rules  # noqa: E402
import outbound  # noqa: E402

ROLE_VARIABLES = ("AGENT_TEAM_ROLE", "AGENT_TEAM_TASK")
DECLARERS = frozenset("export declare typeset local readonly let read mapfile readarray".split())
# What runs a script by its path, with its options before it.
INTERPRETERS = frozenset(("node", "deno", "bun", "npx", "source", "."))
COORDINATOR = frozenset(("team-ask", "team-answer", "team-inbox", "team-run-approved"))
TASK_ID = re.compile(r"T[0-9]+")
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
    """A rule: its id, its test over one Command and the call's context, which refuses by
    returning True (the row's reason) or a reason of its own, its reason and its allowed way
    (None: the refusal names none)."""

    id: str
    test: Callable
    reason: str | None
    allowed: str | None = None


# A session id's first 8 characters, which name a background session's job directory.
JOB_ID = re.compile(r"[A-Za-z0-9-]{8}")


class Context:
    """The call's context, each part read on a row's first use of it, so only a call with a kill
    or a recursive delete in it reads the process table or the file system: the command's text;
    cwd, the hook input's, resolved; the worktree, CLAUDE_PROJECT_DIR when it is a directory, else
    the git top level of cwd; the job tmp, $CLAUDE_JOB_DIR/tmp when it is a directory, else
    ~/.claude/jobs/<the session id's first 8 characters>/tmp when that is one; the roots, those of
    the two that exist, resolved; the kept paths, each root and the worktree's .scratch/task; and
    the role, AGENT_TEAM_ROLE, empty in a gate agent."""

    def __init__(self, call, environ=None):
        self.call = call
        self.environ = os.environ if environ is None else environ
        self.text = call["tool_input"]["command"]

    @functools.cached_property
    def cwd(self):
        cwd = self.call.get("cwd")
        return os.path.realpath(cwd) if isinstance(cwd, str) and cwd else None

    @functools.cached_property
    def worktree(self):
        project = self.environ.get("CLAUDE_PROJECT_DIR")
        if project and os.path.isdir(project):
            return os.path.realpath(project)
        if self.cwd is None:
            return None
        try:
            found = subprocess.run(
                ["git", "-C", self.cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        top = found.stdout.strip()
        return os.path.realpath(top) if found.returncode == 0 and top and os.path.isdir(top) else None

    @functools.cached_property
    def job_tmp(self):
        job = self.environ.get("CLAUDE_JOB_DIR")
        if job and os.path.isdir(os.path.join(job, "tmp")):
            return os.path.realpath(os.path.join(job, "tmp"))
        session = self.call.get("session_id")
        home = self.environ.get("HOME")
        if isinstance(session, str) and JOB_ID.match(session) and home:
            tmp = os.path.join(home, ".claude", "jobs", session[:8], "tmp")
            if os.path.isdir(tmp):
                return os.path.realpath(tmp)
        return None

    @functools.cached_property
    def roots(self):
        return tuple(root for root in (self.worktree, self.job_tmp) if root)

    @functools.cached_property
    def kept(self):
        task = (os.path.realpath(os.path.join(self.worktree, ".scratch", "task")),) if self.worktree else ()
        return self.roots + task

    @functools.cached_property
    def role(self):
        return self.environ.get("AGENT_TEAM_ROLE", "")


def _before_end(args):
    """A command's words up to its first --."""
    return args[: args.index("--")] if "--" in args else args


def _named(names, test=None):
    """A test refusing a command named one of names, whose words after the name pass test."""

    def named(command, context):
        for words in heads(command):
            if words and command_name(words[0]) in names and (test is None or test(list(words[1:]))):
                return True
        return False

    return named


def _ops(args):
    return any(word == "ops" or word.endswith("=ops") for word in _before_end(args))


def _capture(command, context):
    for words in heads(command):
        if not words:
            continue
        name = command_name(words[0])
        if name == "ui-capture":
            return True
        if name in INTERPRETERS:
            args = list(words[1:])
            if name in ("deno", "bun") and args[:1] == ["run"]:
                args = args[1:]
            reached = leads(args, wrappers=False)
            if any(command_name(args[k]) == "ui-capture" and not has_blank(args[k]) for k in reached):
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
    for words in heads(command):
        if not words:
            continue
        name, args = command_name(words[0]), list(words[1:])
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
    for words in heads(command):
        if words and command_name(words[0]) == "unset" and any(_role_word(word, "[") for word in words[1:]):
            return True
        if words and command_name(words[0]) == "env" and _env_unsets(list(words[1:])):
            return True
    return any(command_name(words[0]) == "env" and _env_unsets(list(words[1:])) for words in from_wrappers(command))


def _team_script(word):
    """Whether a word names a team script: team-<anything> or claude-coordinator, by any path."""
    name = command_name(word)
    if has_blank(word) or word.startswith("-"):
        return False
    return name == "claude-coordinator" or (name.startswith("team-") and len(name) > len("team-"))


def _empties(wrapper):
    """Whether a wrapper's words empty the environment of what it runs: env -i, env
    --ignore-environment, env - or exec -c."""
    pattern = EMPTIES.get(command_name(wrapper[0])) if wrapper else None
    return pattern is not None and any(pattern[0].fullmatch(word) for word in wrapper[1:])


def _emptied(command, context):
    # What runs behind an emptied environment, a string a shell runs there among it.
    if command.words and _team_script(command.words[0]) and any(_empties(w) for w in command.wrappers):
        return True
    # A team script past env's or exec's options where the walk took it as an option's value.
    for words in from_wrappers(command):
        for k in leads(words):
            pattern = EMPTIES.get(command_name(words[k]))
            if pattern is None:
                continue
            empties, valued = pattern
            rest = words[k + 1 :]
            for e in leads(rest, wrappers=False):
                if not empties.fullmatch(rest[e]):
                    continue
                after = rest[e + 1 :]
                starts = (0, 1) if valued.fullmatch(rest[e]) else (0,)
                if any(_team_script(after[j]) for j in leads(after, starts)):
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
) + tuple(Row(id, test, None, allowed) for id, test, allowed in kill_rules.ROWS + delete_rules.ROWS)


def _code(part):
    """A part of the command's code text, with the operator and marker of each heredoc it still
    opens blanked, so the walk reads every line of it as code: a body a shell reads, kept whole,
    and the lines after a heredoc whose body is left out."""
    out, start = [], 0
    for heredoc in sorted(read_command(part).heredocs, key=lambda heredoc: heredoc.marker[0]):
        begin, end = heredoc.marker
        out += [part[start:begin], " " * (end - begin)]
        start = end
    return "".join(out) + part[start:]


class RowError(Exception):
    """A row that raised, named."""


def refusal(command, context=None):
    """The first row, in table order, that refuses any command the text runs, with its reason and
    allowed way, or None; each row is given the call's context."""
    # The command's own text too, whose heredoc bodies the walk leaves out as Bash reads them: a
    # line of the code text that an unquoted body keeps from its first $( or backtick on may open
    # a substitution that never closes (an escaped backtick), which would hide the lines after it.
    walked = [found for part in code_parts(command) for found in commands(_code(part))]
    walked += commands(command)
    for row in ROWS:
        for found in walked:
            try:
                refused = row.test(found, context)
            except Exception as error:  # noqa: BLE001 - named, then refused by the caller
                raise RowError(f"{row.id}: {type(error).__name__}: {error}") from error
            if refused:
                reason = refused if isinstance(refused, str) else row.reason
                return {"rule": row.id, "reason": reason, "allowed": row.allowed}
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
        found = refusal(command, Context(call))
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
