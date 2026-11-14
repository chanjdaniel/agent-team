"""command-guard's delete rows: a recursive delete that reaches what is not the worker's own.

bin/lib/command_rules.py appends ROWS to its table after the kill rows (bin/lib/kill_rules.py).
Each row is its id, its test over one command_text.Command and the call's context, returning its
reason when it refuses and None when it passes, and its allowed way, as kill_rules.py's are.
A recursive delete passes only when every path it deletes resolves strictly inside a root (the
worktree or the job tmp) and is no kept path (a root or the worktree's .scratch/task) nor a
directory holding one.

Which commands, read past their wrappers as command_text.heads_behind reads them, so a path, a
quoted name, sudo, env, nohup, timeout and the rest are no way around a row:
  rm with a recursive option (r or R in a short option cluster, or a long option that is a prefix
    of --recursive from --r on), its operands every word that is no option and every word after
    --; a file a shell runs as its script, or source reads, is never rm.
  find with -delete outside its -exec lists, its operands its start paths (its words before the
    first that starts with -, ( or !, past the leading options -H, -L, -P, -E, -X, -d, -s, -x,
    -D <debug> and -O<level> and a -- after them; . when there are none, a {} never one), and
    the list -files0-from reads them from, which the guard cannot read: "-files0-from's list".
  rm run by find's -exec, -execdir, -ok or -okdir, recursive or not, directly or in a string a
    shell there runs: find's start paths are its operands, and its own operands holding no {} are
    checked as well when it is recursive.
  rm or find behind xargs or parallel deletes what they read from input (and parallel's :::
    inputs), which the guard cannot read: its word is "xargs's input" or "parallel's input".
  Every rm or find above, in a call that names extglob (below) and whose text holds a pattern's
    opening (@(, !(, +(, ?( or *(), which the walk reads as a subshell, deletes "an extglob
    pattern", unread.
A call names a variable or a shell option when its text does, or that text unquoted (its line
continuations dropped, its $'...' strings decoded, its quotes and backslashes removed), or a word,
assignment or wrapper word of a command its walk reads that the text does not hold as it is; so
I""FS=, C\\DPATH=, CD{PATH,X}= and shopt -s cdable_v''ars name them. A shopt with a word, or a shell with an -O or +O value, holding
a $ or a backtick names every option.
Each operand is resolved without running anything, from the walk's word (its quotes removed, its
unquoted brace lists expanded):
  - a backslash left in it (a quoted backslash), or a word the walk decoded from a $'...' escape
    or made by a brace range ({1..3}), makes it unread, named as written;
  - a brace comma list ({a,b}, nested too) left in it is expanded;
  - a leading ~ or ~/ is HOME; ~user, ~+ and ~- are unread;
  - $HOME and $CLAUDE_JOB_DIR (each also as ${...}) are the hook's environment, an unset one
    empty; $CLAUDE_PROJECT_DIR is both the hook's value and empty, every one of which must pass,
    since the Bash tool's shell does not set it, though hooks get it; $PWD is each candidate
    directory below; any of them is unread when the call names it (above) otherwise than as a use
    ($X, ${X}, ${X:-y}), as an assignment, read, unset or a word of prose does;
  - a variable the command assigns is each value it is given, every one of which must pass: its
    first mention in the command's text is an assignment (X=...) and every other one the call
    names (above) an assignment or a use, and each value comes from a bare assignment or one of export, local, declare,
    typeset or readonly (not declare -n); a value that is $(mktemp ...) or `mktemp ...` alone is
    the new path mktemp makes: its template under -p <dir> or --tmpdir=<dir>; its template's name
    under $TMPDIR (/tmp when it is empty) with -t, --tmpdir alone or no template (tmp.XXXXXXXXXX);
    else its template as written, relative to the cwd when relative; a value with a blank, or that
    starts with (, an array, is unread, and so is a variable assigned before a command on its line
    (X=1 rm -rf "$X", env X=1 ...), which the shell expands before the assignment;
  - any other $, a backtick, $( or <( or >( left in it makes it unread, and so does a variable
    while the call names IFS otherwise than as a use, since that may split its value;
  - a path under /proc or /dev is unread, since /proc/self and /dev/fd name the guard's own
    process there.
A relative operand is checked against every candidate directory: the input's cwd and each cd or
pushd target anywhere in the command (cd alone is HOME), resolved the same way, each relative one
against every candidate so far, both as the shell's logical cd reads it and as the file system
does; a cd -, popd, pushd with no directory or a +N or -N, a cd to an unread target, a relative cd
target while CDPATH is set or named, env's -C or --chdir and sudo's -D or --chdir make every
relative operand unread, and so do a call with no cwd and one that names cdable_vars, under which
cd follows a variable of the name it is given.
Each path is made absolute, and its symlinks are followed (os.path.realpath), so a link never
launders a delete. A glob (*, ? or [ in a component) passes when the literal directory before its
first glob component passes, which holds no kept path then, and that component does not start
with a dot (which may match ..); when a component follows its first glob component, the path
normalized as written must pass too, and so must each directory that glob matches now joined to
the rest, resolved, or when the rest holds a glob judged so in turn (to 256 matches in all), so a
.. or a link after a glob climbs nowhere unseen. Such a path is unread in a call that names
dotglob, GLOBIGNORE (which turns it on), nocaseglob or globstar, under which Bash's glob matches
hidden entries, another case or across directories, which the guard's match skips. An empty
operand deletes nothing.
With no root at all (no worktree and no job tmp found), every recursive delete is refused as
outside, naming its first operand.
The rows, in order, each naming the first operand of its kind:
  delete-outside: a path outside the worktree and the job tmp.
  delete-kept: the worktree, its .scratch/task or the job tmp, or a directory holding one.
  delete-unread: a path the guard cannot read before it runs.
Not this rule's: git clean (which the worker settings deny), rsync --delete, a single file's rm,
rmdir, an editor tool's write and an interpreter's own delete.
Not seen: a link or a move the same command makes before its delete (ln -s /tmp l && rm -rf l/x),
since the guard reads the file system as it is before the command runs.
"""

import functools
import glob
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import (  # noqa: E402
    FIND_EXEC, SCRIPT, SHELLS, SOURCE, blank_heredocs, code_parts, command_name, commands, heads_behind, long_options,
    short_cluster, simple_commands, unquoted,
)

ALLOWED_DELETE = (
    "delete only inside your worktree (never it or its .scratch/task, which team-close archives) or inside"
    ' $CLAUDE_JOB_DIR/tmp, by a path spelled out in the command; make scratch with mktemp -d'
    ' "$CLAUDE_JOB_DIR/tmp/<name>.XXXXXX"'
)
ALLOWED_UNREAD = (
    'spell the path out, or set the variable in the same command (T=$(mktemp -d "$CLAUDE_JOB_DIR/tmp/<name>.XXXXXX")),'
    " inside your worktree or your job's tmp"
)
RM = "a recursive delete of {}"
FIND = "a recursive delete (find -delete or find -exec rm) under {}"
OUTSIDE, KEPT, UNREAD = "outside", "kept", "unread"
WHY = {
    OUTSIDE: ", which is outside your worktree and your job's tmp",
    KEPT: ", which is your worktree, its .scratch/task or your job's tmp, or holds one",
    UNREAD: (
        ", a path the guard cannot read before it runs (a variable or substitution this command does not set,"
        " a ~user, a brace range, or a relative path after a cd it cannot follow)"
    ),
}

# What runs a command on words read from its input.
FEEDERS = ("xargs", "parallel")
# The variables an operand may name that the hook reads from its own environment.
KNOWN = ("HOME", "CLAUDE_JOB_DIR", "CLAUDE_PROJECT_DIR")
# Those of them the Bash tool's shell does not set, though hooks get them: read as unset too.
HOOK_ONLY = ("CLAUDE_PROJECT_DIR",)
DECLARERS = frozenset(("export", "local", "declare", "typeset", "readonly"))
# A variable as $NAME or ${NAME}.
REFERENCE = re.compile(r"\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})")
GLOB = re.compile(r"[*?\[]")
# An extglob pattern's opening, which the walk reads as a subshell's (, as Bash does while extglob
# is off.
EXTGLOB = re.compile(r"[?*+@!]\(")
# The shell options and the variable under which Bash's glob matches what glob.iglob skips: hidden
# entries (dotglob, and GLOBIGNORE, which turns it on), another case, and ** across directories.
GLOB_OPTIONS = ("dotglob", "nocaseglob", "globstar", "GLOBIGNORE")
# The trees whose links name the process that reads them.
LIVE = ("/proc/", "/dev/")
# What a word may still hold that the shell expands at run time.
UNREAD_TEXT = re.compile(r"[$`]|[<>]\(")
# find's options before its start paths: those with no value, and -D with one.
FIND_LEADING = re.compile(r"-[HLPEXdsx]+|-O[0-9]*")
MKTEMP_LONG = frozenset(("directory", "quiet", "dry-run", "suffix", "tmpdir", "help", "version"))
# How many paths one operand may expand to, how many candidate directories a call may have, and
# how deep a variable's value may name another, before the guard reads it as unread.
MAX_PATHS = 64
MAX_CANDIDATES = 64
# The most directories one glob a component follows may match before the delete is unread.
MAX_MATCHES = 256
MAX_DEPTH = 8


class Unread(Exception):
    """An operand, a value or a directory the guard cannot read before the command runs."""


def _mentions(name, text):
    """Each mention of the variable name in the text, as (is it a use, is it an assignment)."""
    for mention in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", text):
        start, end = mention.span()
        braced = text.endswith("${", 0, start)
        used = (text.endswith("$", 0, start) and not braced) or (braced and not re.match(r":?=", text[end:]))
        yield used, not used and not braced and text[end : end + 1] == "=" and text[end + 1 : end + 2] != "="


def _rebound(name, context):
    """Whether the command names the variable otherwise than as a use, as _spelled reads it."""
    return any(not used for used, _ in _mentions(name, _spelled(context)))


@functools.lru_cache(maxsize=None)
def _spelled(context):
    """The command's text as Bash reads the names in it: the text, then a line of it unquoted
    (command_text.unquoted), then a line for each word, assignment and wrapper word of every
    command the walk reads (its quotes removed, its escapes decoded, its brace lists expanded) that
    the text does not hold as it is, since only such a word may spell a name otherwise (a word the
    text holds is read in it, as ${T}'s T is a use); so a name spelled with quotes, an escape, a
    line continuation or a brace list is named in it."""
    lines = [context.text, unquoted(context.text)]
    for command in _walked(context):
        words = list(command.assignments + command.words)
        words += [word for wrapper in command.wrappers for word in wrapper]
        lines += [word for word in words if word not in context.text]
    return "\n".join(lines)


@functools.lru_cache(maxsize=None)
def _named(name, context):
    """Whether the command names a shell option or variable, as _spelled reads it, or runs a
    shopt with a word, or a shell with an -O or +O option, the guard cannot read (a $ or a
    backtick left in it), which may set any option."""
    if re.search(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", _spelled(context)):
        return True
    for command in _walked(context):
        words = list(command.words)
        ran = command_name(words[0]) if words else ""
        if ran == "shopt":
            options = words[1:]
        elif ran in SHELLS:
            options = [value for option, value in zip(words[1:], words[2:]) if option in ("-O", "+O")]
        else:
            continue
        if any(UNREAD_TEXT.search(word) for word in options):
            return True
    return False


@functools.lru_cache(maxsize=None)
def _walked(context):
    """Each command the call runs, as command_rules walks it: its code text's parts, then its own
    text."""
    found = [command for part in code_parts(context.text) for command in commands(blank_heredocs(part))]
    return tuple(found + list(commands(context.text)))


@functools.lru_cache(maxsize=None)
def _assigned(name, context):
    """The values the command gives the variable, or None when it may hold another: its first
    mention not an assignment, a mention that is neither a use nor an assignment, an assignment
    before a command on its line, a nameref, or no value found."""
    mentions = list(_mentions(name, _spelled(context)))
    if not mentions or not mentions[0][1] or any(not used and not assigns for used, assigns in mentions):
        return None
    prefix, values = name + "=", []
    for command in _walked(context):
        if command.reached in (SCRIPT, SOURCE):
            continue
        given = [word[len(prefix) :] for word in command.assignments if word.startswith(prefix)]
        if given and command.words:
            return None
        values += given
        if command.words and command_name(command.words[0]) in DECLARERS:
            args = command.words[1:]
            named = [word[len(prefix) :] for word in args if word.startswith(prefix)]
            if named and any(re.fullmatch(r"[-+][A-Za-z]*n[A-Za-z]*", word) for word in args):
                return None
            values += named
    return tuple(dict.fromkeys(values)) or None


def _braces(word):
    """The word's brace comma lists expanded, as Bash's brace expansion does; a sequence is
    unread."""
    i = 0
    while True:
        start = word.find("{", i)
        if start < 0:
            return [word]
        if word.endswith("$", 0, start):
            i = start + 1
            continue
        depth, commas = 0, []
        for j in range(start, len(word)):
            if word[j] == "{":
                depth += 1
            elif word[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            elif word[j] == "," and depth == 1:
                commas.append(j)
        else:
            return [word]
        if commas:
            bounds = [start] + commas + [j]
            out = []
            for a, b in zip(bounds, bounds[1:]):
                out += _braces(word[:start] + word[a + 1 : b] + word[j + 1 :])
            if len(out) > MAX_PATHS:
                raise Unread
            return out
        if ".." in word[start + 1 : j]:
            raise Unread
        i = start + 1


def _environment(name, context):
    """A variable's value from the hook's environment, unread when the command rebinds it."""
    if _rebound(name, context):
        raise Unread
    return context.environ.get(name, "")


def _tilde(text, context):
    """The text's leading ~ or ~/ as HOME; ~user, ~+ and ~- are unread."""
    if text == "~" or text.startswith("~/"):
        return _environment("HOME", context) + text[1:]
    if text.startswith("~"):
        raise Unread
    return text


def _values(name, context, depth):
    """Each value $name may hold where the command runs."""
    if name in KNOWN:
        value = _environment(name, context)
        return [value, ""] if name in HOOK_ONLY and value else [value]
    if name == "PWD":
        if _rebound(name, context):
            raise Unread
        return list(_candidates(context))
    values = _assigned(name, context)
    if values is None or depth >= MAX_DEPTH:
        raise Unread
    out = []
    for value in values:
        out += _value(value, context, depth + 1)
    return out


def _value(value, context, depth):
    """The paths an assignment's value stands for: mktemp's new path, else the value with its
    leading ~ and its variables expanded."""
    substitution = re.fullmatch(r"\$\((.*)\)|`(.*)`", value, re.DOTALL)
    if substitution:
        return _mktemp(substitution.group(1) if substitution.group(1) is not None else substitution.group(2),
                       context, depth)
    if value.startswith("("):
        raise Unread
    return _substitute(_tilde(value, context), context, depth)


def _mktemp(text, context, depth):
    """The paths mktemp's command text makes: each template under its directory."""
    if re.search(r"[;&|()`\n]|\$\(", text):
        raise Unread
    found = list(simple_commands(text))
    if len(found) != 1 or not found[0] or command_name(found[0][0]) != "mktemp":
        raise Unread
    args, directory, under_tmpdir, templates, k = found[0][1:], None, False, [], 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            templates += args[k:]
            break
        if word.startswith("--"):
            name, eq, given = word[2:].partition("=")
            options = long_options(name, MKTEMP_LONG)
            if len(options) != 1:
                raise Unread
            if options == {"tmpdir"}:
                under_tmpdir, directory = True, given if eq else None
            elif options == {"suffix"} and not eq:
                k += 1
        elif word.startswith("-") and word != "-":
            flags, flag, joined = short_cluster(word, "p")
            under_tmpdir = under_tmpdir or "t" in flags
            if flag:
                if not joined and k < len(args):
                    joined, k = args[k], k + 1
                under_tmpdir, directory = True, joined
        else:
            templates.append(word)
    if directory is not None and directory != "":
        bases = _substitute(_tilde(directory, context), context, depth)
    elif under_tmpdir or not templates:
        if _rebound("TMPDIR", context):
            raise Unread
        bases = [context.environ.get("TMPDIR") or "/tmp"]
    else:
        bases = [None]
    out = []
    for template in templates or ["tmp.XXXXXXXXXX"]:
        for path in _substitute(_tilde(template, context), context, depth):
            for base in bases:
                if base is None or path.startswith("/"):
                    out.append(path)
                else:
                    out.append(os.path.join(base, path if directory else os.path.basename(path)))
    return out


def _substitute(text, context, depth):
    """The text with each $NAME and ${NAME} it holds replaced by each value it may hold."""
    results, at = [""], 0
    for reference in REFERENCE.finditer(text):
        # An IFS the command sets may split a value where a blank would not.
        if _rebound("IFS", context):
            raise Unread
        values = _values(reference.group(1) or reference.group(2), context, depth)
        if any(re.search(r"\s", value) for value in values):
            raise Unread
        literal = text[at : reference.start()]
        results = [result + literal + value for result in results for value in values]
        if len(results) > MAX_PATHS:
            raise Unread
        at = reference.end()
    results = [result + text[at:] for result in results]
    if any(UNREAD_TEXT.search(result) for result in results):
        raise Unread
    return results


def _expand(word, context):
    """The word as the paths the shell may make of it, relative ones as they stand."""
    # The walk decoded a $'...' escape or expanded a brace range in a word it marks written.
    if "\\" in word or getattr(word, "written", None) is not None:
        raise Unread
    out = []
    for braced in _braces(word):
        out += _substitute(_tilde(braced, context), context, 0)
    return out


def _cd_targets(command):
    """The directories a cd, pushd, popd or a wrapper's chdir option may move the command to, as
    words, with None for one it cannot follow."""
    for wrapper in command.wrappers:
        name = command_name(wrapper[0]) if wrapper else ""
        short = {"env": "C", "sudo": "D"}.get(name)
        for word in wrapper[1:] if short else ():
            if word.startswith("--ch") or re.fullmatch(rf"-[^-]*{short}.*", word):
                yield None
    if not command.words or command.reached in (SCRIPT, SOURCE):
        return
    name, args = command_name(command.words[0]), list(command.words[1:])
    if name not in ("cd", "pushd", "popd"):
        return
    if name == "popd":
        yield None
        return
    while args and args[0].startswith("-") and args[0] != "-":
        if args.pop(0) == "--":
            break
    if not args:
        yield "~" if name == "cd" else None
    elif args[0] == "-" or (name == "pushd" and re.fullmatch(r"[+-][0-9]+", args[0])):
        yield None
    else:
        yield args[0]


def _within(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


@functools.lru_cache(maxsize=None)
def _candidates(context):
    """Each directory the command may be in when it runs a relative delete, resolved: its cwd and
    each cd target; Unread when one cannot be followed."""
    # cdable_vars makes cd follow a variable of the name it is given.
    if context.cwd is None or _named("cdable_vars", context):
        raise Unread
    targets = [target for command in _walked(context) for target in _cd_targets(command)]
    if None in targets:
        raise Unread
    found = [context.cwd]
    absolute, relative = [], []
    for target in targets:
        # $PWD in a cd target would read the candidates being found.
        if any("PWD" in reference.groups() for reference in REFERENCE.finditer(target)):
            raise Unread
        for path in _expand(target, context):
            (absolute if path.startswith("/") else relative).append(path)
    if relative and (context.environ.get("CDPATH") or _named("CDPATH", context)):
        raise Unread

    def add(path):
        for resolved in (os.path.realpath(path), os.path.realpath(os.path.normpath(path))):
            if resolved not in found:
                found.append(resolved)
        if len(found) > MAX_CANDIDATES:
            raise Unread

    for path in absolute:
        add(path)
    for _ in relative:
        for base in list(found):
            for path in relative:
                add(os.path.join(base, path))
    return tuple(found)


def _verdicts(path, context, matched=None):
    """An absolute path's verdicts, each OUTSIDE, KEPT or None (it passes) and how it is named: the
    path's own, and for a glob a component follows, where its .. or a link may climb from each
    directory the glob matches, the path normalized as written and each such match's, joined to
    the rest, whose own globs are followed so in turn; Unread past MAX_MATCHES matches in all, or
    under an option by which Bash matches what glob.iglob skips (GLOB_OPTIONS)."""
    matched = [0] if matched is None else matched
    yield _verdict(path, context)
    parts = path.split("/")
    first = next((k for k, part in enumerate(parts) if GLOB.search(part)), None)
    if first is None or first == len(parts) - 1:
        return
    if any(_named(option, context) for option in GLOB_OPTIONS):
        raise Unread
    yield _verdict(os.path.normpath(path), context)
    rest = "/".join(parts[first + 1 :])
    for match in glob.iglob("/".join(parts[: first + 1])):
        matched[0] += 1
        if matched[0] > MAX_MATCHES:
            raise Unread
        joined = os.path.join(match, rest)
        if GLOB.search(rest):
            yield from _verdicts(joined, context, matched)
        else:
            yield _verdict(os.path.realpath(joined), context)


def _verdict(path, context):
    """An absolute path's verdict, OUTSIDE, KEPT or None (it passes), and how it is named."""
    parts = path.split("/")
    first = next((k for k, part in enumerate(parts) if GLOB.search(part)), None)
    if first is None:
        directory = shown = os.path.realpath(path)
        dotted = False
    else:
        directory = os.path.realpath("/".join(parts[:first]) or "/")
        shown = directory.rstrip("/") + "/" + "/".join(parts[first:])
        dotted = parts[first].startswith(".")
    if not any(_within(directory, root) for root in context.roots):
        return OUTSIDE, shown
    if dotted or any(_within(kept, directory) for kept in context.kept):
        return KEPT, shown
    return None, shown


def _judge(word, opening, context):
    """The verdicts of one operand: (kind, reason) for each path it may delete that does not pass,
    or with no root one OUTSIDE for its first path, or its word when that is unread."""
    try:
        paths = []
        for path in _expand(word, context):
            if path and not path.startswith("/"):
                paths += [os.path.join(base, path) for base in _candidates(context)]
            elif path:
                paths.append(path)
        # /proc/self, /dev/fd and the rest name the guard's own process, not the command's.
        if any(path.startswith(LIVE) for path in paths):
            raise Unread
        found = []
        for path in paths:
            for kind, shown in _verdicts(path, context):
                if kind:
                    found.append((kind, opening.format(shown) + WHY[kind]))
    except Unread:
        written = getattr(word, "written", None) or word
        if not context.roots:
            return [(OUTSIDE, opening.format(written) + WHY[OUTSIDE])]
        return [(UNREAD, opening.format(written) + WHY[UNREAD])]
    return found


def _rm(args):
    """Whether rm's words after its name make it recursive, and its operands."""
    recursive, operands = False, []
    for k, word in enumerate(args):
        if word == "--":
            operands += args[k + 1 :]
            break
        if word.startswith("--"):
            recursive = recursive or (len(word) > 2 and "--recursive".startswith(word))
        elif word.startswith("-") and word != "-":
            recursive = recursive or "r" in word or "R" in word
        else:
            operands.append(word)
    return recursive, operands


def _starts(args):
    """find's start paths among its words after its name: past its leading options and a -- that
    ends them, its words before the first that starts with -, ( or !; . when there are none; a {}
    never one."""
    k = 0
    while k < len(args) and (FIND_LEADING.fullmatch(args[k]) or args[k] == "-D"):
        k += 2 if args[k] == "-D" else 1
    if args[k : k + 1] == ["--"]:
        k += 1
    paths = []
    while k < len(args) and not args[k].startswith(("-", "(", "!")):
        paths.append(args[k])
        k += 1
    return [path for path in paths if path != "{}"] if paths else ["."]


def _holds(args, option):
    """Whether find's words hold option outside its -exec lists."""
    k = 0
    while k < len(args):
        if args[k] in FIND_EXEC:
            while k < len(args) and args[k] not in (";", "+"):
                k += 1
        elif args[k] == option:
            return True
        k += 1
    return False


def _find_starts(args, context):
    """The verdicts on find's start paths: each of _starts', and its -files0-from list's, which the
    guard cannot read before it runs (with no root, outside)."""
    found = []
    for start in _starts(args):
        found += _judge(start, FIND, context)
    if _holds(args, "-files0-from"):
        kind = OUTSIDE if not context.roots else UNREAD
        found.append((kind, FIND.format("-files0-from's list") + WHY[kind]))
    return found


@functools.lru_cache(maxsize=None)
def _judgments(command, context):
    """Every verdict on what the command deletes that does not pass, in its operands' order."""
    if command.reached in (SCRIPT, SOURCE):
        return ()
    found, seen = [], set()
    for words, behind in heads_behind(command):
        if not words or (tuple(words), behind) in seen:
            continue
        seen.add((tuple(words), behind))
        name, args = command_name(words[0]), list(words[1:])
        if name == "rm":
            recursive, operands = _rm(args)
            finder = next((w for w in reversed(command.wrappers) if w and command_name(w[0]) == "find"), None)
            if finder is not None:
                found += _find_starts(list(finder[1:]), context)
                operands = [operand for operand in operands if "{}" not in operand]
            elif not recursive:
                continue
            opening = RM
            if recursive:
                for operand in operands:
                    found += _judge(operand, RM, context)
        elif name == "find" and _holds(args, "-delete"):
            opening = FIND
            found += _find_starts(args, context)
        else:
            continue
        kind = OUTSIDE if not context.roots else UNREAD
        feeder = next((ran for ran in reversed(behind) if ran in FEEDERS), None)
        if feeder:
            found.append((kind, opening.format(f"{feeder}'s input") + WHY[kind]))
        if _named("extglob", context) and EXTGLOB.search(context.text):
            found.append((kind, opening.format("an extglob pattern") + WHY[kind]))
    return tuple(found)


def _row(kind):
    def test(command, context):
        return next((reason for found, reason in _judgments(command, context) if found == kind), None)

    return test


# The rows, in order: each its id, its test and its allowed way.
ROWS = (
    ("delete-outside", _row(OUTSIDE), ALLOWED_DELETE),
    ("delete-kept", _row(KEPT), ALLOWED_DELETE),
    ("delete-unread", _row(UNREAD), ALLOWED_UNREAD),
)
