#!/usr/bin/env python3
"""Check a rewritten repository against the one it was rewritten from, commit by commit.

Usage: python3 verify.py <old-git-dir> <new-git-dir> <drop-list> <message-expressions> [--changed <path-suffix>]...

T56's byte-identical check, run by team-records-rewrite. For every line of
<new>/filter-repo/commit-map (old sha, new sha), the old commit read through <old>'s objects as an
alternate, so <new> is never written:
  - the trees: every difference between the old and the new tree is a deletion of a path the drop
    list matches (so every kept file is byte-identical, same blob and mode, at every commit that
    had it), except a modification of a path ending with a --changed suffix (a callback's);
  - the metadata: author and committer (names, emails, dates) are equal, and the parents are the
    old parents through the commit map;
  - the message: exactly the old one through <message-expressions> (read as git filter-repo's
    --replace-message reads it), but for the commit hashes it names, each either as written or
    mapped as filter-repo maps it (a unique prefix of an old commit to as long a prefix of the
    new): filter-repo maps only a commit it has already rewritten, so one naming a later commit
    keeps its hash.
Then no path the drop list matches is left anywhere in <new>'s branches, and the refs/pull/* of
<old> whose history holds a dropped path are counted (GitHub Support asks for that number).
Paths are read NUL-separated, never C-quoted, so a name with any byte matches as it is.
Prints counts only, never a path's content, and exits 1 on any failure or path left.
"""
import fnmatch
import os
import re
import subprocess
import sys

HASH = re.compile(rb"\b[0-9a-f]{7,40}\b")


def rules(path):
    out = []
    for line in open(path, encoding="utf-8", errors="surrogateescape"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        if line.startswith("glob:"):
            out.append(("g", line[5:]))
        elif line.startswith("regex:"):
            out.append(("r", re.compile(line[6:])))
        else:
            out.append(("l", line.rstrip("/")))
    return out


def matches(p, rs):
    for k, v in rs:
        if k == "g" and fnmatch.fnmatch(p, v):
            return True
        if k == "r" and v.search(p):
            return True
        if k == "l" and (p == v or p.startswith(v + "/")):
            return True
    return False


def expressions(path):
    """The literals and regexes of a --replace-message file, as git filter-repo 2.47.0 reads them."""
    literals, regexes = [], []
    for line in open(path, "rb"):
        line = line.rstrip(b"\r\n")
        replacement = b"***REMOVED***"
        if b"==>" in line:
            line, replacement = line.rsplit(b"==>", 1)
        if line.startswith(b"regex:"):
            regexes.append((re.compile(line[6:]), replacement))
        elif line.startswith(b"glob:"):
            regexes.append((re.compile(fnmatch.translate(line[5:].decode()).encode()), replacement))
        else:
            if line.startswith(b"literal:"):
                line = line[8:]
            if line:
                literals.append((line, replacement))
    return literals, regexes


def git(repo, *args, env=None):
    return subprocess.run(["git", "--git-dir", repo, *args], capture_output=True, check=True, env=env).stdout


def path_of(raw):
    return os.fsdecode(raw)


def parse_commit(raw):
    head, _, msg = raw.partition(b"\n\n")
    fields = {"parent": []}
    for line in head.split(b"\n"):
        if line.startswith(b" "):
            continue  # continuation of gpgsig
        k, _, v = line.partition(b" ")
        if k == b"parent":
            fields["parent"].append(v.decode())
        else:
            fields[k.decode()] = v
    return fields, msg


def history_paths(repo, *revs):
    out = git(repo, "log", *revs, "--format=", "--name-only", "-z", "--no-renames", "-m", "--full-history")
    return {path_of(p.strip(b"\n")) for p in out.split(b"\0") if p.strip(b"\n")}


def main():
    args = sys.argv[1:]
    changed = []
    while "--changed" in args:
        i = args.index("--changed")
        changed.append(args[i + 1])
        del args[i : i + 2]
    if len(args) != 4:
        sys.exit(__doc__.split("\n\n")[1])
    old, new, drop, messages = (os.path.abspath(a) for a in args)
    rs = rules(drop)
    literals, regexes = expressions(messages)
    # The old commits and trees, readable in <new> without fetching them into it.
    env = dict(os.environ, GIT_ALTERNATE_OBJECT_DIRECTORIES=os.path.join(old, "objects"))
    cmap = {}
    for line in open(os.path.join(new, "filter-repo", "commit-map")):
        a, b = line.split()
        if a == "old":
            continue
        cmap[a] = b
    by_prefix = {}
    for o in cmap:
        by_prefix.setdefault(o[:7], []).append(o)

    def mapped(h):
        h = h.decode()
        if h in cmap:
            return cmap[h][: len(h)].encode()
        found = [o for o in by_prefix.get(h[:7], []) if o.startswith(h)]
        return cmap[found[0]][: len(h)].encode() if len(found) == 1 else h.encode()

    # filter-repo maps a hash only to a commit it has already rewritten, so a message naming a
    # later one keeps it: each hash is the old one or its mapping, and every other byte is equal.
    def same_but_hashes(want, got):
        w, g = HASH.split(want), HASH.split(got)
        wh, gh = HASH.findall(want), HASH.findall(got)
        return w == g and len(wh) == len(gh) and all(y in (x, mapped(x)) for x, y in zip(wh, gh))

    def scrub(m):
        for literal, replacement in literals:
            m = m.replace(literal, replacement)
        for regex, replacement in regexes:
            m = regex.sub(replacement, m)
        return m

    fails = []
    n = same_tree = dropped = changed_at = msg_hash = msg_expr = 0
    for a, b in cmap.items():
        n += 1
        fields = git(new, "diff-tree", "-r", "-z", "--no-renames", "--no-commit-id", a, b, env=env).split(b"\0")
        if fields == [b""]:
            same_tree += 1
        # -z: each change is its ":<modes> <shas> <status>" field, then its path.
        for meta, raw in zip(fields[0:-1:2], fields[1::2]):
            status = meta.split()[-1].decode()
            path = path_of(raw)
            if status == "D" and matches(path, rs):
                dropped += 1
            elif status == "M" and any(path.endswith(s) for s in changed):
                changed_at += 1
            else:
                shown = raw.decode("utf-8", "backslashreplace")
                fails.append(f"{a}: unexpected {status} {shown}")
        fo, mo = parse_commit(git(new, "cat-file", "commit", a, env=env))
        fn, mn = parse_commit(git(new, "cat-file", "commit", b))
        for k in ("author", "committer"):
            if fo[k] != fn[k]:
                fails.append(f"{a}: {k} differs")
        if [cmap.get(p, p) for p in fo["parent"]] != fn["parent"]:
            fails.append(f"{a}: parents differ")
        scrubbed = scrub(mo)
        if not same_but_hashes(scrubbed, mn):
            fails.append(f"{a}: the message is not the old one through the message expressions and the commit map")
        elif scrubbed != mo:
            msg_expr += 1
        elif mn != mo:
            msg_hash += 1
    left = {p for p in history_paths(new, "--branches") if matches(p, rs)}
    pulls = [r for r in git(old, "for-each-ref", "--format=%(refname)", "refs/pull/").decode().splitlines() if r]
    pulls_dropped = sum(1 for r in pulls if any(matches(p, rs) for p in history_paths(old, r)))
    print(f"commits compared: {n}")
    print(f"commits whose tree is unchanged: {same_tree}")
    print(f"dropped paths, summed over commits: {dropped}")
    print(f"callback-changed paths, summed over commits: {changed_at}")
    print(f"messages changed only by hash rewriting: {msg_hash}")
    print(f"messages changed by the message expressions: {msg_expr}")
    print(f"drop-list paths left in the new history: {len(left)}")
    print(f"pull refs whose history holds a dropped path: {pulls_dropped} of {len(pulls)}")
    print(f"failures: {len(fails)}")
    for f in fails[:20]:
        print("  " + f)
    sys.exit(1 if fails or left or not n else 0)


if __name__ == "__main__":
    main()
