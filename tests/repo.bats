#!/usr/bin/env bats
# Invariants of the team home itself, checked on the tracked files of this checkout.

load helpers/common

setup() {
  sandbox
}

# tasks/ and projects/ hold history imported as written, so they keep their own text.
@test "no em dash in tracked Markdown or templates outside tasks/ and projects/" {
  local files hits
  files=$(git -C "$REPO_ROOT" ls-files -- '*.md' 'templates/**' ':!:tasks/**' ':!:projects/**')
  [[ -n $files ]]
  hits=$(cd "$REPO_ROOT" && xargs -d '\n' grep -n $'—' -- <<<"$files" || true)
  assert_equal "$hits" ""
}

@test "every executable in bin/ answers --help with its header and exit 0" {
  local script found=0 header
  while IFS= read -r script; do
    found=$((found + 1))
    header=$(sed -n '2s/^# \{0,1\}//p' "$REPO_ROOT/bin/$script")
    [[ -n $header ]] || { echo "bin/$script has no header comment" >&2; return 1; }
    run_bin -0 "$script" --help </dev/null
    assert_equal "${lines[0]}" "$header"
  done < <(cd "$REPO_ROOT/bin" && find . -type f -perm -u+x -printf '%P\n' | sort)
  ((found >= 5))
}

# The settings every session starts with: the coordinator's and the workers' shared ones.
SETTINGS=(coordinator.settings.json settings/worker.json)

# Whether one of the Bash deny rules in <settings file> matches <command>, a rule's * matching any
# text as Claude Code's does: denied <settings file> <command>
denied() {
  local rule
  while IFS= read -r rule; do
    rule_matches "$rule" "$2" && return 0
  done < <(jq -r '.permissions.deny[] | select(startswith("Bash("))' "$REPO_ROOT/$1")
  return 1
}

# Whether the Bash rule <rule> matches <command>: rule_matches <rule> <command>
rule_matches() {
  local glob=${1#Bash(}
  glob=${glob%)}
  # shellcheck disable=SC2053 # the rule is a glob
  [[ $2 == $glob ]]
}

# Every session's settings deny <rule>, and it matches each <command>: assert_denies <rule> <command>...
assert_denies() {
  local file command
  for file in "${SETTINGS[@]}"; do
    jq -e --arg rule "$1" '.permissions.deny | index($rule)' "$REPO_ROOT/$file" >/dev/null ||
      { echo "$file lacks the deny rule $1" >&2; return 1; }
  done
  for command in "${@:2}"; do
    rule_matches "$1" "$command" || { echo "$1 does not match: $command" >&2; return 1; }
  done
}

# The deny rules are a speed bump, not the guard: git's hooks and the Dev records workflow are
# (CLAUDE.md). Each rule matches the commands it is for; the commands below them stay allowed.

@test "the git hooks' deny rule: --no-verify last, on any git command" {
  assert_denies 'Bash(git * --no-verify)' 'git commit --no-verify' 'git commit -a -m "x" --no-verify' \
    'git push -u origin feat/T1-x --no-verify'
}

@test "the git hooks' deny rule: --no-verify before more arguments, on any git command" {
  assert_denies 'Bash(git * --no-verify *)' 'git commit --no-verify -m "x"' \
    'git push --no-verify origin feat/T1-x' 'git -C /home/me/agent-team commit --no-verify -m "x"'
}

@test "the git hooks' deny rule: git commit -n first" {
  assert_denies 'Bash(git commit -n*)' 'git commit -n -m "x"' 'git commit -nm "x"'
}

@test "the git hooks' deny rule: git commit -n last" {
  assert_denies 'Bash(git commit * -n)' 'git commit -m "x" -n'
}

@test "the git hooks' deny rule: git commit -n before another option" {
  assert_denies 'Bash(git commit * -n -*)' 'git commit -a -n -m "x"'
}

@test "the git hooks' deny rule: git config of core.hooksPath, set or unset" {
  assert_denies 'Bash(git *config*core.hooksPath*)' 'git config core.hooksPath /dev/null' \
    'git config --unset core.hooksPath' 'git -C /home/me/agent-team config core.hooksPath x'
}

@test "the git hooks' deny rule: git config of core.hookspath, the same key in git's lower case" {
  assert_denies 'Bash(git *config*core.hookspath*)' 'git config core.hookspath x'
}

@test "the git hooks' deny rule: core.hooksPath overridden for one command" {
  assert_denies 'Bash(git *-c core.hooksPath*)' 'git -c core.hooksPath=/dev/null commit -m "x"' \
    'git -C /home/me/agent-team -c core.hooksPath= commit -m "x"'
}

@test "the git hooks' deny rule: core.hookspath overridden for one command, in git's lower case" {
  assert_denies 'Bash(git *-c core.hookspath*)' 'git -c core.hookspath= commit'
}

@test "plain commits, pushes, config and searches for the rules' words stay allowed for every session" {
  local file command
  for file in "${SETTINGS[@]}"; do
    while IFS= read -r command; do
      if denied "$file" "$command"; then echo "$file denies: $command" >&2; return 1; fi
    done <<'COMMANDS'
git commit -m "fix: x"
git commit -am "x"
git commit --no-edit
git commit -m "docs: deny --no-verify"
git commit -m "fix: the -n flag"
git push -u origin feat/T1-x
git config user.name "x"
git grep -n core.hooksPath
git log -S core.hooksPath
COMMANDS
  done
}

# Whether one of the Bash allow rules in settings/reviewer.json matches <command>:
# reviewer_allows <command>
reviewer_allows() {
  local rule
  while IFS= read -r rule; do
    rule_matches "$rule" "$1" && return 0
  done < <(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")
  return 1
}

@test "the reviewer may set the agent-review status and post its comment, and no other gh write" {
  assert_equal "$(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")" \
    'Bash(gh api repos/*/statuses/* -f state=success -f context=agent-review -f description=*)
Bash(gh api repos/*/statuses/* -f state=failure -f context=agent-review -f description=*)
Bash(gh pr comment * --body-file *)'
  # The commands as templates/briefs/reviewer.md and rereview.md render them.
  local brief
  for brief in reviewer rereview; do
    grep -qF 'gh api repos/{{repo}}/statuses/{{head}} -f state=<success|failure> -f context=agent-review -f description="<one line>"' \
      "$REPO_ROOT/templates/briefs/$brief.md"
  done
  reviewer_allows 'gh api repos/me/shop/statuses/a1b2c3d -f state=success -f context=agent-review -f description="no blocking findings"'
  reviewer_allows 'gh api repos/me/shop/statuses/a1b2c3d -f state=failure -f context=agent-review -f description="1 blocking"'
  reviewer_allows 'gh pr comment https://github.com/me/shop/pull/5 --body-file /home/me/wt/.scratch/task/review.md'
  run -1 reviewer_allows 'gh api repos/me/shop/statuses/a1b2c3d -f state=success -f context=ci -f description=x'
  run -1 reviewer_allows 'gh api repos/me/shop/pulls/5/merge -X PUT'
  run -1 reviewer_allows 'gh pr comment https://github.com/me/shop/pull/5 --body "x"'
  run -1 reviewer_allows 'gh pr merge https://github.com/me/shop/pull/5'
}

@test "the dev-records workflow's paths-ignore lists exactly bin/lib/records' globs" {
  local ignored records
  ignored=$(sed -n '/^    paths-ignore:/,/^[^ ]/s/^      - //p' "$REPO_ROOT/.github/workflows/dev-records.yml")
  records=$(grep -v -e '^#' -e '^$' "$REPO_ROOT/bin/lib/records")
  [[ -n $records ]]
  assert_equal "$ignored" "$records"
}
