# git hooks     The code checkout's (the directory above bin/) core.hooksPath is bin/hooks/git
#               (relative, so each worktree runs its own checkout's hooks): the dev guard. The
#               fix is Daniel's, since every session is denied touching core.hooksPath.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's

# Read from the code checkout's own config, so a value set only globally does not pass.
code=$(dirname "$bin")
hooks=$(git -C "$code" config --local core.hooksPath 2>/dev/null) || hooks=''
if [[ $hooks == bin/hooks/git ]]; then
  report "git hooks" PASS "core.hooksPath is bin/hooks/git"
else
  hooks_reason="core.hooksPath is unset, so git runs none of bin/hooks/git"
  [[ -z $hooks ]] || hooks_reason="core.hooksPath is $hooks, not bin/hooks/git"
  report "git hooks" FAIL "$hooks_reason" "Daniel runs git -C $(tilde "$code") config core.hooksPath bin/hooks/git"
fi
