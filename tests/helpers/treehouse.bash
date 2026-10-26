# A fake treehouse pool for tests: load with `load helpers/treehouse`.
# Its lease and return commands behave like Conventioner's scripts/th-lease.sh and
# scripts/th-return.sh over treehouse v3 (the pin), and a stub treehouse answers `status --json`
# from the same state, kept in $BATS_TEST_TMPDIR: pool (every slot, one path per line), free (the
# slots the lease hands out, in order) and leases (one "<path><TAB><holder>" per leased slot).
# The lease hands out the first free slot, leased to its first argument, then runs
# $BATS_TEST_TMPDIR/prewarm (Bash, when present) in it, as the project's pre-warm would. Unlike
# treehouse's own get, it hands out a slot that is already dirty, as a lease command that leases
# a slot in place could, so a test can make one. The return frees a clean slot, detached; a dirty
# one it keeps leased and exits 3, as treehouse v3 does with no terminal to ask, unless given
# --force, which cleans it first; with --if-lease-holder <holder> it returns only a slot leased
# to <holder>.
# shellcheck shell=bash

# fake_pool_commands <primary>: write the fake lease and return commands into <primary>'s
# scripts/ (untracked there, so no worktree sees them), and stub treehouse. The pool is the slots
# $BATS_TEST_TMPDIR/free lists when called, unless $BATS_TEST_TMPDIR/pool already lists them.
# Each command logs {cwd, args} per call to $STUB_CALLS/<file name>.log, read with stub_calls.
fake_pool_commands() {
  local primary=$1
  [[ -e $BATS_TEST_TMPDIR/pool ]] || cp "$BATS_TEST_TMPDIR/free" "$BATS_TEST_TMPDIR/pool"
  touch "$BATS_TEST_TMPDIR/leases"
  mkdir -p "$primary/scripts"
  cat >"$primary/scripts/th-lease.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args -- "$@" >>"$STUB_CALLS/${0##*/}.log"
free=$BATS_TEST_TMPDIR/free
echo "🌳 Setting up worktree..." >&2
path=$(head -n 1 "$free")
if [[ -z $path ]]; then
  echo "all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
  exit 1
fi
sed -i 1d "$free"
printf '%s\t%s\n' "$path" "${1:-agent}" >>"$BATS_TEST_TMPDIR/leases"
echo "[setup] installing node_modules (pre-warm)" >&2
if [[ -e $BATS_TEST_TMPDIR/prewarm ]]; then (cd "$path" && source "$BATS_TEST_TMPDIR/prewarm") >&2; fi
echo "$path"
SH
  cat >"$primary/scripts/th-return.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" '{cwd: $cwd, args: $ARGS.positional}' --args -- "$@" >>"$STUB_CALLS/${0##*/}.log"
leases=$BATS_TEST_TMPDIR/leases path='' force='' holder=''
while (($#)); do
  case $1 in
    --force) force=1 ;;
    --if-lease-holder) holder=$2 && shift ;;
    *) [[ -n $path ]] || path=$1 ;;
  esac
  shift
done
leased=$(awk -F '\t' -v p="$path" '$1 == p { print $2 }' "$leases")
if [[ -n $holder && -z $leased ]]; then
  echo "failed to return worktree: lease precondition failed: worktree $path is not leased" >&2
  exit 1
fi
if [[ -n $holder && $leased != "$holder" ]]; then
  echo "failed to return worktree: lease precondition failed: lease holder does not match worktree $path" >&2
  exit 1
fi
if [[ -n $(git -C "$path" status --porcelain) ]]; then
  if [[ -z $force ]]; then
    echo "Worktree has uncommitted changes. Clean and return? [Y/n] 🌳 worktree not returned: it has uncommitted changes and the confirmation could not be answered (stdin reached EOF); prune will not reclaim this slot. Use treehouse return --force '$path' to clean and return it" >&2
    exit 3
  fi
  git -C "$path" reset -q --hard
  git -C "$path" clean -q -fd
fi
git -C "$path" switch -q --detach
awk -F '\t' -v p="$path" '$1 != p' "$leases" >"$leases.next" && mv "$leases.next" "$leases"
echo "$path" >>"$BATS_TEST_TMPDIR/free"
echo "🌳 Worktree returned to pool."
SH
  chmod +x "$primary/scripts/th-lease.sh" "$primary/scripts/th-return.sh"
  stub_command treehouse
  stub_script treehouse <<'SH'
[[ $* == 'status --json' ]] || { echo "treehouse stub: unplanned call: $*" >&2; exit 64; }
while IFS= read -r path; do
  [[ -d $path ]] || continue
  holder=$(awk -F '\t' -v p="$path" '$1 == p { print $2 }' "$BATS_TEST_TMPDIR/leases")
  status=available
  if [[ -n $holder ]]; then
    status=leased
  elif [[ -n $(git -C "$path" status --porcelain) ]]; then
    status=dirty
  fi
  jq -cn --arg path "$path" --arg status "$status" --arg holder "$holder" \
    --arg branch "$(git -C "$path" symbolic-ref -q --short HEAD || true)" \
    '{name: ($path | split("/") | .[-2]), path: $path, status: $status, branch: $branch, lease_holder: $holder}'
done < <(cut -f1 "$BATS_TEST_TMPDIR/leases" | cat "$BATS_TEST_TMPDIR/pool" - | awk 'NF && !seen[$0]++') | jq -cs .
SH
}

# The slots the fake pool leases, one "<path> <holder>" per line.
pool_leases() {
  tr '\t' ' ' <"$BATS_TEST_TMPDIR/leases"
}

# The arguments of each call to the fake pool command <file name>, one line per call.
pool_calls() {
  stub_calls "$1" | jq -r '.args | join(" ")'
}
