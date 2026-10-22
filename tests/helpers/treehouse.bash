# Fake treehouse lease and return commands for tests: load with `load helpers/treehouse`.
# They behave like Conventioner's scripts/th-lease.sh and scripts/th-return.sh over treehouse v2.0.0:
# the lease hands out the next free pre-made worktree (detached), the return detaches a clean
# worktree and frees it, and answers a dirty one with treehouse's prompt, aborted, leaving it leased.
# shellcheck shell=bash

# fake_pool_commands <primary>: write the fake lease and return commands into <primary>'s
# scripts/ (untracked there, so no worktree sees them). Each logs {cwd, args} per call to $STUB_CALLS/<file name>.log, read with
# stub_calls. The lease hands out the first line of $BATS_TEST_TMPDIR/free; the return puts a
# clean worktree back at its end.
fake_pool_commands() {
  local primary=$1
  mkdir -p "$primary/scripts"
  cat >"$primary/scripts/th-lease.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args "$@" >>"$STUB_CALLS/${0##*/}.log"
free=$BATS_TEST_TMPDIR/free
echo "🌳 Setting up worktree..." >&2
path=$(head -n 1 "$free")
if [[ -z $path ]]; then
  echo "all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
  exit 1
fi
sed -i 1d "$free"
echo "[setup] installing node_modules (pre-warm)" >&2
echo "$path"
SH
  cat >"$primary/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args "$@" >>"$STUB_CALLS/${0##*/}.log"
if [[ -n $(git -C "$1" status --porcelain) ]]; then
  echo "Worktree has uncommitted changes. Clean and return? [Y/n] 🌳 Aborted."
  exit 0
fi
git -C "$1" switch -q --detach
echo "$1" >>"$BATS_TEST_TMPDIR/free"
echo "🌳 Worktree returned to pool."
SH
  chmod +x "$primary/scripts/th-lease.sh" "$primary/scripts/th-return.sh"
}
