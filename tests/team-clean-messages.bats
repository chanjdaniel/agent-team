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

@test "the matcher finds the attribution lines case-insensitively and keeps human co-authors" {
  local text
  text=$(printf '%s\n' \
    'fix: x' '' \
    'Co-Authored-By: Claude <noreply@anthropic.com>' \
    'co-authored-by: claude-code <x@example.invalid>' \
    'CO-AUTHORED-BY: Some Bot <bot@ANTHROPIC.COM>' \
    'Co-Authored-By: Anthropic Assistant <a@example.invalid>' \
    'Co-Authored-By: Grace Human <grace@example.invalid>' \
    'Co-Authored-By: Claudette Painter <claudette@example.invalid>' \
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
    'CO-AUTHORED-BY: Some Bot <bot@ANTHROPIC.COM>' \
    'Co-Authored-By: Anthropic Assistant <a@example.invalid>' \
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
