#!/usr/bin/env bats
# team-secrets: the secret files a machine needs, checked from their metadata alone, restored from
# 1Password and saved back to it. op is the sandbox's stub standing in for the agent-team vault
# ($FAKE_VAULT/<title>, one file of dummy values per Document); restore and save run in a real
# pseudo-terminal (tests/helpers/terminal.py), as in Daniel's own terminal, and no output, ledger
# or log may carry a dummy value.

load helpers/common

setup() {
  sandbox
  mkdir -p "$TEAM_HOME/machine"
  export FAKE_VAULT=$BATS_TEST_TMPDIR/vault
  mkdir -p "$FAKE_VAULT"
  fake_op
}

# Write machine/secrets.json with one secret per <id>:<target>[:disabled], mode 600, its ref
# op://agent-team/<id>/<the target's file name>.
manifest() {
  local spec id target rest entries=()
  for spec in "$@"; do
    IFS=: read -r id target rest <<<"$spec"
    entries+=("$(jq -cn --arg id "$id" --arg target "$target" --arg rest "$rest" \
      '{id: $id, target: $target, mode: "600", ref: "op://agent-team/\($id)/\($target | split("/") | last)", about: "the \($id) file"}
      + if $rest == "disabled" then {enabled: false} else {} end')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '{about: "test secrets", secrets: .}' >"$TEAM_HOME/machine/secrets.json"
}

# The agent-team vault holds a Document titled <id> for each <id>, with dummy values.
in_vault() {
  local id
  for id in "$@"; do echo "OP_DUMMY_TOKEN=op-dummy-$id-value" >"$FAKE_VAULT/$id"; done
}

# A local secret file under HOME with dummy content: local_secret <target> <mode>
local_secret() {
  mkdir -p "$(dirname "$HOME/$1")"
  echo "LOCAL_DUMMY_TOKEN=local-dummy-value" >"$HOME/$1"
  chmod "$2" "$HOME/$1"
}

# The op stub as the 1Password CLI answers the calls team-secrets makes: read and document get
# write the Document into --out-file with --file-mode (refusing a file already there), document
# list lists the vault, edit and create write it. $STUB_FIXTURES/op-fails lists the calls ("read",
# "document get", ...) that fail as a dismissed prompt does, op-read-misses the ids op read cannot
# resolve; a failing read or get leaves a partial --out-file behind, as an interrupted download
# could.
fake_op() {
  stub_script op <<'EOF'
fail() { echo "[ERROR] 2026/10/23 09:00:00 $*" >&2; exit 1; }
verb=$1
[[ $1 != document ]] || verb="$1 $2"
out='' mode='' title='' vault='' pos=() args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --out-file) out=${args[++i]} ;;
    --file-mode) mode=${args[++i]} ;;
    --vault) vault=${args[++i]} ;;
    --title) title=${args[++i]} ;;
    --file-name | --format) i=$((i + 1)) ;;
    *) pos+=("${args[i]}") ;;
  esac
done
[[ $verb == read || $vault == agent-team ]] || fail "no vault $vault"
if grep -qxF "$verb" "$STUB_FIXTURES/op-fails" 2>/dev/null; then
  [[ -z $out ]] || echo partial >"$out"
  fail "authorization prompt dismissed, please try again"
fi
case $verb in
  read | "document get")
    item=${pos[2]:-}
    if [[ $verb == read ]]; then
      item=${pos[1]#op://agent-team/} item=${item%%/*}
      if grep -qxF "$item" "$STUB_FIXTURES/op-read-misses" 2>/dev/null; then
        echo partial >"$out"
        fail "could not read secret '${pos[1]}': \"${pos[1]##*/}\" isn't a field in the item"
      fi
    fi
    [[ ! -e $out ]] || fail "a file already exists at $out"
    [[ -f $FAKE_VAULT/$item ]] || fail "\"$item\" isn't an item in the \"agent-team\" vault"
    (umask 077 && cp "$FAKE_VAULT/$item" "$out")
    chmod "$mode" "$out"
    echo "$out"
    ;;
  "document list")
    if [[ -f $STUB_FIXTURES/op-list.json ]]; then cat "$STUB_FIXTURES/op-list.json"; exit 0; fi
    find "$FAKE_VAULT" -mindepth 1 -printf '%f\n' | sort | jq -R . | jq -s 'map({id: "id-\(.)", title: ., vault: {name: "agent-team"}})'
    ;;
  "document edit") cp "${pos[3]}" "$FAKE_VAULT/${pos[2]#id-}" ;;
  "document create")
    cp "${pos[2]}" "$FAKE_VAULT/$title"
    echo "{\"uuid\": \"id-$title\", \"vaultUuid\": \"agent-team\"}"
    ;;
  *) fail "unplanned call: $*" ;;
esac
EOF
}

# Run <command...> with bats' run in a pseudo-terminal, after the sandbox guard; leading
# --expect <text> --send <text> pairs type <text> once the output shows <expect>, and options
# before them go to run: run_in_terminal [-<status>] [--expect X --send Y]... -- <command...>
run_in_terminal() {
  local opts=()
  while [[ $1 == -[0-9]* ]]; do opts+=("$1"); shift; done
  guard_sandbox || return 1
  run "${opts[@]}" python3 -I "$REPO_ROOT/tests/helpers/terminal.py" "$@"
}

# Fail when the output, the ledger or anything under ~/.local/state carries a dummy value.
no_dummy_values() {
  local value
  for value in op-dummy paste-dummy local-dummy; do
    [[ $output != *"$value"* ]] || { echo "the output carries $value" >&2; return 1; }
    ! grep -rqF "$value" "$TEAM_HOME/ledger.jsonl" "$HOME/.local/state" 2>/dev/null ||
      { echo "the ledger or a log carries $value" >&2; return 1; }
  done
}

# The verb of each op call ("read", "document get", ...), one per line.
op_verbs() {
  stub_calls op | jq -r 'if .[0] == "document" then .[0:2] else .[0:1] end | join(" ")'
}

# Every --out-file op was given, one per line.
out_files() {
  stub_calls op | jq -r 'index("--out-file") as $i | select($i) | .[$i + 1]'
}

# A PATH that is this one without any op: a folder of links to every other command on it.
path_without_op() {
  local bin=$BATS_TEST_TMPDIR/without-op dir dirs
  mkdir -p "$bin"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    ln -s "$dir"/* "$bin/" 2>/dev/null || true
  done
  rm -f "$bin/op"
  echo "$bin"
}

@test "check passes or fails each enabled secret from its existence, size and mode alone" {
  manifest ok-env:projects/app/.env no-env:projects/app/api/.env empty-env:projects/app/web/.env \
    open-env:.config/bot/.env dir-env:.config/dir/.env write-only:.config/w/.env hub-env:hub/.env:disabled
  local_secret projects/app/.env 600
  mkdir -p "$HOME/projects/app/web"
  touch "$HOME/projects/app/web/.env"
  chmod 600 "$HOME/projects/app/web/.env"
  local_secret .config/bot/.env 644
  mkdir -p "$HOME/.config/dir/.env"
  # Mode 200 lets nobody read it: a check that opened the file could not pass it.
  jq '(.secrets[] | select(.id == "write-only") | .mode) = "200"' "$TEAM_HOME/machine/secrets.json" >"$BATS_TEST_TMPDIR/m"
  mv "$BATS_TEST_TMPDIR/m" "$TEAM_HOME/machine/secrets.json"
  local_secret .config/w/.env 200

  run_bin -1 team-secrets check
  assert_equal "$output" "PASS ok-env
FAIL no-env: missing
FAIL empty-env: empty
FAIL open-env: mode 644
FAIL dir-env: not a file
PASS write-only"
  no_dummy_values

  run_bin -1 --separate-stderr team-secrets check --json
  assert_equal "$(jq -c . <<<"$output")" '[{"id":"ok-env","verdict":"PASS","reason":""},{"id":"no-env","verdict":"FAIL","reason":"missing"},{"id":"empty-env","verdict":"FAIL","reason":"empty"},{"id":"open-env","verdict":"FAIL","reason":"mode 644"},{"id":"dir-env","verdict":"FAIL","reason":"not a file"},{"id":"write-only","verdict":"PASS","reason":""}]'
  assert_equal "$stderr" ""

  # Every secret in place: exit 0; and op is never asked.
  manifest ok-env:projects/app/.env hub-env:hub/.env:disabled
  run_bin -0 team-secrets check
  assert_equal "$output" "PASS ok-env"
  assert_equal "$(stub_calls op)" ""
}

@test "check on a manifest shaped like the team home's fails each enabled secret it lacks, and not the disabled one" {
  cp "$BATS_TEST_DIRNAME/fixtures/secrets.json" "$TEAM_HOME/machine/secrets.json"
  # The sandbox's Discord token, written with the default umask.
  run_bin -1 team-secrets check
  assert_equal "$output" "FAIL discord-bot-env: mode 644
FAIL discord-access-json: missing
FAIL conventioner-env: missing
FAIL conventioner-front-end-env: missing
FAIL conventioner-back-end-env: missing"
}

@test "check refuses a missing or malformed manifest, naming each problem" {
  run_bin -1 --separate-stderr team-secrets check
  assert_equal "$stderr" "team-secrets: no machine/secrets.json in $TEAM_HOME"
  echo 'not json' >"$TEAM_HOME/machine/secrets.json"
  run_bin -1 --separate-stderr team-secrets check
  assert_equal "$stderr" "team-secrets: machine/secrets.json is not JSON"
  echo '[]' >"$TEAM_HOME/machine/secrets.json"
  run_bin -1 --separate-stderr team-secrets check
  assert_equal "$stderr" "team-secrets: machine/secrets.json: it has no secrets array"
  echo '{"secrets": [
    {"id": "Bad Id", "target": "/etc/x", "mode": "0600", "ref": "https://x", "about": 1, "enabled": "yes"},
    {"id": "ok", "target": "a/../b", "mode": "600", "ref": "op://agent-team/ok/.env", "about": ""},
    {"id": "ok", "target": "a/b", "mode": "600", "ref": "op://agent-team/ok/.env", "about": ""},
    3]}' >"$TEAM_HOME/machine/secrets.json"
  run_bin -1 --separate-stderr team-secrets check
  assert_equal "$stderr" "team-secrets: machine/secrets.json: entry 0: id is not lower-case kebab case; entry 0: target is not a path under HOME; entry 0: mode is not three octal digits; entry 0: ref is not an op:// reference; entry 0: about is not a string; entry 0: enabled is not true or false; ok: target is not a path under HOME; entry 3 is not an object; ok: listed twice"
}

@test "restore and save refuse unless stdin and stdout are a terminal, before any op call" {
  manifest bot-env:.config/bot/.env
  local_secret .config/bot/.env 600
  rm "$HOME/.config/bot/.env"
  in_vault bot-env
  local command
  for command in restore "save bot-env"; do
    # shellcheck disable=SC2086 # the command and its argument
    run_bin -1 --separate-stderr team-secrets $command </dev/null
    assert_equal "$stderr" "team-secrets: ${command%% *} runs only in Daniel's own terminal (stdin and stdout a terminal), never in an agent's shell: type team-secrets ${command%% *} there"
    # stdin a terminal, stdout not.
    run_in_terminal -1 -- bash -c '"$0" $1 >"$2"' "$REPO_ROOT/bin/team-secrets" "$command" "$BATS_TEST_TMPDIR/out"
    assert_contains "$output" "${command%% *} runs only in Daniel's own terminal"
  done
  assert_equal "$(stub_calls op)" ""
  [[ ! -e $HOME/.config/bot/.env ]]
}

@test "restore fetches each missing, empty or wrong-mode secret beside its target with mode 600, backing up a wrong-mode one, pastes what 1Password lacks, and ends with check" {
  manifest ok-env:projects/app/.env bot-env:.config/bot/.env empty-env:projects/app/web/.env \
    open-env:projects/app/api/.env paste-env:projects/paste/.env skip-env:projects/skip/.env \
    dir-env:.config/dir/.env hub-env:hub/.env:disabled
  in_vault ok-env bot-env empty-env open-env hub-env
  local_secret projects/app/.env 600
  mkdir -p "$HOME/projects/app/web"
  : >"$HOME/projects/app/web/.env"
  local_secret projects/app/api/.env 644
  cp "$HOME/projects/app/api/.env" "$BATS_TEST_TMPDIR/open-before"
  mkdir -p "$HOME/projects/paste" "$HOME/projects/skip" "$HOME/.config/dir/.env"
  local ok_before
  ok_before=$(stat -c '%i %s %y %a' "$HOME/projects/app/.env")
  # op read cannot resolve empty-env's reference, so op document get fetches it.
  echo empty-env >"$STUB_FIXTURES/op-read-misses"

  run_in_terminal -1 --expect "paste-env: paste" --send $'PASTE_DUMMY_TOKEN=paste-dummy-value\n\x04' \
    --expect "skip-env: paste" --send $'\x04' -- "$REPO_ROOT/bin/team-secrets" restore
  local backup
  backup=$(find "$HOME/projects/app/api" -name '.env.bak-*')
  [[ ${backup##*/} =~ ^\.env\.bak-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}$ ]] || { echo "not a backup name: $backup" >&2; return 1; }
  assert_equal "$output" "ok-env: in place; untouched
bot-env: restored from 1Password (op read)
empty-env: op read gave nothing: could not read secret 'op://agent-team/empty-env/.env': \".env\" isn't a field in the item
empty-env: restored from 1Password (op document get)
open-env: replaced from 1Password (op read); the old one (mode 644) is ~/projects/app/api/${backup##*/}, mode 600
paste-env: op read gave nothing: \"paste-env\" isn't an item in the \"agent-team\" vault
paste-env: op document get gave nothing: \"paste-env\" isn't an item in the \"agent-team\" vault
paste-env: paste ~/projects/paste/.env (the paste-env file), then Ctrl-D on a line of its own; Ctrl-D alone skips it. What you paste is not shown.

paste-env: restored from what you pasted
skip-env: op read gave nothing: \"skip-env\" isn't an item in the \"agent-team\" vault
skip-env: op document get gave nothing: \"skip-env\" isn't an item in the \"agent-team\" vault
skip-env: paste ~/projects/skip/.env (the skip-env file), then Ctrl-D on a line of its own; Ctrl-D alone skips it. What you paste is not shown.

skip-env: skipped; still missing
dir-env: ~/.config/dir/.env is not a file; left alone

team-secrets check:
PASS ok-env
PASS bot-env
PASS empty-env
PASS open-env
PASS paste-env
FAIL skip-env: missing
FAIL dir-env: not a file"
  no_dummy_values

  # Fetched and pasted secrets hold what 1Password or Daniel gave, with mode 600, and the
  # folder restore made is 700.
  cmp "$FAKE_VAULT/bot-env" "$HOME/.config/bot/.env"
  cmp "$FAKE_VAULT/empty-env" "$HOME/projects/app/web/.env"
  assert_equal "$(cat "$HOME/projects/paste/.env")" "PASTE_DUMMY_TOKEN=paste-dummy-value"
  assert_equal "$(stat -c %a "$HOME/.config/bot/.env" "$HOME/projects/app/web/.env" "$HOME/projects/paste/.env" | sort -u)" 600
  assert_equal "$(stat -c %a "$HOME/.config/bot")" 700
  # The wrong-mode one holds 1Password's, its old content kept beside it with mode 600; a passing
  # secret was not touched at all.
  cmp "$FAKE_VAULT/open-env" "$HOME/projects/app/api/.env"
  cmp "$BATS_TEST_TMPDIR/open-before" "$backup"
  assert_equal "$(stat -c %a "$HOME/projects/app/api/.env" "$backup" | sort -u)" 600
  assert_equal "$(stat -c '%i %s %y %a' "$HOME/projects/app/.env")" "$ok_before"
  [[ ! -e $HOME/hub/.env && ! -e $HOME/projects/skip/.env ]]

  # Every download went to a new temporary file beside its target, with mode 0600; none is left.
  assert_equal "$(op_verbs | sort | uniq -c | sed 's/^ *//')" "3 document get
5 read"
  local out
  while IFS= read -r out; do
    [[ ${out##*/} =~ ^\.\.env\.restore\.[A-Za-z0-9]{6}$ ]] || { echo "not a temporary name: $out" >&2; return 1; }
  done < <(out_files)
  assert_equal "$(out_files | xargs -n1 dirname | sort -u)" "$(printf '%s\n' "$HOME/.config/bot" "$HOME/projects/app/web" "$HOME/projects/app/api" "$HOME/projects/paste" "$HOME/projects/skip" | sort)"
  assert_equal "$(stub_calls op | jq -r 'index("--file-mode") as $i | .[$i + 1]' | sort -u)" 0600
  assert_equal "$(find "$HOME" -name '*.restore.*')" ""
  # op read on the ref, then op document get on the id in the agent-team vault.
  stub_calls op | jq -e -s --arg tmp "$(out_files | head -n1)" '.[0] == ["read", "--out-file", $tmp, "--file-mode", "0600", "op://agent-team/bot-env/.env"]'
  stub_calls op | jq -e -s 'any(.[]; .[0:5] == ["document", "get", "empty-env", "--vault", "agent-team"])'

  # Run again with everything in place but the skipped one, skipped again: only it is asked about.
  rmdir "$HOME/.config/dir/.env"
  local_secret .config/dir/.env 600
  : >"$STUB_CALLS/op.log"
  run_in_terminal -1 --expect "skip-env: paste" --send $'\x04' -- "$REPO_ROOT/bin/team-secrets" restore
  assert_equal "$(grep -c 'in place; untouched' <<<"$output")" 6
  assert_equal "$(op_verbs)" "read
document get"
  assert_equal "$(tail -n2 <<<"$output")" "FAIL skip-env: missing
PASS dir-env"
}

@test "a wrong-mode secret 1Password and Daniel do not replace is left as it was, with no backup" {
  manifest open-env:.config/open/.env
  in_vault open-env
  local_secret .config/open/.env 644
  cp "$HOME/.config/open/.env" "$BATS_TEST_TMPDIR/open-before"
  printf '%s\n' read "document get" >"$STUB_FIXTURES/op-fails"
  run_in_terminal -1 --expect "open-env: paste" --send $'\x04' -- "$REPO_ROOT/bin/team-secrets" restore
  assert_contains "$output" "open-env: skipped; still mode 644"
  assert_equal "$(tail -n1 <<<"$output")" "FAIL open-env: mode 644"
  no_dummy_values
  cmp "$BATS_TEST_TMPDIR/open-before" "$HOME/.config/open/.env"
  assert_equal "$(stat -c %a "$HOME/.config/open/.env")" 644
  assert_equal "$(find "$HOME" -name '*.bak-*' -o -name '*.restore.*')" ""
}

@test "restore with every secret fetched exits 0; an op failure falls back to the paste, leaving no temporary file" {
  manifest bot-env:.config/bot/.env app-env:projects/app/.env
  in_vault bot-env app-env
  run_in_terminal -0 -- "$REPO_ROOT/bin/team-secrets" restore
  assert_equal "$(tail -n3 <<<"$output")" "team-secrets check:
PASS bot-env
PASS app-env"
  no_dummy_values

  # 1Password's prompt dismissed: each download leaves a partial file, which goes; then the paste.
  rm "$HOME/.config/bot/.env" "$HOME/projects/app/.env"
  printf '%s\n' read "document get" >"$STUB_FIXTURES/op-fails"
  run_in_terminal -0 --expect "bot-env: paste" --send $'PASTE_DUMMY_TOKEN=paste-dummy-bot\n\x04' \
    --expect "app-env: paste" --send $'PASTE_DUMMY_TOKEN=paste-dummy-app\n\x04' -- "$REPO_ROOT/bin/team-secrets" restore
  assert_contains "$output" "bot-env: op read gave nothing: authorization prompt dismissed, please try again
bot-env: op document get gave nothing: authorization prompt dismissed, please try again"
  assert_contains "$output" "app-env: restored from what you pasted"
  no_dummy_values
  assert_equal "$(find "$HOME" -name '*.restore.*')" ""
  assert_equal "$(cat "$HOME/.config/bot/.env")" "PASTE_DUMMY_TOKEN=paste-dummy-bot"
  assert_equal "$(stat -c %a "$HOME/.config/bot/.env" "$HOME/projects/app/.env" | sort -u)" 600
}

@test "restore without op installed goes straight to the paste" {
  manifest bot-env:.config/bot/.env
  in_vault bot-env
  local path
  path=$(path_without_op)
  PATH=$path run_in_terminal -0 --expect "bot-env: paste" --send $'PASTE_DUMMY_TOKEN=paste-dummy-value\n\x04' \
    -- "$REPO_ROOT/bin/team-secrets" restore
  assert_contains "$output" "bot-env: op read gave nothing: op is not installed
bot-env: op document get gave nothing: op is not installed"
  assert_contains "$output" "PASS bot-env"
  no_dummy_values
  assert_equal "$(stub_calls op)" ""
}

@test "save edits the vault's document when it exists and creates it when not, printing only the id and the result" {
  manifest bot-env:.config/bot/.env app-env:projects/app/.env hub-env:hub/.env:disabled
  local_secret .config/bot/.env 600
  local_secret projects/app/.env 600
  in_vault bot-env

  run_in_terminal -0 -- "$REPO_ROOT/bin/team-secrets" save bot-env
  assert_equal "$output" "saved bot-env: updated its document in the agent-team vault"
  no_dummy_values
  cmp "$HOME/.config/bot/.env" "$FAKE_VAULT/bot-env"
  assert_equal "$(stub_calls op | tail -n1)" "$(jq -cn --arg f "$HOME/.config/bot/.env" \
    '["document", "edit", "id-bot-env", $f, "--vault", "agent-team", "--file-name", ".env"]')"

  run_in_terminal -0 -- "$REPO_ROOT/bin/team-secrets" save app-env
  assert_equal "$output" "saved app-env: created its document in the agent-team vault"
  no_dummy_values
  cmp "$HOME/projects/app/.env" "$FAKE_VAULT/app-env"
  assert_equal "$(stub_calls op | tail -n1)" "$(jq -cn --arg f "$HOME/projects/app/.env" \
    '["document", "create", $f, "--vault", "agent-team", "--title", "app-env", "--file-name", ".env"]')"
  assert_equal "$(op_verbs)" "document list
document edit
document list
document create"
}

@test "save refuses an unknown, disabled or missing secret before asking op, and reports op's failure" {
  manifest bot-env:.config/bot/.env app-env:projects/app/.env hub-env:hub/.env:disabled
  local_secret .config/bot/.env 600
  local_secret hub/.env 600
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save nope
  assert_equal "$output" "team-secrets: machine/secrets.json lists no enabled secret nope"
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save hub-env
  assert_equal "$output" "team-secrets: machine/secrets.json lists no enabled secret hub-env"
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save app-env
  assert_equal "$output" "team-secrets: app-env: ~/projects/app/.env is missing or empty, so there is nothing to save"
  assert_equal "$(stub_calls op)" ""

  echo "document list" >"$STUB_FIXTURES/op-fails"
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save bot-env
  assert_equal "$output" "team-secrets: bot-env: 1Password did not list the agent-team vault: authorization prompt dismissed, please try again"
  echo "document create" >"$STUB_FIXTURES/op-fails"
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save bot-env
  assert_equal "$output" "team-secrets: bot-env: 1Password did not create its document: authorization prompt dismissed, please try again"
  echo '[{"id": "a", "title": "bot-env"}, {"id": "b", "title": "bot-env"}]' >"$STUB_FIXTURES/op-list.json"
  run_in_terminal -1 -- "$REPO_ROOT/bin/team-secrets" save bot-env
  assert_equal "$output" "team-secrets: bot-env: the agent-team vault has more than one document titled bot-env; delete the extra ones in 1Password"
  no_dummy_values
  [[ ! -e $FAKE_VAULT/bot-env ]]
}

@test "team-secrets refuses a malformed command line" {
  local args
  for args in "" "check --full" "restore now" "save" "save a b" "fetch"; do
    # shellcheck disable=SC2086 # the words of each command line
    run_bin -2 --separate-stderr team-secrets $args
    assert_equal "$stderr" "team-secrets: usage: team-secrets check [--json] | restore | save <id>"
  done
}
