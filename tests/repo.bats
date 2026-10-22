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

# Only the ops role's production servers fetch a credential, through Daniel's 1Password prompt:
# every other session is denied the 1Password CLI and other processes' environments.
@test "the worker and coordinator settings deny the 1Password CLI and /proc environment reads" {
  local file rule
  for file in settings/worker.json coordinator.settings.json; do
    for rule in 'Bash(op *)' 'Bash(* op *)' 'Bash(*op read*)' 'Bash(*op run*)' 'Bash(*op item*)' \
      'Bash(*op document*)' 'Bash(*/proc/*/environ*)' 'Read(//proc/**)'; do
      jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$REPO_ROOT/$file" >/dev/null ||
        { echo "$file does not deny $rule" >&2; return 1; }
    done
  done
}
