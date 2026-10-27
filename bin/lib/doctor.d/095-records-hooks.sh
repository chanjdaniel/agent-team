# records hooks The team home's own core.hooksPath is the code's bin/hooks/records-git, by
#               absolute path into the primary code checkout (a worktree's main one): the data
#               check on records commits. The fix is Daniel's, as the git hooks line's is.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's

# The team home's own config, naming the primary code checkout's records hooks.
code=$(dirname "$bin")
records_hooks=$code
code_common=$(git -C "$code" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  records_hooks=$(dirname "$code_common")
records_hooks+=/bin/hooks/records-git
if [[ -z $TEAM_HOME || ! -d $TEAM_HOME ]]; then
  report "records hooks" FAIL "no team home to read it from (the team home line)" \
    "the team home line's fix, then run team-doctor again"
else
  hooks=$(git -C "$TEAM_HOME" config --local core.hooksPath 2>/dev/null) || hooks=''
  hooks_at=${hooks/#\~/$HOME}
  [[ -z $hooks_at || $hooks_at == /* ]] || hooks_at=$TEAM_HOME/$hooks_at
  if [[ -n $hooks && $(realpath -m -- "$hooks_at") == "$(realpath -m -- "$records_hooks")" ]]; then
    report "records hooks" PASS "the team home's core.hooksPath is $(tilde "$records_hooks")"
  else
    hooks_reason="the team home's core.hooksPath is unset, so git runs no data check on its commits"
    [[ -z $hooks ]] || hooks_reason="the team home's core.hooksPath is $hooks, not $(tilde "$records_hooks")"
    report "records hooks" FAIL "$hooks_reason" \
      "Daniel runs git -C $(tilde "$TEAM_HOME") config core.hooksPath $(tilde "$records_hooks")"
  fi
fi
