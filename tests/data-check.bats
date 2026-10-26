#!/usr/bin/env bats
# bin/lib/data-check: what a change adds that a repository never takes, by path and kind, never a
# value. The code policy (ci.yml's data job, over a pull request's base and head) refuses an
# address outside the fixture domains and any image; the records policy (the records' pre-commit
# hook, over the index, which tests/records-pre-commit.bats runs) refuses an address at a public
# provider and any image. No address at a real provider is written out in this file, since the
# data job would refuse it: each is built from $provider.

load helpers/common

setup() {
  sandbox
  repo=$(make_repo shop dev)
  cd "$repo" || return
  git checkout -q -b feat/T1-thing
  base=$(git rev-parse HEAD)
  provider=gmail.com other=acme-corp.ca
}

# Write each path's content, staged: put <path> <content>
put() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  git add -- "$1"
}

# A file that starts as a PNG does, staged: put_png <path>
put_png() {
  mkdir -p "$(dirname "$1")"
  printf '\x89PNG\r\n\x1a\n%s' "$RANDOM" >"$1"
  git add -- "$1"
}

# Commit what is staged, past any hook.
commit() {
  git commit -q -m "feat: change"
}

# Run data-check with bats' run, stderr apart: check <status> <arguments>...
check() {
  run "$1" --separate-stderr "$REPO_ROOT/bin/lib/data-check" "${@:2}"
}

@test "code: fixture and service addresses pass, and a name@word.<file type> is no address" {
  put docs/a.md "ann@example.com bo@sub.example.org cy@example.co.uk dee@x.example
eve@example.invalid fay@shop.test gus@localhost hal@app.localhost ivy@ex.com jo@sub.ex.org kay@ex.io
staging-cluster.example.mongodb.net: ops@staging-cluster.example.mongodb.net
Co-Authored-By: Claude <noreply@anthropic.com> NO-REPLY@Shop.dev 1+bot@users.noreply.github.com
git@github.com:owner/site.git logo@2x.png icon@small.svg pkg@1.2.3"
  commit
  check -0 code "$base" HEAD
  assert_equal "$stderr" ""
}

@test "code: an address at a provider or at any other domain is refused, by path and kind, never the value" {
  put docs/a.md "write to ann.lee@$provider or bo@$other, or ANN.LEE@${provider^^}"
  put "tests/b c.bats" "  local mail=cy@$other"
  put docs/ok.md "dee@example.com"
  commit
  check -1 code "$base" HEAD
  assert_equal "$stderr" "data-check: refused: docs/a.md, tests/b c.bats add a real email address, \
an image or a package tree, which the code repository never takes: a test or doc uses an address \
at example.com or example.invalid, and an image or a node_modules/ directory stays out of git; take \
each out, then commit again:
  docs/a.md: 1 email address outside the fixture domains
  docs/a.md: 2 email addresses at a public provider
  tests/b c.bats: 1 email address outside the fixture domains"
  [[ $stderr != *ann.lee* && $stderr != *"$other"* && $output == "" ]]
}

@test "code: any image is refused, by its first bytes or its extension; a deleted one is not" {
  put_png docs/shot.dat
  put docs/logo.svg '<svg xmlns="http://www.w3.org/2000/svg"/>'
  printf 'GIF89a%s' "$RANDOM" >docs/anim
  git add docs/anim
  commit
  check -1 code "$base" HEAD
  assert_contains "$stderr" "data-check: refused: docs/anim, docs/logo.svg, docs/shot.dat add"
  assert_contains "$stderr" "commit again:
  docs/anim: an image
  docs/logo.svg: an image
  docs/shot.dat: an image"
  base=$(git rev-parse HEAD)
  git rm -q docs/shot.dat docs/logo.svg docs/anim
  commit
  check -0 code "$base" HEAD
}

@test "code: only what the change adds counts, and vendored code is not read" {
  put docs/old.md "ann@$other"
  commit
  base=$(git rev-parse HEAD)
  printf '%s\n' "a new line" >>docs/old.md
  git add docs/old.md
  put tests/vendor/bats-core/AUTHORS "Bo <bo@$provider>"
  commit
  check -0 code "$base" HEAD
  # A rename is read whole, as an added file.
  base=$(git rev-parse HEAD)
  git mv docs/old.md docs/new.md
  commit
  check -1 code "$base" HEAD
  assert_contains "$stderr" "docs/new.md: 1 email address outside the fixture domains"
}

# The code repository never tracks a package tree, so a node_modules/ path is no way past the scan.
@test "code: a node_modules/ path is refused whatever it holds, never read" {
  put docs/node_modules/notes.md "ann@$provider"
  put servers/node_modules/pkg/package.json '{}'
  put_png node_modules/pkg/logo.png
  commit
  check -1 code "$base" HEAD
  assert_equal "$stderr" "data-check: refused: docs/node_modules/notes.md, node_modules/pkg/logo.png, \
servers/node_modules/pkg/package.json add a real email address, an image or a package tree, which \
the code repository never takes: a test or doc uses an address at example.com or example.invalid, \
and an image or a node_modules/ directory stays out of git; take each out, then commit again:
  docs/node_modules/notes.md: a package tree (node_modules/)
  node_modules/pkg/logo.png: a package tree (node_modules/)
  servers/node_modules/pkg/package.json: a package tree (node_modules/)"
  [[ $stderr != *ann@* ]]
}

@test "code: the range is what the head adds since its merge base with the base" {
  local head
  put docs/mine.md "ok@example.com"
  commit
  head=$(git rev-parse HEAD)
  # The base moves on with an address the head never added.
  git checkout -q dev
  put docs/theirs.md "ann@$other"
  commit
  check -0 code dev "$head"
  # A binary file is read whole.
  git checkout -q "$head"
  printf 'bin\0ary ann@%s\n' "$other" >data.bin
  git add data.bin
  commit
  check -1 code dev HEAD
  assert_contains "$stderr" "data.bin: 1 email address outside the fixture domains"
}

@test "records: an address at a public provider in the index is refused; another domain and git's user.email pass" {
  git config user.email "Daniel.Owner@$provider"
  put tasks/T1/notes.md "from ann@$other, a fixture bo@example.com, and the owner daniel.owner@$provider"
  check -0 records
  put tasks/T1/plan.md "Discord: please reply to cy.applicant@$provider"
  local outlook=outlook.com yahoo=yahoo.co.uk
  put ledger.jsonl "{\"note\": \"dee@$outlook and eve@$yahoo\"}"
  check -1 records
  assert_equal "$stderr" "data-check: refused: ledger.jsonl, tasks/T1/plan.md add an email address \
at a public provider or an image, which the records never take: other people's addresses and \
screenshots stay out of git; take each out, then commit again:
  ledger.jsonl: 2 email addresses at a public provider
  tasks/T1/plan.md: 1 email address at a public provider"
  [[ $stderr != *applicant* ]]
}

@test "records: a refusal of more than three paths names three in its first line, then how many more" {
  local n
  for n in 1 2 3 4 5; do put "tasks/T$n/notes.md" "ann@$provider"; done
  check -1 records
  assert_equal "${stderr%%$'\n'*}" "data-check: refused: tasks/T1/notes.md, tasks/T2/notes.md, \
tasks/T3/notes.md and 2 more add an email address at a public provider or an image, which the \
records never take: other people's addresses and screenshots stay out of git; take each out, then commit again:"
  assert_equal "$(grep -c '^  tasks/' <<<"$stderr")" 5
}

@test "records: any image is refused, by its first bytes or its extension, a package's aside" {
  put_png tasks/T1/scratch/shot.dat
  put tasks/T1/scratch/logo.svg '<svg xmlns="http://www.w3.org/2000/svg"/>'
  printf '\x00\x00\x01\x00%s' "$RANDOM" >favicon.ico
  git add favicon.ico
  put_png tasks/T1/scratch/tools/node_modules/pkg/logo.png
  check -1 records
  assert_contains "$stderr" "data-check: refused: favicon.ico, tasks/T1/scratch/logo.svg, \
tasks/T1/scratch/shot.dat add an email address at a public provider or an image, which the records \
never take: other people's addresses and screenshots stay out of git; take each out, then commit again:
  favicon.ico: an image
  tasks/T1/scratch/logo.svg: an image
  tasks/T1/scratch/shot.dat: an image"
  [[ $stderr != *node_modules* ]]
  # Deleting one is no addition.
  git rm -q --cached favicon.ico tasks/T1/scratch/logo.svg tasks/T1/scratch/shot.dat
  commit
  git rm -q tasks/T1/scratch/tools/node_modules/pkg/logo.png
  check -0 records
}

@test "a malformed command line is refused with exit 2, a range that is not two commits with exit 1" {
  check -2 ""
  assert_equal "$stderr" "data-check: the first argument is code or records, not nothing"
  check -2 public
  check -2 code HEAD
  assert_equal "$stderr" "data-check: data-check code takes a base and a head, or neither"
  check -1 code no-such-ref HEAD
  assert_equal "$stderr" "data-check: no-such-ref is no commit here"
}
