#!/usr/bin/env bats
# Invariants of the team home itself, checked on the tracked files of this checkout.

load helpers/common

setup() {
  sandbox
}

# tasks/ and projects/ hold history imported as written, so they keep their own text.
@test "no em dash in tracked Markdown or templates outside tasks/, projects/ and machine/claude/" {
  local files hits
  files=$(git -C "$REPO_ROOT" ls-files -- '*.md' 'templates/**' ':!:tasks/**' ':!:projects/**' ':!:machine/claude/**')
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

# Only Daniel's own terminal runs op (team-secrets restore and save), behind Daniel's 1Password
# prompt: every session is denied the 1Password CLI and other processes' environments.
@test "the worker and coordinator settings deny the 1Password CLI and /proc environment reads" {
  local file rule
  for file in settings/worker.json coordinator.settings.json; do
    for rule in 'Bash(op *)' 'Bash(* op *)' 'Bash(*op read*)' 'Bash(*op run*)' 'Bash(*op item*)' \
      'Bash(*op document*)' 'Bash(*/proc/*/environ*)' 'Read(//proc/**)'; do
      jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$REPO_ROOT/$file" >/dev/null ||
        { echo "$file does not deny $rule" >&2; return 1; }
    done
    denied_in "$REPO_ROOT/$file" 'op read op://agent-team/discord-bot-env/.env'
    denied_in "$REPO_ROOT/$file" 'cd ~ && op document get discord-bot-env --vault agent-team'
    ! denied_in "$REPO_ROOT/$file" 'team-secrets check'
  done
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

@test "a PR merge through gh api is denied to every session" {
  assert_denies 'Bash(gh api*pulls/*/merge*)' \
    'gh api repos/me/shop/pulls/5/merge -X PUT' \
    'gh api -X PUT repos/me/shop/pulls/5/merge' \
    'gh api repos/me/shop/pulls/5/merge -X PUT -f a=repos/x/statuses/y -f state=success -f context=agent-review'
}

@test "a ref written through gh api, a branch delete included, is denied to every worker" {
  local command
  jq -e '.permissions.deny | index("Bash(gh api*git/refs*)")' "$REPO_ROOT/settings/worker.json" >/dev/null
  for command in \
    'gh api repos/me/shop/git/refs/heads/dev -X DELETE' \
    'gh api -X PATCH repos/me/shop/git/refs/heads/dev -f sha=a1b2c3d -F force=true' \
    'gh api repos/me/shop/git/refs -f ref=refs/heads/x -f sha=a1b2c3d'; do
    denied settings/worker.json "$command" || { echo "not denied: $command" >&2; return 1; }
  done
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
gh pr view https://github.com/me/shop/pull/5 --json headRefOid
gh pr checks https://github.com/me/shop/pull/5 --watch
gh api repos/me/shop/pulls/5/comments
COMMANDS
  done
}

# Whether one of the Bash allow rules in settings/reviewer.json, with @TEAM_HOME@ as team-worker
# renders it (this checkout), matches <command>: reviewer_allows <command>
# Claude Code checks each part of a compound command (;, &&, |) on its own, so a rule's * never
# lets a second command ride along; this model checks one simple command.
reviewer_allows() {
  local rule
  while IFS= read -r rule; do
    rule_matches "${rule//@TEAM_HOME@/$REPO_ROOT}" "$1" && return 0
  done < <(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")
  return 1
}

@test "the reviewer's allow rules are the agent-review status and the review comment scripts only" {
  assert_equal "$(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")" \
    'Bash(@TEAM_HOME@/bin/team-review-status *)
Bash(@TEAM_HOME@/bin/team-review-comment *)'
  # The commands as templates/briefs/reviewer.md and rereview.md give them, team_bin being
  # this checkout's bin/ in full.
  local brief
  for brief in reviewer rereview; do
    grep -qF '`{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`' \
      "$REPO_ROOT/templates/briefs/$brief.md"
    grep -qF '`{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/' "$REPO_ROOT/templates/briefs/$brief.md"
  done
  reviewer_allows "$REPO_ROOT/bin/team-review-status https://github.com/me/shop/pull/5 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 success \"no blocking findings\""
  reviewer_allows "$REPO_ROOT/bin/team-review-comment https://github.com/me/shop/pull/5 .scratch/task/review.md"
}

@test "the reviewer's allow rules let no raw gh write through, statuses in the command or not" {
  local command
  while IFS= read -r command; do
    if reviewer_allows "$command"; then echo "the reviewer may run: $command" >&2; return 1; fi
  done <<'COMMANDS'
gh api repos/me/shop/pulls/5/merge -X PUT -f a=repos/x/statuses/y -f state=success -f context=agent-review -f description=x
gh api repos/me/shop/git/refs/heads/dev -X DELETE -F x=repos/a/statuses/b -f state=success -f context=agent-review -f description=x
gh api repos/me/shop/statuses/a1b2c3d -f state=success -f context=agent-review -f description=x
gh api repos/me/shop/statuses/a1b2c3d -f state=success -f context=ci -f description=x
gh api repos/me/shop/pulls/5/merge -X PUT
gh pr comment https://github.com/me/shop/pull/5 --body-file review.md
gh pr comment https://github.com/me/shop/pull/5 --repo someone/else --body-file review.md
gh pr merge https://github.com/me/shop/pull/5
team-review-status https://github.com/me/shop/pull/5 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 success x
/elsewhere/bin/team-review-status https://github.com/me/shop/pull/5 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 success x
COMMANDS
}

@test "the dev-records workflow's paths-ignore lists exactly bin/lib/records' globs" {
  local ignored records
  ignored=$(sed -n '/^    paths-ignore:/,/^[^ ]/s/^      - //p' "$REPO_ROOT/.github/workflows/dev-records.yml")
  records=$(grep -v -e '^#' -e '^$' "$REPO_ROOT/bin/lib/records")
  [[ -n $records ]]
  assert_equal "$ignored" "$records"
}
