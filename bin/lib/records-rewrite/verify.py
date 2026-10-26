#!/usr/bin/env python3
"""Check a rewritten repository against the one it was rewritten from, commit by commit.

Usage: python3 verify.py <old-git-dir> <new-git-dir> <drop-list> [--changed <path-suffix>]...

T56's byte-identical check, run by team-records-rewrite. For every line of
<new>/filter-repo/commit-map (old sha, new sha), the old commit read through <old>'s objects as an
alternate, so <new> is never written:
  - the trees: every difference between the old and the new tree is a deletion of a path the drop
    list matches (so every kept file is byte-identical, same blob and mode, at every commit that
    had it), except a modification of a path ending with a --changed suffix (a callback's);
  - the metadata: author and committer (names, emails, dates) are equal, and the parents are the
    old parents through the commit map;
  - the messages: equal, or changed only by rewritten hashes or by the message expressions, which
    are counted.
Then no path the drop list matches is left anywhere in <new>'s branches, and the refs/pull/* of
<old> whose history holds a dropped path are counted (GitHub Support asks for that number).
Prints counts only, never a path's content, and exits 1 on any failure or path left.
"""
import fnmatch
import os
import re
import subprocess
import sys


def rules(path):
    out = []
    for line in open(path):
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


def git(repo, *args, env=None):
    return subprocess.run(["git", "--git-dir", repo, *args], capture_output=True, text=True, check=True,
                          env=env).stdout


def parse_commit(raw):
    head, _, msg = raw.partition("\n\n")
    fields = {"parent": []}
    for line in head.split("\n"):
        if line.startswith(" "):
            continue  # continuation of gpgsig
        k, _, v = line.partition(" ")
        if k == "parent":
            fields["parent"].append(v)
        else:
            fields[k] = v
    return fields, msg


def history_paths(repo, *revs):
    out = git(repo, "log", *revs, "--format=", "--name-only", "--no-renames", "-m", "--full-history")
    return {p for p in out.splitlines() if p}


def main():
    args = sys.argv[1:]
    changed = []
    while "--changed" in args:
        i = args.index("--changed")
        changed.append(args[i + 1])
        del args[i : i + 2]
    if len(args) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    old, new, drop = (os.path.abspath(a) for a in args)
    rs = rules(drop)
    # The old commits and trees, readable in <new> without fetching them into it.
    env = dict(os.environ, GIT_ALTERNATE_OBJECT_DIRECTORIES=os.path.join(old, "objects"))
    cmap = {}
    for line in open(os.path.join(new, "filter-repo", "commit-map")):
        a, b = line.split()
        if a == "old":
            continue
        cmap[a] = b
    fails = []
    n = same_tree = dropped = changed_at = msg_hash = msg_other = 0
    for a, b in cmap.items():
        n += 1
        diff = git(new, "diff-tree", "-r", "--no-renames", "--no-commit-id", a, b, env=env)
        if not diff:
            same_tree += 1
        for line in diff.splitlines():
            meta, path = line.split("\t", 1)
            status = meta.split()[-1]
            if status == "D" and matches(path, rs):
                dropped += 1
            elif status == "M" and any(path.endswith(s) for s in changed):
                changed_at += 1
            else:
                fails.append(f"{a}: unexpected {status} {path}")
        fo, mo = parse_commit(git(new, "cat-file", "commit", a, env=env))
        fn, mn = parse_commit(git(new, "cat-file", "commit", b))
        for k in ("author", "committer"):
            if fo[k] != fn[k]:
                fails.append(f"{a}: {k} differs")
        if [cmap.get(p, p) for p in fo["parent"]] != fn["parent"]:
            fails.append(f"{a}: parents differ")
        if mo != mn:
            # Equal once every old hash the message names is mapped to its new one?
            def remap(m):
                return re.sub(r"\b[0-9a-f]{7,40}\b", lambda x: next(
                    (cmap[o][: len(x.group())] for o in cmap if o.startswith(x.group())), x.group())
                    if len(x.group()) < 40 else cmap.get(x.group(), x.group()), m)
            if remap(mo) == mn:
                msg_hash += 1
            else:
                msg_other += 1
    left = {p for p in history_paths(new, "--branches") if matches(p, rs)}
    pulls = [r for r in git(old, "for-each-ref", "--format=%(refname)", "refs/pull/").splitlines() if r]
    pulls_dropped = sum(1 for r in pulls if any(matches(p, rs) for p in history_paths(old, r)))
    print(f"commits compared: {n}")
    print(f"commits whose tree is unchanged: {same_tree}")
    print(f"dropped paths, summed over commits: {dropped}")
    print(f"callback-changed paths, summed over commits: {changed_at}")
    print(f"messages changed only by hash rewriting: {msg_hash}")
    print(f"messages changed otherwise (message expressions): {msg_other}")
    print(f"drop-list paths left in the new history: {len(left)}")
    print(f"pull refs whose history holds a dropped path: {pulls_dropped} of {len(pulls)}")
    print(f"failures: {len(fails)}")
    for f in fails[:20]:
        print("  " + f)
    sys.exit(1 if fails or left or not n else 0)


if __name__ == "__main__":
    main()
