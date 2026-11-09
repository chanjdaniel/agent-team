#!/usr/bin/env bash
# The review-a-code-diff case's workspace: the one file of a made-up shell tool that the prompt's
# diff changes, and no task directory, so nothing in it is a spec.
set -euo pipefail

mkdir -p lib

cat >lib/notecat.sh <<'EOF'
# notecat's functions.

# The notes directory: $NOTECAT_DIR when set, else ~/notes.
notes_dir() {
  echo "${NOTECAT_DIR:-$HOME/notes}"
}

# One note's text.
show_note() {
  cat "$(notes_dir)/$1.txt"
}
EOF
