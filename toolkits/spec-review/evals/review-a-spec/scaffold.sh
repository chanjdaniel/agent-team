#!/usr/bin/env bash
# The review-a-spec case's workspace: a small made-up shell tool, notecat, and a planner's task
# directory for it in .scratch/task/ with two planted faults. Ticket 02 leaves open where its new
# setting is read from (notecat reads one setting from the environment and another from its config
# file, and the ticket picks neither), and spec.md's line on filter_notes extends a function
# lib/notecat.sh does not have and no ticket creates.
set -euo pipefail

mkdir -p bin lib tests .scratch/task/tickets

cat >CLAUDE.md <<'EOF'
# notecat

A small shell tool that lists and shows plain-text notes.

- `bin/notecat` is the command; it sources `lib/notecat.sh`, which holds every function.
- Notes are `*.txt` files in the notes directory.
- Tests are bats files in `tests/`, run with `bats tests`.
- Bash 5, `set -euo pipefail`, every variable quoted.
EOF

cat >bin/notecat <<'EOF'
#!/usr/bin/env bash
# Usage: notecat list | notecat show <name>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/notecat.sh"

case ${1:-} in
  list) list_notes ;;
  show) show_note "${2:?usage: notecat show <name>}" ;;
  *) echo "usage: notecat list | notecat show <name>" >&2; exit 2 ;;
esac
EOF
chmod +x bin/notecat

cat >lib/notecat.sh <<'EOF'
# notecat's functions.

# The notes directory: $NOTECAT_DIR when set, else ~/notes.
notes_dir() {
  echo "${NOTECAT_DIR:-$HOME/notes}"
}

# The editor show_note opens with -e: the config file's editor= line, else $EDITOR.
config_editor() {
  local config=$HOME/.config/notecat/config
  if [[ -f $config ]] && grep -q '^editor=' "$config"; then
    sed -n 's/^editor=//p' "$config"
  else
    echo "${EDITOR:-vi}"
  fi
}

# Each note's name, one per line, in the order the directory gives them.
list_notes() {
  local note
  for note in "$(notes_dir)"/*.txt; do
    [[ -e $note ]] || continue
    basename "$note" .txt
  done
}

# One note's text.
show_note() {
  cat "$(notes_dir)/$1.txt"
}
EOF

cat >tests/notecat.bats <<'EOF'
setup() {
  export NOTECAT_DIR=$BATS_TEST_TMPDIR/notes
  mkdir -p "$NOTECAT_DIR"
  echo one >"$NOTECAT_DIR/a.txt"
  echo two >"$NOTECAT_DIR/b.txt"
}

@test "list names every note" {
  run bin/notecat list
  [ "$output" = "$(printf 'a\nb')" ]
}

@test "show prints a note" {
  run bin/notecat show b
  [ "$output" = two ]
}
EOF

cat >.scratch/task/spec.md <<'EOF'
# T9 spec: Sorted note lists

## Problem Statement

`notecat list` prints notes in whatever order the directory gives them, so a user with many notes cannot find the newest one.

## Solution

`notecat list` takes `--sort name` or `--sort date`, and a user can set the order it uses when no `--sort` is given.

## Implementation Decisions

- `--sort name` sorts by note name, `--sort date` by modification time, newest first.
- `list` passes its notes through `filter_notes` in `lib/notecat.sh`, which ticket 01 extends with the sort.
- An unknown `--sort` value exits 2 with the usage line.
- With no `--sort` and no default set, `list` keeps today's order.

### Left to the builder: none

## Testing Decisions

- `tests/notecat.bats` gains one test per order and one for an unknown value (01), and one for the default (02).
EOF

cat >.scratch/task/scope.txt <<'EOF'
bin/notecat
lib/notecat.sh
tests/notecat.bats
EOF

cat >.scratch/task/tickets/01-sort-flag.md <<'EOF'
# 01: The --sort flag

**What to build:** `notecat list --sort name` and `notecat list --sort date` print the notes in that order.

Blocked by: None

## Acceptance

- [ ] `--sort name` and `--sort date` sort as `spec.md` says, in the function the spec names.
- [ ] An unknown value exits 2 with the usage line.
- [ ] `tests/notecat.bats` has a test for each.
EOF

cat >.scratch/task/tickets/02-default-order.md <<'EOF'
# 02: A default order

**What to build:** a user can set the order `notecat list` uses when no `--sort` is given, so they need not pass it each time.

Blocked by: 01

## Acceptance

- [ ] A new setting holds the default order, `name` or `date`.
- [ ] `--sort` on the command line wins over the setting.
- [ ] `tests/notecat.bats` has a test for the default.
EOF
