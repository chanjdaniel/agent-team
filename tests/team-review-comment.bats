#!/usr/bin/env bats
# team-review-comment: the reviewer's only way to comment, a Markdown file from a task directory
# posted on a registered project's PR, so its allow rule posts no other file and on no other PR.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "Owner/Proj"
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
  wt=$(realpath "$BATS_TEST_TMPDIR")/wt
  git init -q "$wt"
  mkdir -p "$wt/.scratch/task"
  echo "# Review" >"$wt/.scratch/task/review.md"
  stub_reply gh "https://github.com/Owner/Proj/pull/5#issuecomment-1"
}

@test "posts the task directory's file on the PR, in the registered repo's spelling" {
  run_bin -0 team-review-comment https://github.com/owner/proj/pull/5 "$wt/.scratch/task/review.md"
  assert_equal "$output" "https://github.com/Owner/Proj/pull/5#issuecomment-1"
  assert_equal "$(stub_calls gh)" \
    "$(jq -cn --arg file "$wt/.scratch/task/review.md" '["pr", "comment", "5", "--repo", "Owner/Proj", "--body-file", $file]')"
}

@test "a path relative to the worktree, as the briefs give it, works" {
  cd "$wt"
  run_bin -0 team-review-comment https://github.com/owner/proj/pull/5 .scratch/task/review.md
  assert_equal "$(stub_calls gh | jq -r '.[-1]')" "$wt/.scratch/task/review.md"
}

@test "a malformed command line is refused before any gh call" {
  local url=https://github.com/owner/proj/pull/5 file=$wt/.scratch/task/review.md
  run_bin -2 team-review-comment
  run_bin -2 team-review-comment "$url"
  run_bin -2 team-review-comment "$url" "$file" --repo someone/else
  run_bin -2 team-review-comment "$url" --body "x"
  assert_equal "$(stub_calls gh)" ""
}

@test "another PR, or a file from anywhere but a task directory, is refused" {
  local good=https://github.com/owner/proj/pull/5 file=$wt/.scratch/task/review.md
  echo "DISCORD_BOT_TOKEN=x" >"$wt/secret.md"
  ln -s "$HOME/.claude/channels/discord/.env" "$wt/.scratch/task/env.md"
  ln -s "$wt/secret.md" "$wt/.scratch/task/linked.md"
  echo "x" >"$wt/.scratch/task/notes.txt"
  : >"$wt/.scratch/task/empty.md"
  mkdir -p "$wt/.scratch/task/dir.md" "$BATS_TEST_TMPDIR/plain/.scratch/task"
  echo "x" >"$BATS_TEST_TMPDIR/plain/.scratch/task/review.md"
  local -a hostile=(
    "https://github.com/someone/else/pull/5|$file"
    "https://github.com/owner/proj/pull/5/merge|$file"
    "https://github.com/owner/proj/pull/5 --repo someone/else|$file"
    "$good|$HOME/.claude/channels/discord/.env"
    "$good|$wt/secret.md"
    "$good|$wt/.scratch/task/../../secret.md"
    "$good|$wt/.scratch/task/env.md"
    "$good|$wt/.scratch/task/linked.md"
    "$good|$wt/.scratch/task/notes.txt"
    "$good|$wt/.scratch/task/empty.md"
    "$good|$wt/.scratch/task/dir.md"
    "$good|$wt/.scratch/task/missing.md"
    "$good|$BATS_TEST_TMPDIR/plain/.scratch/task/review.md"
  )
  local case url path
  for case in "${hostile[@]}"; do
    IFS='|' read -r url path <<<"$case"
    run_bin team-review-comment "$url" "$path"
    [[ $status -ne 0 ]] || { echo "allowed: $case" >&2; return 1; }
  done
  assert_equal "$(stub_calls gh)" ""
}

@test "a comment GitHub refuses is a failure" {
  stub_reply gh "" 1
  run_bin -1 team-review-comment https://github.com/owner/proj/pull/5 "$wt/.scratch/task/review.md"
  assert_contains "$output" "GitHub refused the comment"
}
