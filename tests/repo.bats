#!/usr/bin/env bats
# Invariants of the team home itself, checked on the tracked files of this checkout.

load helpers/common

setup() {
  sandbox
}

# The records (bin/lib/records) are history and notes written outside any PR, kept as written.
@test "no em dash in tracked Markdown or templates outside the records" {
  local files hits
  files=$(git -C "$REPO_ROOT" ls-files -z -- '*.md' 'templates/**' | bash -c 'source "$1/bin/lib/team.sh"; non_records' _ "$REPO_ROOT")
  [[ -n $files ]]
  hits=$(cd "$REPO_ROOT" && xargs -d '\n' grep -n $'—' -- <<<"$files" || true)
  assert_equal "$hits" ""
}

# The tracked code files of the checkout <dir> that name an Atlas cluster host, in any case, one
# per line; a placeholder host is at example.mongodb.net. Names the file, never the host:
# atlas_host_files <dir>
atlas_host_files() {
  local files
  files=$(git -C "$1" ls-files -z | bash -c 'source "$1/bin/lib/team.sh"; non_records' _ "$REPO_ROOT")
  [[ -n $files ]]
  (cd "$1" && xargs -d '\n' grep -I -H -i -o -E '[a-z0-9-]+\.[a-z0-9-]+\.mongodb\.net' -- <<<"$files" \
    | grep -v -i '\.example\.mongodb\.net$' | cut -d: -f1 | sort -u || true)
}

# D6 (T31): the production toolkits go public without the Atlas cluster's host, which only the
# 1Password item's connection string holds.
@test "no tracked code file names an Atlas cluster host" {
  run -0 atlas_host_files "$REPO_ROOT"
  assert_equal "$output" ""
}

# The hosts are composed at run time, so this file names none.
@test "an Atlas cluster host is named by its file, alone or in upper case, and a placeholder is not" {
  local copy=$BATS_TEST_TMPDIR/copy domain=mongodb.net
  git init -q "$copy"
  mkdir "$copy/toolkits"
  echo "host: made-up.zz9zz9z.$domain" >"$copy/toolkits/one.md"
  git -C "$copy" add toolkits/one.md
  run -0 atlas_host_files "$copy"
  assert_equal "$output" "toolkits/one.md"
  echo "host: MADE-UP.ZZ9ZZ9Z.${domain^^}" >"$copy/toolkits/one.md"
  run -0 atlas_host_files "$copy"
  assert_equal "$output" "toolkits/one.md"
  echo "host: X.EXAMPLE.${domain^^}" >"$copy/toolkits/one.md"
  echo "host: x.example.$domain" >"$copy/toolkits/two.md"
  git -C "$copy" add toolkits/two.md
  run -0 atlas_host_files "$copy"
  assert_equal "$output" ""
}

# Each tracked path of the checkout <dir> that matches neither or both of its lists, bin/lib/code
# and bin/lib/records, with which, one per line: unassigned_paths <dir>
unassigned_paths() {
  local path glob in_code in_records
  local -a code records
  mapfile -t code < <(grep -v -e '^#' -e '^$' "$1/bin/lib/code")
  mapfile -t records < <(grep -v -e '^#' -e '^$' "$1/bin/lib/records")
  while IFS= read -r -d '' path; do
    in_code=0 in_records=0
    for glob in "${code[@]}"; do
      # shellcheck disable=SC2053 # the list's line is a glob
      [[ $path != $glob ]] || { in_code=1; break; }
    done
    for glob in "${records[@]}"; do
      # shellcheck disable=SC2053 # the list's line is a glob
      [[ $path != $glob ]] || { in_records=1; break; }
    done
    case $in_code$in_records in
      00) echo "$path: neither code nor records" ;;
      11) echo "$path: both code and records" ;;
    esac
  done < <(git -C "$1" ls-files -z)
}

# A sandbox copy of this checkout's tracked paths (empty files, the two lists as they are) at
# <dir>: path_copy <dir>
path_copy() {
  git init -q "$1"
  git -C "$REPO_ROOT" ls-files -s -z | git -C "$1" update-index -z --index-info
  mkdir -p "$1/bin/lib"
  cp "$REPO_ROOT/bin/lib/code" "$REPO_ROOT/bin/lib/records" "$1/bin/lib/"
}

# The public repository takes the code list only, so a new path must be assigned before it lands.
@test "every tracked path is exactly one of code (bin/lib/code) and records (bin/lib/records)" {
  run -0 unassigned_paths "$REPO_ROOT"
  assert_equal "$output" ""
}

@test "a tracked path in neither list, or in both, is named" {
  local copy=$BATS_TEST_TMPDIR/copy
  path_copy "$copy"
  run -0 unassigned_paths "$copy"
  assert_equal "$output" ""
  touch "$copy/NOTES.md"
  git -C "$copy" add NOTES.md
  echo 'sops/machine-setup.md' >>"$copy/bin/lib/records"
  run -0 unassigned_paths "$copy"
  assert_equal "$output" "NOTES.md: neither code nor records
sops/machine-setup.md: both code and records"
}

# The machine docs: Daniel's sentence, the setup entry point and the SOPs.
MACHINE_DOCS=(README.md SETUP.md sops/machine-setup.md sops/portability.md)

@test "the machine docs name only commands in bin/, with options and subcommands their --help knows" {
  local doc span cmd i found=0 missing=() words
  for doc in "${MACHINE_DOCS[@]}"; do
    # Each code span's team command and what follows it: `~/agent-team/bin/team-lease take --steal`.
    while IFS= read -r span; do
      found=$((found + 1))
      read -ra words <<<"$span"
      cmd=${words[0]}
      [[ -x $REPO_ROOT/bin/$cmd ]] || { missing+=("$doc: $cmd is not in bin/"); continue; }
      run_bin -0 "$cmd" --help </dev/null
      # Every option, and a subcommand right after the command (`team-config diff --full`).
      for i in "${!words[@]}"; do
        ((i)) || continue
        [[ ${words[i]} == --?* ]] || { ((i == 1)) && [[ ${words[i]} =~ ^[a-z]+$ ]]; } || continue
        grep -qwF -- "${words[i]}" <<<"$output" || missing+=("$doc: $span (${words[i]})")
      done
    done < <(grep -oE '`[^`]*`' "$REPO_ROOT/$doc" | tr -d '`' |
      grep -oE '(^|[ /])(team-[a-z]+(-[a-z]+)*|claude-coordinator)( [^ ]+)*' | sed -E 's#^[ /]##')
  done
  assert_equal "$(printf '%s\n' "${missing[@]}")" ""
  ((found >= 20))
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

# Only Daniel's own terminal runs op (team-secrets restore and save), and only the ops role's
# production servers fetch a credential, each through Daniel's 1Password prompt: every other
# session is denied the 1Password CLI and other processes' environments.
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

# The deny rules are a speed bump, not the guard: git's hooks and team-merge's records check are
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
  assert_denies 'Bash(git *config* core.hooksPath *)' 'git config core.hooksPath /dev/null' \
    'git -C /home/me/agent-team config core.hooksPath x' 'git config set --global core.hooksPath x'
  assert_denies 'Bash(git *config*unset* core.hooksPath*)' 'git config --unset core.hooksPath' \
    'git config --unset-all core.hooksPath' 'git config unset --local core.hooksPath'
  assert_denies 'Bash(git *config* "core.hooksPath" *)' 'git config "core.hooksPath" /dev/null'
  assert_denies "Bash(git *config* 'core.hooksPath' *)" "git config 'core.hooksPath' /dev/null"
  assert_denies 'Bash(git *config*unset* "core.hooksPath"*)' 'git config --unset "core.hooksPath"'
  assert_denies "Bash(git *config*unset* 'core.hooksPath'*)" "git config --unset 'core.hooksPath'"
}

@test "the git hooks' deny rule: git config of core.hookspath, the same key in git's lower case" {
  assert_denies 'Bash(git *config* core.hookspath *)' 'git config core.hookspath x'
  assert_denies 'Bash(git *config*unset* core.hookspath*)' 'git config --unset core.hookspath'
  assert_denies 'Bash(git *config* "core.hookspath" *)' 'git config "core.hookspath" x'
  assert_denies "Bash(git *config* 'core.hookspath' *)" "git config 'core.hookspath' x"
  assert_denies 'Bash(git *config*unset* "core.hookspath"*)' 'git config --unset "core.hookspath"'
  assert_denies "Bash(git *config*unset* 'core.hookspath'*)" "git config --unset 'core.hookspath'"
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
  local command rule
  # gh api writes only with a method or a field: each flag, after the ref path or before it, its
  # value apart or attached.
  for rule in 'Bash(gh api*git/refs* -X*)' 'Bash(gh api* -X*git/refs*)' 'Bash(gh api*git/refs* --method*)' \
    'Bash(gh api* --method*git/refs*)' 'Bash(gh api*git/refs* -f*)' 'Bash(gh api* -f*git/refs*)' \
    'Bash(gh api*git/refs* -F*)' 'Bash(gh api* -F*git/refs*)' 'Bash(gh api*git/refs* --field*)' \
    'Bash(gh api* --field*git/refs*)' 'Bash(gh api*git/refs* --raw-field*)' 'Bash(gh api* --raw-field*git/refs*)' \
    'Bash(gh api*git/refs* --input*)' 'Bash(gh api* --input*git/refs*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r)' "$REPO_ROOT/settings/worker.json" >/dev/null ||
      { echo "settings/worker.json lacks the deny rule $rule" >&2; return 1; }
  done
  while IFS= read -r command; do
    denied settings/worker.json "$command" || { echo "not denied: $command" >&2; return 1; }
  done <<'COMMANDS'
gh api repos/me/shop/git/refs/heads/dev -X DELETE
gh api -X PATCH repos/me/shop/git/refs/heads/dev -f sha=a1b2c3d -F force=true
gh api repos/me/shop/git/refs -f ref=refs/heads/x -f sha=a1b2c3d
gh api --method DELETE repos/me/shop/git/refs/heads/dev
gh api repos/me/shop/git/refs/heads/dev --method PATCH
gh api -F force=true repos/me/shop/git/refs/heads/dev
gh api --field sha=a1b2c3d repos/me/shop/git/refs/heads/dev
gh api repos/me/shop/git/refs --raw-field ref=refs/heads/x --raw-field sha=a1b2c3d
gh api --input ref.json repos/me/shop/git/refs
gh api repos/me/shop/git/refs -fref=refs/heads/x -fsha=a1b2c3d
gh api repos/me/shop/git/refs -f=ref=refs/heads/x -Fsha=a1b2c3d
gh api -fref=refs/heads/x -fsha=a1b2c3d repos/me/shop/git/refs
COMMANDS
}

# The production servers' launcher runs op read itself, so a shell that starts it raises the same
# 1Password prompt as an ops launch: every session is denied starting it, directly or through a
# claude session given a production toolkit.
@test "starting a production server from a shell is denied to every session" {
  assert_denies 'Bash(*node *start-server.mjs*)' 'node /home/me/agent-team/toolkits/prod-write/scripts/start-server.mjs' \
    'cd toolkits/prod-read/scripts && node start-server.mjs' 'node --env-file=x toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(./*start-server.mjs*)' './start-server.mjs' './toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(/*start-server.mjs*)' '/home/me/agent-team/toolkits/prod-write/scripts/start-server.mjs'
  assert_denies 'Bash(toolkits/*start-server.mjs*)' 'toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(*node *mongodb-mcp*)' 'node -e "import(\"/home/me/agent-team/servers/mongodb-mcp.mjs\")"' \
    'node servers/mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(./*mongodb-mcp*)' './mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(/*mongodb-mcp*)' '/home/me/agent-team/servers/mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(servers/*mongodb-mcp*)' 'servers/mongodb-mcp.mjs prod-read' \
    'servers/node_modules/.bin/mongodb-mcp-server --readOnly'
  assert_denies 'Bash(*npx *mongodb-mcp*)' 'npx -y mongodb-mcp-server --readOnly'
  assert_denies 'Bash(*npm exec *mongodb-mcp*)' 'npm exec -- mongodb-mcp-server --readOnly'
  assert_denies 'Bash(*node_modules/.bin/mongodb-mcp*)' 'cd servers && node_modules/.bin/mongodb-mcp-server'
  # Run by a path relative to its toolkit, or through a wrapper or another runtime.
  assert_denies 'Bash(scripts/*start-server.mjs*)' 'scripts/start-server.mjs'
  assert_denies 'Bash(*&& scripts/*start-server.mjs*)' 'cd toolkits/prod-read && scripts/start-server.mjs'
  assert_denies 'Bash(*; scripts/*start-server.mjs*)' 'cd toolkits/prod-read; scripts/start-server.mjs'
  assert_denies 'Bash(env *start-server.mjs*)' 'env toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(bun *start-server.mjs*)' 'bun toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(deno *start-server.mjs*)' 'deno run -A toolkits/prod-read/scripts/start-server.mjs'
  assert_denies 'Bash(env *mongodb-mcp*)' 'env servers/mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(bun *mongodb-mcp*)' 'bun servers/mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(deno *mongodb-mcp*)' 'deno run -A servers/mongodb-mcp.mjs prod-read'
  assert_denies 'Bash(*--plugin-dir*prod-*)' 'claude -p hi --plugin-dir /home/me/agent-team/toolkits/prod-read' \
    'claude --bg --plugin-dir=toolkits/prod-write'
  assert_denies 'Bash(*--mcp-config*prod-*)' 'claude -p hi --mcp-config toolkits/prod-read/.mcp.json' \
    'claude --strict-mcp-config --mcp-config /home/me/agent-team/tasks/T5/mcp.prod-write.json'
}

# The deny rules name the runtimes; a launcher without its exec bit cannot be run by its path at all.
@test "the production launchers and the MCP server's entry are not executable" {
  local modes
  modes=$(git -C "$REPO_ROOT" ls-files -s toolkits/prod-read/scripts toolkits/prod-write/scripts servers/mongodb-mcp.mjs |
    awk '{print $1, $4}')
  assert_equal "$(wc -l <<<"$modes")" 3
  if grep -v '^100644 ' <<<"$modes"; then echo "executable in git (above)" >&2; return 1; fi
}

# Conventioner's email migration rewrites every account's address: a worker is denied running it
# through Python, the stack's compose wrapper or uv, while reading and searching it stay allowed.
@test "running the email migration script is denied to every worker" {
  local command rule
  for rule in 'Bash(*python* *migrate_user_emails*)' 'Bash(*th-compose* *migrate_user_emails*)' \
    'Bash(*uv run* *migrate_user_emails*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r)' "$REPO_ROOT/settings/worker.json" >/dev/null ||
      { echo "settings/worker.json lacks the deny rule $rule" >&2; return 1; }
  done
  while IFS= read -r command; do
    denied settings/worker.json "$command" || { echo "not denied: $command" >&2; return 1; }
  done <<'COMMANDS'
python back-end/migrations/migrate_user_emails.py --apply
cd back-end && python3 -m migrations.migrate_user_emails
scripts/th-compose.sh exec api python migrations/migrate_user_emails.py
scripts/th-compose.sh run --rm api migrate_user_emails
uv run back-end/migrations/migrate_user_emails.py
COMMANDS
}

# Only the coordinator launches an ops session, on Daniel's request: a worker is denied team-worker's
# ops role and the ops load check, while its own test runs of those scripts stay allowed.
@test "an ops launch and the ops load check are denied to workers, and stay the coordinator's" {
  local command rule
  for rule in 'Bash(*team-worker *ops *)' 'Bash(*team-load-check *ops*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r)' "$REPO_ROOT/settings/worker.json" >/dev/null ||
      { echo "settings/worker.json lacks the deny rule $rule" >&2; return 1; }
  done
  while IFS= read -r command; do
    denied settings/worker.json "$command" || { echo "a worker may run: $command" >&2; return 1; }
    if denied coordinator.settings.json "$command"; then echo "the coordinator may not run: $command" >&2; return 1; fi
  done <<'COMMANDS'
/home/me/agent-team/bin/team-worker T5 ops /home/me/slots/proj-1 --toolkit prod-read --request https://discord.com/channels/1/2/3 -- "$(cat /home/me/agent-team/tasks/T5/brief-ops.md)"
team-worker "T5" ops /home/me/slots/proj-1 --toolkit prod-read --request x -- go
/home/me/agent-team/bin/team-load-check --role ops --worktree /home/me/slots/proj-1 --toolkit prod-read
team-load-check --role=ops --worktree /home/me/slots/proj-1 --toolkit prod-read --toolkit prod-write
COMMANDS
}

@test "a worker's own work on the production toolkits and their tests stays allowed" {
  local command
  while IFS= read -r command; do
    if denied settings/worker.json "$command"; then echo "settings/worker.json denies: $command" >&2; return 1; fi
  done <<'COMMANDS'
node --test tests/toolkits/prod-read.test.mjs --test-name-pattern 'the launcher refuses'
tests/run toolkits
tests/vendor/bats-core/bin/bats tests/team-worker.bats -f 'an ops session'
tests/vendor/bats-core/bin/bats tests/team-load-check.bats -f 'the ops form'
claude plugin validate --strict toolkits/prod-read
git add toolkits/prod-write/skills/changing-production-data/SKILL.md
git diff origin/dev -- toolkits/prod-read
/home/me/agent-team/bin/team-worker T5 builder /home/me/slots/proj-1 -- "Read your brief"
COMMANDS
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

# A Bash deny rule matches the command's whole text, so a rule written as a name refuses every read
# of the thing it names. Each command below was refused once (T36's retro, 2026-10-23 and 24).
@test "the deny rules refuse actions, not the names of things" {
  local file command
  for file in "${SETTINGS[@]}"; do
    while IFS= read -r command; do
      if denied "$file" "$command"; then echo "$file denies: $command" >&2; return 1; fi
    done <<'COMMANDS'
git config --get core.hooksPath
git config --show-origin --get-all core.hooksPath
git config --get "core.hooksPath"
sed -n 1,20p scripts/start-server.mjs
gh api repos/me/shop/git/refs/tags/v1.0.0
gh api repos/me/shop/git/refs/tags/v1.0.0 --jq .object.sha
sed -n 1,60p toolkits/prod-read/scripts/start-server.mjs
cat servers/mongodb-mcp.mjs
grep -n migrate_user_emails docs/RELEASING.md
git log -S migrate_user_emails
COMMANDS
    command=$'cat > tickets/11-x.md <<\'EOF\'\nNarrow the deny rule on migrate_user_emails.py to its execution forms.\nEOF'
    if denied "$file" "$command"; then echo "$file denies: $command" >&2; return 1; fi
  done
}

# Whether one of the Bash allow rules in settings/reviewer.json, with @TEAM_CODE@ as team-worker
# renders it (this checkout), matches <command>: reviewer_allows <command>
# Claude Code checks each part of a compound command (;, &&, |) on its own, so a rule's * never
# lets a second command ride along; this model checks one simple command.
reviewer_allows() {
  local rule
  while IFS= read -r rule; do
    rule_matches "${rule//@TEAM_CODE@/$REPO_ROOT}" "$1" && return 0
  done < <(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")
  return 1
}

@test "the reviewer's allow rules are the agent-review status and the review comment scripts only" {
  assert_equal "$(jq -r '.permissions.allow[]' "$REPO_ROOT/settings/reviewer.json")" \
    'Bash(@TEAM_CODE@/bin/team-review-status *)
Bash(@TEAM_CODE@/bin/team-review-comment *)'
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

@test "GitHub's CI runs only on a pull request to main and by hand, and no workflow runs for dev" {
  local workflow
  # CI policy B: the top-level keys under on:, and the branches its pull_request names.
  assert_equal "$(sed -n '/^on:$/,/^[^ ]/s/^  \([a-z_]*\):.*$/\1/p' "$REPO_ROOT/.github/workflows/ci.yml")" \
    $'pull_request\nworkflow_dispatch'
  assert_equal "$(sed -n '/^on:$/,/^[^ ]/s/^    branches: //p' "$REPO_ROOT/.github/workflows/ci.yml")" "[main]"
  for workflow in "$REPO_ROOT"/.github/workflows/*.yml; do
    if grep -nE '^\s*(push|pull_request_target|schedule):' "$workflow" || grep -nE 'branches: .*\bdev\b' "$workflow"; then
      echo "$workflow runs for dev" >&2
      return 1
    fi
  done
}

# The README's inventory is pasted from the ops load check; the eval mocks' _tools.json, which the
# toolkit tests hold to the server's own tools/list, says what it must still be.
@test "each production toolkit's README inventory is exactly its server's tools" {
  local kit listed want
  for kit in prod-read prod-write; do
    listed=$(sed -n '/^```text$/,/^```$/p' "$REPO_ROOT/toolkits/$kit/README.md" | grep '^mcp__' | sort)
    want=$(jq -r --arg kit "$kit" '.tools[] | "mcp__\($kit)__\(.name)"' "$REPO_ROOT/toolkits/$kit/evals/mocks/$kit/_tools.json" | sort)
    [[ -n $want ]]
    assert_equal "$listed" "$want"
  done
}

# The problems with the gotchas SOP <file>, one per line, given the registry's project names:
# gotchas_problems <file> <name>...
gotchas_problems() {
  awk -v names="${*:2}" '
    function close_entry() {
      if (heading != "" && (why != 1 || seen != 1))
        printf "%s: %d Why: and %d Seen: lines, not one each\n", heading, why, seen
    }
    BEGIN { n = split(tolower(names), name, " ") }
    /^## / { close_entry(); heading = $0; why = seen = 0; entries++ }
    /^Why: / { why++ }
    /^Seen: / { seen++; next }
    /(^|[^[:alnum:]_])T[0-9]+([^[:alnum:]_]|$)/ { printf "line %d names a task outside a Seen: line\n", NR }
    {
      for (i = 1; i <= n; i++)
        if (index(tolower($0), name[i])) printf "line %d names the project %s outside a Seen: line\n", NR, name[i]
    }
    END {
      close_entry()
      if (entries < 1 || entries > 12) printf "%d entries, not 1 to 12\n", entries
    }' "$1"
}

# The gotchas SOP stays a short list of general rules, the stories on their Seen: lines only.
@test "the platform gotchas SOP: at most 12 general rules, each with one Why: and one Seen: line" {
  local sop=$REPO_ROOT/sops/platform-gotchas.md
  [[ -f $sop ]] || { echo "sops/platform-gotchas.md is missing" >&2; return 1; }
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/"
  run_bin -0 team-project --list
  ((${#lines[@]} >= 1))
  run -0 gotchas_problems "$sop" "${lines[@]}"
  assert_equal "$output" ""
}

# The templates in templates/briefs/ (not the delivery partials) but ops whose ## Rules section
# lacks the gotchas line, read from the code checkout, one per line: briefs_without_gotchas <dir>
briefs_without_gotchas() {
  local file
  for file in "$1"/*.md; do
    [[ $(basename "$file") != ops.md ]] || continue
    awk '/^## / { rules = ($0 == "## Rules") }
      rules && $0 == "Read `{{team_code}}/sops/platform-gotchas.md` before your first command." { found = 1 }
      END { exit !found }' "$file" || basename "$file"
  done
}

# Every worker reads the gotchas SOP first, whatever its brief, a template added later included.
# The SOP is code, so the brief names it in the code checkout, which the team home never holds.
@test "every brief template tells its worker to read the gotchas SOP before its first command" {
  [[ -f $REPO_ROOT/sops/platform-gotchas.md ]] || { echo "sops/platform-gotchas.md is missing" >&2; return 1; }
  run -0 find "$REPO_ROOT/templates/briefs" -maxdepth 1 -name '*.md'
  ((${#lines[@]} >= 11))
  run -0 briefs_without_gotchas "$REPO_ROOT/templates/briefs"
  assert_equal "$output" ""
}

# The ops session reads nothing outside its worktree, the coordinator passing it the brief's text,
# and runs no shell, so the gotchas do not apply to it: its brief names no path outside it.
@test "the ops brief template names no path outside the ops session's worktree" {
  run grep -nE '\{\{(team_home|team_code|team_bin|plan)\}\}|platform-gotchas' "$REPO_ROOT/templates/briefs/ops.md"
  assert_equal "$status" 1
  assert_equal "$output" ""
}
