#!/usr/bin/env bats
# Invariants of the team home itself, checked on the tracked files of this checkout.

load helpers/common

setup() {
  sandbox
}

@test "no em dash in tracked Markdown or templates outside tasks/" {
  local files hits
  files=$(git -C "$REPO_ROOT" ls-files -- '*.md' 'templates/**' ':!:tasks/**')
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
