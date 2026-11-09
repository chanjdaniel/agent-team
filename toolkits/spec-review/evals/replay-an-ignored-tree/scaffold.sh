#!/usr/bin/env bash
# The replay-an-ignored-tree case's workspace: a git checkout whose .gitignore excludes .scratch/,
# as a team worktree's does, holding a replay's copies under it: an archived spec in
# .scratch/task/replay/T9/task/ and its project, notecat, in .scratch/task/replay/T9/tree/, a
# plain copy with no .git. The spec extends rotate_notes, which the tree has in a file no line
# names, so only a search of the tree finds it, and calls prune_notes, which the tree lacks.
set -euo pipefail

cat >.gitignore <<'EOF'
.scratch/
EOF

cat >CLAUDE.md <<'EOF'
# replay worktree

The checkout a replay runs in; the projects it replays are copied under `.scratch/`.
EOF

git init -q
git add -A
git -c user.name=eval -c user.email=eval@example.invalid commit -q -m "worktree"

task=.scratch/task/replay/T9/task
tree=.scratch/task/replay/T9/tree
mkdir -p "$task/tickets" "$tree/bin" "$tree/lib"

cat >"$tree/CLAUDE.md" <<'EOF'
# notecat

A small shell tool that lists and rotates plain-text notes.

- `bin/notecat` is the command; it sources the files in `lib/`, which hold every function.
- Bash 5, `set -euo pipefail`, every variable quoted.
EOF

cat >"$tree/bin/notecat" <<'EOF'
#!/usr/bin/env bash
# Usage: notecat list | notecat rotate
set -euo pipefail
for lib in "$(dirname "${BASH_SOURCE[0]}")"/../lib/*.sh; do source "$lib"; done

case ${1:-} in
  list) list_notes ;;
  rotate) rotate_notes ;;
  *) echo "usage: notecat list | notecat rotate" >&2; exit 2 ;;
esac
EOF
chmod +x "$tree/bin/notecat"

cat >"$tree/lib/notecat.sh" <<'EOF'
# The notes directory: $NOTECAT_DIR when set, else ~/notes.
notes_dir() {
  echo "${NOTECAT_DIR:-$HOME/notes}"
}

# Each note's name, one per line.
list_notes() {
  local note
  for note in "$(notes_dir)"/*.txt; do
    [[ -e $note ]] || continue
    basename "$note" .txt
  done
}
EOF

cat >"$tree/lib/keep.sh" <<'EOF'
# Keeps the newest ten notes in the notes directory and moves the rest to old/.
rotate_notes() {
  local note kept=0
  mkdir -p "$(notes_dir)/old"
  while IFS= read -r note; do
    if ((kept < 10)); then
      kept=$((kept + 1))
    else
      mv "$note" "$(notes_dir)/old/"
    fi
  done < <(ls -t "$(notes_dir)"/*.txt)
}
EOF

cat >"$task/spec.md" <<'EOF'
# T9 spec: Rotate by count

## Problem Statement

`notecat rotate` always keeps ten notes, and old notes pile up in `old/`.

## Solution

`notecat rotate --keep <n>` keeps the newest `n` notes, and rotating then empties `old/` of notes older than a year.

## Implementation Decisions

- Ticket 01 extends `rotate_notes` with the count, read from `--keep`; with no `--keep` it keeps ten, as today.
- After rotating, `rotate_notes` calls `prune_notes` in `lib/notecat.sh`, which deletes the notes in `old/` older than a year.
- A value that is not a whole number exits 2 with the usage line.

### Left to the builder: none
EOF

cat >"$task/scope.txt" <<'EOF'
bin/notecat
EOF

cat >"$task/tickets/01-keep-count.md" <<'EOF'
# 01: rotate --keep

**What to build:** `notecat rotate --keep <n>` keeps the newest `n` notes, then prunes `old/`.

Blocked by: None

## Acceptance

- [ ] The function the spec extends takes the count.
- [ ] Rotating prunes `old/` as the spec says.
- [ ] A value that is not a whole number exits 2 with the usage line.
EOF
