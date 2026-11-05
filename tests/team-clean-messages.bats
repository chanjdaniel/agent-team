#!/usr/bin/env bats
# team-clean-messages and the library's attribution matcher, on real git histories: a project
# proj based on dev, with a task worktree at $HOME/slots/proj/1 on feat/T7-thing.

load helpers/common

setup() {
  sandbox
  primary=$(make_repo proj dev)
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  wt=$HOME/slots/proj/1
  git -C "$primary" worktree add -q --no-track -b feat/T7-thing "$wt" origin/dev
  when=1700000000
}

# Commit in the worktree with a distinct author and committer and fixed dates, one hour apart
# per commit: commit <message> [<file>] (no file: a commit whose only change is its message).
commit() {
  when=$((when + 3600))
  if [[ -n ${2:-} ]]; then
    echo "$1" >>"$wt/$2"
    git -C "$wt" add "$2"
  fi
  GIT_AUTHOR_NAME="Ada Author" GIT_AUTHOR_EMAIL=ada@example.invalid GIT_AUTHOR_DATE="$when +0200" \
    GIT_COMMITTER_NAME="Cy Committer" GIT_COMMITTER_EMAIL=cy@example.invalid GIT_COMMITTER_DATE="$((when + 60)) -0500" \
    git -C "$wt" commit -q --allow-empty --cleanup=verbatim -m "$1"
}

# The raw commit object of <rev> in the worktree.
raw() { git -C "$wt" cat-file commit "$1"; }

# The message of <rev>, exactly as stored.
message() { raw "$1" | sed '1,/^$/d'; }

# Every header of <rev> but its parents: tree, author, committer.
headers() { raw "$1" | sed '/^$/q' | grep -v '^parent '; }

# Run the library's <function> with stdin from the message <text>.
library() {
  run bash -c 'source "$1/bin/lib/team.sh"; "$2"' _ "$REPO_ROOT" "$1" <<<"$2"
}

# The branch's history and the ledger, to prove a refusal changed nothing.
remember_before() {
  before=$(git -C "$wt" for-each-ref; cat "$TEAM_HOME/ledger.jsonl")
}
assert_unchanged() {
  assert_equal "$(git -C "$wt" for-each-ref; cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

attributed=$'feat: two\n\nBody line.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nCo-authored-by: Grace Human <grace@example.invalid>\nClaude-Session: 0785a670\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)\n'

# A co-author whose name is the word Claude is taken for the agent, as the spec says: a human
# Claude loses the line.
@test "the matcher finds the attribution lines case-insensitively and keeps human co-authors" {
  local text
  text=$(printf '%s\n' \
    'fix: x' '' \
    'Co-Authored-By: Claude <noreply@anthropic.com>' \
    'co-authored-by: claude-code <x@example.invalid>' \
    'CO-AUTHORED-BY: Some Bot <NOREPLY@ANTHROPIC.COM>' \
    'Co-Authored-By: Anthropic Assistant <a@example.invalid>' \
    'Co-Authored-By: Grace Human <grace@example.invalid>' \
    'Co-Authored-By: Claudette Painter <claudette@example.invalid>' \
    'Co-Authored-By: Claude Monet <monet@example.invalid>' \
    'claude-session: abc123' \
    'Generated with Claude Code' \
    '🤖 Generated with [Claude Code](https://claude.com/claude-code)' \
    '  generated with claude code (https://claude.ai/code)' \
    'This change was generated with Claude Code help.' \
    'Claude-Session is mentioned here.')
  library attribution_lines "$text"
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '%s\n' \
    'Co-Authored-By: Claude <noreply@anthropic.com>' \
    'co-authored-by: claude-code <x@example.invalid>' \
    'CO-AUTHORED-BY: Some Bot <NOREPLY@ANTHROPIC.COM>' \
    'Co-Authored-By: Anthropic Assistant <a@example.invalid>' \
    'Co-Authored-By: Claude Monet <monet@example.invalid>' \
    'claude-session: abc123' \
    'Generated with Claude Code' \
    '🤖 Generated with [Claude Code](https://claude.com/claude-code)' \
    '  generated with claude code (https://claude.ai/code)')"
}

@test "the matcher strips the lines and the blank lines they leave at the end, nothing else" {
  library strip_attribution "$attributed"
  assert_equal "$status" 0
  assert_equal "$output" $'feat: two\n\nBody line.\n\nCo-authored-by: Grace Human <grace@example.invalid>'

  library strip_attribution $'feat: one\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n'
  assert_equal "$output" 'feat: one'

  library attribution_lines $'feat: clean\n\nBody.'
  assert_equal "$status" 0
  assert_equal "$output" ''
}

@test "--check lists each offending commit and line, exits 1 and writes nothing" {
  commit "feat: one" a
  commit "$attributed" b
  commit $'docs: message only\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  remember_before
  run_bin -1 team-clean-messages "$wt" --check
  local two three
  two=$(git -C "$wt" rev-parse --short HEAD~1) three=$(git -C "$wt" rev-parse --short HEAD)
  assert_equal "$output" "$two feat: two
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: 0785a670
  🤖 Generated with [Claude Code](https://claude.com/claude-code)
$three docs: message only
  Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_unchanged
}

@test "--check exits 0 on a clean range" {
  commit "feat: one" a
  commit $'feat: two\n\nCo-Authored-By: Grace Human <grace@example.invalid>' b
  run_bin -0 --separate-stderr team-clean-messages --check "$wt"
  assert_equal "$output" ""
  assert_contains "$stderr" "nothing to clean: the 2 commits of origin/dev..feat/T7-thing carry no attribution lines"
}

@test "the range is origin/<base>..HEAD after a fetch, the base from the registry" {
  # An attributed commit that is already on origin's dev, behind a stale remote-tracking ref.
  commit $'feat: on dev\n\nCo-Authored-By: Claude <noreply@anthropic.com>' a
  local stale
  stale=$(git -C "$wt" rev-parse origin/dev)
  git -C "$wt" push -q origin HEAD:dev
  git -C "$wt" update-ref refs/remotes/origin/dev "$stale"
  # main is not the base: its attributed commit is not in the range either way.
  git -C "$primary" checkout -q -b main
  git -C "$primary" commit -q --allow-empty -m $'chore: main\n\nClaude-Session: x'
  git -C "$primary" push -q origin main
  commit "feat: mine" b
  run_bin -0 --separate-stderr team-clean-messages "$wt" --check
  assert_contains "$stderr" "nothing to clean: the 1 commit of origin/dev..feat/T7-thing"
  assert_equal "$(git -C "$wt" rev-parse origin/dev)" "$(git -C "$wt" rev-parse HEAD~1)"
}

@test "a rewrite changes only messages, keeps trees, people and dates, and moves the branch" {
  commit "feat: one" a
  commit "$attributed" b
  commit $'docs: message only\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  commit "feat: four" c
  git -C "$wt" push -q origin feat/T7-thing
  local old new push old_shas=() new_shas=() i
  old=$(git -C "$wt" rev-parse HEAD)
  mapfile -t old_shas < <(git -C "$wt" rev-list --reverse origin/dev..HEAD)

  run_bin -0 --separate-stderr team-clean-messages "$wt"
  new=$(git -C "$wt" rev-parse HEAD)
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing:$old origin feat/T7-thing"
  push=$output
  assert_contains "$stderr" "rewrote the messages of 2 of 4 commits"
  [[ $new != "$old" ]]
  assert_equal "$(git -C "$wt" symbolic-ref --short HEAD)" feat/T7-thing

  mapfile -t new_shas < <(git -C "$wt" rev-list --reverse origin/dev..HEAD)
  assert_equal "${#new_shas[@]}" 4
  # The commit before the first offender is kept as it was.
  assert_equal "${new_shas[0]}" "${old_shas[0]}"
  for i in 0 1 2 3; do
    assert_equal "$(headers "${new_shas[i]}")" "$(headers "${old_shas[i]}")"
  done
  assert_equal "$(message "${new_shas[1]}")" $'feat: two\n\nBody line.\n\nCo-authored-by: Grace Human <grace@example.invalid>'
  assert_equal "$(message "${new_shas[2]}")" 'docs: message only'
  assert_equal "$(message "${new_shas[3]}")" "$(message "${old_shas[3]}")"
  # The message-only commit is still one: its tree is its parent's.
  assert_equal "$(git -C "$wt" rev-parse "${new_shas[2]}^{tree}")" "$(git -C "$wt" rev-parse "${new_shas[1]}^{tree}")"
  git -C "$wt" diff --quiet "$old" "$new"
  assert_equal "$(git -C "$wt" status --porcelain)" ""

  # It never pushes.
  assert_equal "$(git -C "$primary" ls-remote origin refs/heads/feat/T7-thing | cut -f1)" "$old"
  assert_equal "$(jq -c 'del(.ts)' "$TEAM_HOME/ledger.jsonl")" \
    "{\"task\":\"T7\",\"event\":\"history-rewritten\",\"project\":\"proj\",\"branch\":\"feat/T7-thing\",\"old_head\":\"$old\",\"head\":\"$new\"}"
  run_bin -0 team-log --check

  # The printed push is the one to run.
  run bash -c "cd '$wt' && $push"
  assert_equal "$status" 0
  assert_equal "$(git -C "$primary" ls-remote origin refs/heads/feat/T7-thing | cut -f1)" "$new"
  run_bin -0 team-clean-messages "$wt" --check
}

@test "a rewrite never signs, whatever the git config says" {
  git config --global commit.gpgsign true
  git config --global gpg.program false
  git -C "$wt" -c commit.gpgsign=false commit -q --allow-empty -m $'feat: one\n\nClaude-Session: x'
  run_bin -0 team-clean-messages "$wt"
  assert_equal "$(message HEAD)" 'feat: one'
}

@test "nothing to clean: exit 0, the branch untouched and no ledger line" {
  commit "feat: one" a
  commit $'feat: two\n\nCo-Authored-By: Grace Human <grace@example.invalid>' b
  remember_before
  local reflog
  reflog=$(git -C "$wt" reflog feat/T7-thing)
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" ""
  assert_contains "$stderr" "nothing to clean"
  assert_unchanged
  assert_equal "$(git -C "$wt" reflog feat/T7-thing)" "$reflog"
}

@test "refused, with nothing changed, on a detached HEAD" {
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" checkout -q --detach
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "detached HEAD"
  assert_unchanged
}

@test "refused, with nothing changed, on the base branch and on main" {
  local branch
  git -C "$primary" checkout -q --detach
  for branch in dev main; do
    git -C "$wt" checkout -q -B "$branch" feat/T7-thing
    git -C "$wt" commit -q --allow-empty -m $'feat: one\n\nClaude-Session: x'
    remember_before
    run_bin -1 team-clean-messages "$wt"
    assert_contains "$output" "$branch is the base branch or main"
    assert_unchanged
  done
}

@test "refused, with nothing changed, on a branch that names no task" {
  git -C "$wt" checkout -q -b feat/no-task
  commit $'feat: one\n\nClaude-Session: x' a
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "feat/no-task names no task"
  assert_unchanged
}

@test "refused, with nothing changed, with uncommitted changes" {
  commit $'feat: one\n\nClaude-Session: x' a
  echo change >>"$wt/a"
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "uncommitted changes: changes to tracked files: a"
  assert_unchanged

  git -C "$wt" checkout -q -- a
  echo new >"$wt/untracked"
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "untracked files: untracked"
  assert_unchanged
}

@test "refused, with nothing changed, with a merge commit in the range" {
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" checkout -q -b side origin/dev
  commit "feat: side" b
  git -C "$wt" checkout -q feat/T7-thing
  git -C "$wt" merge -q --no-ff -m "chore: merge side" side
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "a merge commit in origin/dev..feat/T7-thing: $(git -C "$wt" rev-parse --short HEAD)"
  assert_contains "$output" "only a merge of origin/dev"
  assert_unchanged
}

# Advance origin's dev by one commit and merge it into the worktree's branch, with the message
# <message> when given: merge_base [<message>]. Sets merged to the base commit it merged.
merge_base() {
  when=$((when + 3600))
  echo "$when" >>"$primary/on-dev"
  git -C "$primary" add on-dev
  git -C "$primary" commit -q -m "chore: base moves"
  git -C "$primary" push -q origin dev
  git -C "$wt" fetch -q origin dev
  merged=$(git -C "$wt" rev-parse origin/dev)
  GIT_AUTHOR_NAME="Ada Author" GIT_AUTHOR_EMAIL=ada@example.invalid GIT_AUTHOR_DATE="$when +0200" \
    GIT_COMMITTER_NAME="Cy Committer" GIT_COMMITTER_EMAIL=cy@example.invalid GIT_COMMITTER_DATE="$((when + 60)) -0500" \
    git -C "$wt" merge -q --no-ff -m "${1:-Merge remote-tracking branch origin/dev}" origin/dev
}

# The parents of <rev>, one line.
parents() { git -C "$wt" rev-list --parents -n 1 "$1" | cut -d' ' -f2-; }

@test "a range holding a merge of the base is rewritten keeping its parents, its tree unchanged" {
  commit $'feat: one\n\nClaude-Session: x' a
  merge_base
  commit $'feat: two\n\nClaude-Session: y' b
  local old old_merge new
  old=$(git -C "$wt" rev-parse HEAD)
  old_merge=$(git -C "$wt" rev-parse HEAD~1)
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_contains "$stderr" "rewrote the messages of 2 of 3 commits"
  new=$(git -C "$wt" rev-parse HEAD)
  [[ $new != "$old" ]]
  assert_equal "$(git -C "$wt" rev-parse "$new^{tree}")" "$(git -C "$wt" rev-parse "$old^{tree}")"
  assert_equal "$(git -C "$wt" rev-list --count origin/dev..HEAD)" 3
  # The rebuilt merge still merges the same base commit, on the rebuilt commit before it.
  assert_equal "$(parents HEAD~1)" "$(git -C "$wt" rev-parse HEAD~2) $merged"
  [[ $(git -C "$wt" rev-parse HEAD~1) != "$old_merge" ]]
  assert_equal "$(headers HEAD~1)" "$(headers "$old_merge")"
  assert_equal "$(message HEAD~1)" "$(message "$old_merge")"
  assert_equal "$(message HEAD~2)" 'feat: one'
  assert_equal "$(message HEAD)" 'feat: two'
  assert_equal "$(parents HEAD~2)" "$(parents "$old~2")"
  git -C "$wt" merge-base --is-ancestor origin/dev HEAD
  run_bin -0 team-clean-messages "$wt" --check
}

@test "a merge of the base carrying attribution lines loses them and keeps its parents" {
  commit "feat: one" a
  local first
  first=$(git -C "$wt" rev-parse HEAD)
  merge_base $'chore: merge dev\n\nClaude-Session: x'
  run_bin -0 team-clean-messages "$wt"
  assert_equal "$(message HEAD)" 'chore: merge dev'
  assert_equal "$(parents HEAD)" "$first $merged"
}

@test "a merge of the base before the first offender stays the commit it was" {
  commit "feat: one" a
  merge_base
  local kept
  kept=$(git -C "$wt" rev-parse HEAD)
  commit $'feat: two\n\nClaude-Session: x' b
  run_bin -0 team-clean-messages "$wt"
  assert_equal "$(git -C "$wt" rev-parse HEAD~1)" "$kept"
}

@test "the branch does not move when a rebuilt merge's parents differ" {
  commit $'feat: one\n\nClaude-Session: x' a
  merge_base
  remember_before
  # commit-tree is handed only the first parent of each commit.
  wrap_git <<'SH'
if [[ " $* " == *" commit-tree "* ]]; then
  args=() seen=''
  while (($#)); do
    if [[ $1 == -p ]]; then
      if [[ -n $seen ]]; then shift 2; continue; fi
      seen=1
    fi
    args+=("$1")
    shift
  done
  set -- "${args[@]}"
fi
SH
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "its parents differ; nothing moved"
  assert_unchanged
}

@test "refused, with nothing changed, in a worktree of an unregistered repo" {
  local other
  other=$(make_repo other)
  git -C "$other" commit -q --allow-empty -m $'feat: one\n\nClaude-Session: x'
  run_bin -1 team-clean-messages "$other" --check
  assert_contains "$output" "is no project's primary checkout in projects.toml"
  run_bin -1 team-clean-messages "$other"
  assert_contains "$output" "is no project's primary checkout in projects.toml"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "refused on a path that is not a git checkout, and on a malformed command line" {
  mkdir "$HOME/plain"
  run_bin -1 team-clean-messages "$HOME/plain"
  assert_contains "$output" "is not a git worktree"
  run_bin -2 team-clean-messages
  run_bin -2 team-clean-messages "$wt" --force
  run_bin -2 team-clean-messages "$wt" "$wt"
}

# A git on PATH before the real one that runs <bash> on the call's arguments, then the real git.
wrap_git() {
  local real
  real=$(command -v git)
  {
    echo '#!/usr/bin/env bash'
    cat
    echo "exec '$real' \"\$@\""
  } >"$BATS_TEST_TMPDIR/stubs/git"
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
}

@test "the branch does not move when a rebuilt commit's tree differs" {
  commit "feat: one" a
  commit $'feat: two\n\nClaude-Session: x' b
  remember_before
  local wrong
  wrong=$(git -C "$wt" rev-parse 'HEAD~1^{tree}')
  # commit-tree is handed the first commit's tree instead of its own.
  wrap_git <<SH
if [[ " \$* " == *" commit-tree "* ]]; then
  args=()
  for a in "\$@"; do [[ \$a =~ ^[0-9a-f]{40}$ && \${#args[@]} -gt 0 && \${args[-1]} == --no-gpg-sign ]] && a=$wrong; args+=("\$a"); done
  set -- "\${args[@]}"
fi
SH
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "its tree differs"
  assert_contains "$output" "nothing moved"
  assert_unchanged
}

@test "the branch moves only from the head it read: a compare-and-swap update" {
  commit $'feat: one\n\nClaude-Session: x' a
  local other real
  real=$(command -v git)
  # Another writer commits on the branch just before the update.
  wrap_git <<SH
if [[ " \$* " == *" update-ref "* ]]; then
  '$real' -C '$wt' commit -q --allow-empty -m "feat: someone else"
fi
SH
  run_bin -1 team-clean-messages "$wt"
  rm "$BATS_TEST_TMPDIR/stubs/git"
  assert_contains "$output" "feat/T7-thing moved while it was being cleaned"
  other=$(git -C "$wt" log -1 --format=%s feat/T7-thing)
  assert_equal "$other" "feat: someone else"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "the branch does not move when a rebuilt commit's author or committer differs" {
  commit $'feat: one\n\nClaude-Session: x' a
  remember_before
  # commit-tree is handed another author's name.
  wrap_git <<'SH'
if [[ " $* " == *" commit-tree "* ]]; then export GIT_AUTHOR_NAME=Mallory; fi
SH
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "its author, committer or headers differ; nothing moved"
  assert_unchanged
}

# Make HEAD's commit look signed: rewrite it with a gpgsig header and move the branch to it.
sign_head() {
  local signed
  signed=$(raw HEAD | sed '/^committer /a gpgsig -----BEGIN PGP SIGNATURE-----\n \n fake\n -----END PGP SIGNATURE-----' |
    git -C "$wt" hash-object -t commit -w --stdin)
  git -C "$wt" update-ref refs/heads/feat/T7-thing "$signed"
}

@test "signed commits: those before the first offender stay as they are, rebuilt ones lose only the signature" {
  commit "feat: one" a
  sign_head
  commit $'feat: two\n\nClaude-Session: x' b
  sign_head
  local first
  first=$(git -C "$wt" rev-parse HEAD~1)
  raw HEAD | grep -q '^gpgsig '
  run_bin -0 team-clean-messages "$wt"
  assert_equal "$(git -C "$wt" rev-parse HEAD~1)" "$first"
  assert_equal "$(message HEAD)" 'feat: two'
  assert_equal "$(raw HEAD | grep -c '^gpgsig ')" 0
}

@test "--check lists the offenders on a detached HEAD too" {
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" checkout -q --detach
  run_bin -1 team-clean-messages "$wt" --check
  assert_equal "$output" "$(git -C "$wt" rev-parse --short HEAD) feat: one
  Claude-Session: x"
}

@test "a commit in another encoding keeps its encoding and its bytes" {
  echo x >"$wt/a"
  git -C "$wt" add a
  git -C "$wt" -c i18n.commitEncoding=ISO-8859-1 commit -q --cleanup=verbatim -m $'feat: caf\xe9\n\nClaude-Session: x'
  run_bin -0 team-clean-messages "$wt"
  raw HEAD | grep -qx 'encoding ISO-8859-1'
  assert_equal "$(message HEAD | od -An -tx1 | tr -d ' \n')" "$(printf 'feat: caf\xe9\n' | od -An -tx1 | tr -d ' \n')"
}

@test "refused, with nothing changed, when the range reaches a root commit" {
  git -C "$wt" checkout -q --orphan feat/T7-orphan
  commit $'feat: unrelated\n\nClaude-Session: x'
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "is a root commit: feat/T7-orphan does not start from origin/dev"
  assert_unchanged
}

@test "the push leases what origin has: no branch, or a head behind the old one" {
  commit $'feat: one\n\nClaude-Session: x' a
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing: origin feat/T7-thing"
  run bash -c "cd '$wt' && $output"
  assert_equal "$status" 0

  local pushed
  pushed=$(git -C "$wt" rev-parse HEAD)
  commit $'feat: two\n\nClaude-Session: y' b
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing:$pushed origin feat/T7-thing"
}

@test "refused, with nothing changed, when origin's branch has commits the worktree lacks" {
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q origin feat/T7-thing
  git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$BATS_TEST_TMPDIR/second" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/second" checkout -q feat/T7-thing
  git -C "$BATS_TEST_TMPDIR/second" commit -q --allow-empty -m "feat: from elsewhere"
  git -C "$BATS_TEST_TMPDIR/second" push -q origin feat/T7-thing
  remember_before
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "origin's feat/T7-thing is at"
  assert_contains "$output" "which this branch does not contain"
  assert_unchanged
}

# The gate's mirror, as no-mistakes init leaves one: a bare repository under ~/.no-mistakes/repos/
# the project names as its no-mistakes remote, with no gate run active; HOME is the sandbox's. The
# push that lands a rewrite is the plain push of a branch origin does not have yet: these tests
# never force a push, so they run the printed step after that one, and never the printed push.
gate_mirror() {
  mirror=$HOME/.no-mistakes/repos/0123456789ab.git
  mkdir -p "$(dirname "$mirror")"
  git init -q --bare -b dev "$mirror"
  git -C "$primary" remote add no-mistakes "$mirror"
  fake_gate
}

# The mirror's refs, to prove a refusal moved none.
mirror_refs() { git --git-dir "$mirror" for-each-ref --format='%(refname) %(objectname)'; }

# Clean the branch's messages, land the rewrite on origin, and print the step it printed.
rewrite_and_land() {
  local printed
  printed=$("$REPO_ROOT/bin/team-clean-messages" "$wt" 2>/dev/null) || return 1
  git -C "$wt" push -q origin feat/T7-thing || return 1
  echo "${printed##*$'\n'}"
}

@test "on a gated branch it prints the mirror's step after the push, and touches no ref of the mirror" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local refs
  refs=$(mirror_refs)
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing: origin feat/T7-thing
$REPO_ROOT/bin/team-clean-messages $wt --clear-gate-lane"
  assert_contains "$stderr" "the gate's mirror still holds the old commits of feat/T7-thing"
  assert_equal "$(mirror_refs)" "$refs"
  assert_equal "$(stub_calls no-mistakes)" ""
}

@test "no mirror's step when the project has no gate or the mirror has no such branch" {
  commit $'feat: one\n\nClaude-Session: x' a
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing: origin feat/T7-thing"

  gate_mirror
  commit $'feat: two\n\nClaude-Session: y' b
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing: origin feat/T7-thing"
  [[ $stderr != *"gate's mirror"* ]]
}

@test "the printed step clears only the branch's ref on the mirror, when each commit's change matches, keeps its head and logs it" {
  gate_mirror
  commit "feat: kept" a
  commit "$attributed" b
  commit $'docs: message only\n\nClaude-Session: x'
  git -C "$wt" push -q no-mistakes feat/T7-thing
  git -C "$wt" push -q no-mistakes "feat/T7-thing:refs/heads/feat/T8-other"
  local old other step new
  old=$(git -C "$wt" rev-parse HEAD)
  other=$(git --git-dir "$mirror" rev-parse feat/T8-other)
  step=$(rewrite_and_land)
  new=$(git -C "$wt" rev-parse HEAD)
  [[ $new != "$old" ]]

  run bash -c "$step"
  assert_equal "$status" 0
  assert_contains "$output" "cleared feat/T7-thing on the gate's mirror"
  assert_contains "$output" "refs/tags/no-mistakes-abandoned/feat/T7-thing/$old"
  assert_equal "$(mirror_refs)" "refs/heads/feat/T8-other $other
refs/tags/no-mistakes-abandoned/feat/T7-thing/$old $old"
  # Nothing else moved, and the gate's next push of the branch is a new branch to it.
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$new"
  assert_equal "$(git -C "$primary" ls-remote origin refs/heads/feat/T7-thing | cut -f1)" "$new"
  git -C "$wt" push -q no-mistakes feat/T7-thing
  assert_equal "$(git --git-dir "$mirror" rev-parse feat/T7-thing)" "$new"
  # The ledger says the lane was cleared.
  assert_equal "$(jq -c 'select(.event == "gate-lane-cleared") | del(.ts)' "$TEAM_HOME/ledger.jsonl")" \
    "{\"task\":\"T7\",\"event\":\"gate-lane-cleared\",\"project\":\"proj\",\"branch\":\"feat/T7-thing\",\"head\":\"$old\",\"tag\":\"refs/tags/no-mistakes-abandoned/feat/T7-thing/$old\"}"
  run_bin -0 team-log --check
}

# Point the project's no-mistakes remote at <path>, and run <step> expecting a refusal naming it
# that moves nothing on the mirror it named before and logs nothing: refused_remote <path> <step>.
refused_remote() {
  git -C "$primary" remote set-url no-mistakes "$1"
  local refs events said rc=0
  refs=$(mirror_refs)
  events=$(cat "$TEAM_HOME/ledger.jsonl")
  said=$(bash -c "$2" 2>&1) || rc=$?
  assert_equal "$rc" 1
  assert_contains "$said" "the no-mistakes remote names $1, which is no bare repository directly under"
  assert_equal "$(mirror_refs)" "$refs"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$events"
}

@test "--clear-gate-lane refuses a remote naming anything but a bare repository directly under ~/.no-mistakes/repos/" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local step old elsewhere other_refs
  old=$(git -C "$wt" rev-parse HEAD)
  step=$(rewrite_and_land)

  # A bare repository elsewhere that holds the branch with a matching commit.
  elsewhere=$BATS_TEST_TMPDIR/elsewhere.git
  git init -q --bare -b dev "$elsewhere"
  git -C "$wt" push -q "$elsewhere" "$old:refs/heads/feat/T7-thing"
  other_refs=$(git --git-dir "$elsewhere" for-each-ref)
  refused_remote "$elsewhere" "$step"
  assert_equal "$(git --git-dir "$elsewhere" for-each-ref)" "$other_refs"
  # The project's own repository, which also holds the branch.
  refused_remote "$primary/.git" "$step"
  assert_equal "$(git -C "$primary" rev-parse feat/T7-thing)" "$(git -C "$wt" rev-parse HEAD)"
  # A link under the root that leads out of it, a repository deeper in it, one not bare, and none.
  ln -s "$elsewhere" "$HOME/.no-mistakes/repos/link.git"
  refused_remote "$HOME/.no-mistakes/repos/link.git" "$step"
  assert_equal "$(git --git-dir "$elsewhere" for-each-ref)" "$other_refs"
  git init -q --bare -b dev "$HOME/.no-mistakes/repos/deep/er.git"
  refused_remote "$HOME/.no-mistakes/repos/deep/er.git" "$step"
  git init -q -b dev "$HOME/.no-mistakes/repos/plain"
  refused_remote "$HOME/.no-mistakes/repos/plain" "$step"
  refused_remote "$HOME/.no-mistakes/repos/missing.git" "$step"
}

@test "a rewrite prints no step for a remote naming anything but a gate's mirror" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  local elsewhere=$BATS_TEST_TMPDIR/elsewhere.git
  git init -q --bare -b dev "$elsewhere"
  git -C "$wt" push -q "$elsewhere" HEAD:refs/heads/feat/T7-thing
  git -C "$primary" remote set-url no-mistakes "$elsewhere"
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  assert_equal "$output" "git push --force-with-lease=feat/T7-thing: origin feat/T7-thing"
}

@test "the printed step runs no hook of the mirror's" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local step marker=$BATS_TEST_TMPDIR/hook-ran
  step=$(rewrite_and_land)
  printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" >"$mirror/hooks/reference-transaction"
  chmod +x "$mirror/hooks/reference-transaction"
  run bash -c "$step"
  assert_equal "$status" 0
  [[ ! -e $marker ]]
  assert_equal "$(git --git-dir "$mirror" for-each-ref 'refs/heads/*')" ""
}

# The branch's commit in the mirror holds <file> with the bytes <mirror's>, and its commit on the
# branch the bytes <branch's>, the same patch to a patch id: same_patch_other_bytes <file> <mirror's>
# <branch's>. Prints the printed step.
same_patch_other_bytes() {
  printf '%b' "$2" >"$wt/$1"
  git -C "$wt" add "$1"
  commit $'feat: bytes\n\nClaude-Session: x'
  git -C "$wt" push -q no-mistakes feat/T7-thing
  git -C "$wt" reset -q --hard HEAD~1
  printf '%b' "$3" >"$wt/$1"
  git -C "$wt" add "$1"
  commit $'feat: bytes\n\nClaude-Session: x'
  rewrite_and_land
}

@test "the printed step refuses, moving nothing, when the mirror's commit differs only in a binary's bytes" {
  gate_mirror
  local step refs
  step=$(same_patch_other_bytes b.bin 'x\0' 'y\0')
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "no ref moved"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the printed step refuses, moving nothing, when the mirror's commit differs only in whitespace" {
  gate_mirror
  local step refs
  step=$(same_patch_other_bytes spaced 'a b\n' 'a  b\n')
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "no ref moved"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the printed step matches a merge of the base by its change too" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  merge_base
  commit $'feat: two\n\nClaude-Session: y' b
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local old step
  old=$(git -C "$wt" rev-parse HEAD)
  step=$(rewrite_and_land)
  run bash -c "$step"
  assert_equal "$status" 0
  assert_equal "$(mirror_refs)" "refs/tags/no-mistakes-abandoned/feat/T7-thing/$old $old"
}

@test "the printed step refuses, moving nothing, when a commit only the mirror holds has no match on the branch" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  commit "feat: only the gate has this" gate-fix
  local lost step refs
  lost=$(git -C "$wt" rev-parse --short HEAD)
  git -C "$wt" push -q no-mistakes feat/T7-thing
  git -C "$wt" reset -q --hard HEAD~1
  commit "feat: another patch" other
  step=$(rewrite_and_land)
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "the gate's mirror holds $lost"
  assert_contains "$output" "no ref moved"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the printed step counts each change once, so a repeated one the branch has fewer of refuses" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" revert --no-edit HEAD >/dev/null
  git -C "$wt" cherry-pick HEAD~1 >/dev/null
  git -C "$wt" push -q no-mistakes feat/T7-thing
  git -C "$wt" reset -q --hard HEAD~1
  local step refs
  step=$(rewrite_and_land)
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "no ref moved"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the printed step clears a branch holding a repeated change as often as the mirror does" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" revert --no-edit HEAD >/dev/null
  git -C "$wt" cherry-pick HEAD~1 >/dev/null
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local old step
  old=$(git -C "$wt" rev-parse HEAD)
  step=$(rewrite_and_land)
  run bash -c "$step"
  assert_equal "$status" 0
  assert_equal "$(mirror_refs)" "refs/tags/no-mistakes-abandoned/feat/T7-thing/$old $old"
}

@test "the printed step refuses, moving nothing, before the push has landed" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  run_bin -0 --separate-stderr team-clean-messages "$wt"
  local step refs
  step=${output##*$'\n'}
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "origin has no branch feat/T7-thing"
  assert_contains "$output" "no ref moved"
  assert_equal "$(mirror_refs)" "$refs"

  # A branch that moved on from what origin has is refused the same way.
  git -C "$wt" push -q origin feat/T7-thing
  commit "feat: unpushed" b
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "origin's feat/T7-thing is at"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the printed step refuses, moving nothing, while a gate run is active on the branch" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local step refs
  step=$(rewrite_and_land)
  fake_gate "$wt"
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "a gate run is active on feat/T7-thing"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "--clear-gate-lane has nothing to clear when the mirror has no such branch or holds nothing the branch lacks" {
  gate_mirror
  commit "feat: one" a
  git -C "$wt" push -q origin feat/T7-thing
  run_bin -0 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "nothing to clear: the gate's mirror has no feat/T7-thing"
  assert_equal "$(mirror_refs)" ""

  git -C "$wt" push -q no-mistakes feat/T7-thing
  commit "feat: two" b
  git -C "$wt" push -q origin feat/T7-thing
  local refs
  refs=$(mirror_refs)
  run_bin -0 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "nothing to clear: the gate's mirror holds no commit feat/T7-thing lacks"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "--clear-gate-lane is refused with no gate, with uncommitted changes, on a detached HEAD and in a worker session" {
  commit "feat: one" a
  run_bin -1 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "has no no-mistakes remote"

  gate_mirror
  git -C "$wt" push -q no-mistakes feat/T7-thing
  git -C "$wt" push -q origin feat/T7-thing
  local refs
  refs=$(mirror_refs)

  AGENT_TEAM_ROLE=builder run_bin -1 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "a builder session clears no gate lane"

  echo change >>"$wt/a"
  run_bin -1 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "uncommitted changes"
  git -C "$wt" checkout -q -- a

  git -C "$wt" checkout -q --detach
  run_bin -1 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "detached HEAD"
  assert_equal "$(mirror_refs)" "$refs"

  run_bin -2 team-clean-messages "$wt" --check --clear-gate-lane
}

@test "--clear-gate-lane is refused on a branch naming no task, and on the base branch and main" {
  gate_mirror
  commit "feat: one" a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local refs branch
  refs=$(mirror_refs)
  git -C "$wt" checkout -q -b feat/no-task
  run_bin -1 team-clean-messages "$wt" --clear-gate-lane
  assert_contains "$output" "feat/no-task names no task"
  git -C "$primary" checkout -q --detach
  for branch in dev main; do
    git -C "$wt" checkout -q -B "$branch" feat/T7-thing
    run_bin -1 team-clean-messages "$wt" --clear-gate-lane
    assert_contains "$output" "$branch is the base branch or main"
  done
  assert_equal "$(mirror_refs)" "$refs"
}

@test "--clear-gate-lane is refused, moving nothing, when it cannot read the gate's state" {
  gate_mirror
  commit $'feat: one\n\nClaude-Session: x' a
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local step refs
  step=$(rewrite_and_land)
  stub_script no-mistakes <<'EOF'
echo 'the daemon does not answer'
exit 3
EOF
  refs=$(mirror_refs)
  run bash -c "$step"
  assert_equal "$status" 1
  assert_contains "$output" "cannot read the gate's state in $wt: the daemon does not answer; no ref moved"
  assert_equal "$(mirror_refs)" "$refs"
}

@test "the mirror's ref is deleted only from the value checked: a compare-and-swap, with its head still kept" {
  gate_mirror
  commit "feat: first" a
  commit $'feat: two\n\nClaude-Session: x' b
  git -C "$wt" push -q no-mistakes feat/T7-thing
  local step old moved real
  old=$(git -C "$wt" rev-parse HEAD)
  moved=$(git -C "$wt" rev-parse HEAD~1)
  step=$(rewrite_and_land)
  real=$(command -v git)
  # Something moves the mirror's ref just before the delete.
  wrap_git <<SH
if [[ " \$* " == *" update-ref -d "* ]]; then
  '$real' --git-dir '$mirror' update-ref refs/heads/feat/T7-thing $moved
fi
SH
  run bash -c "$step"
  rm "$BATS_TEST_TMPDIR/stubs/git"
  assert_equal "$status" 1
  assert_contains "$output" "feat/T7-thing moved on the gate's mirror while it was being cleared"
  assert_equal "$(git --git-dir "$mirror" rev-parse feat/T7-thing)" "$moved"
  assert_equal "$(git --git-dir "$mirror" rev-parse "refs/tags/no-mistakes-abandoned/feat/T7-thing/$old")" "$old"
  [[ $(cat "$TEAM_HOME/ledger.jsonl") != *gate-lane-cleared* ]]
}

# Rewrite the message file commit-tree is handed: the rebuilt offender's (<name>.new) by <offender>
# and any other's by <other>, each a bash expression on $file that prints the new file to use.
wrap_message() {
  wrap_git <<SH
if [[ " \$* " == *" commit-tree "* ]]; then
  args=() next=''
  for a in "\$@"; do
    if [[ -n \$next ]]; then
      next='' file=\$a
      if [[ \$file == *.new ]]; then a=\$($1); else a=\$($2); fi
    fi
    [[ \$a != -F ]] || next=1
    args+=("\$a")
  done
  set -- "\${args[@]}"
fi
SH
}

@test "the branch does not move when a rebuilt commit that had no attribution lines changes its message" {
  commit $'feat: one\n\nClaude-Session: x' a
  commit "feat: two" b
  remember_before
  wrap_message 'echo "$file"' 'printf "feat: changed\n" >"$file.other"; echo "$file.other"'
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "its message differs; nothing moved"
  assert_unchanged
}

@test "the branch does not move when a rebuilt commit still carries an attribution line" {
  commit $'feat: one\n\nClaude-Session: x' a
  remember_before
  wrap_message 'echo "${file%.new}"' 'echo "$file"'
  run_bin -1 team-clean-messages "$wt"
  assert_contains "$output" "it still carries attribution lines; nothing moved"
  assert_unchanged
}
