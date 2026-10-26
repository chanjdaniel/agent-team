# claude login  `claude auth status`: signed in with a claude.ai account.
# shellcheck shell=bash

# The answer is read for these two fields alone.
login_fix="claude auth login --claudeai" rc=0
auth=$(bounded 30 claude auth status --json 2>/dev/null </dev/null) || rc=$?
auth=$(jq -r 'select(type == "object" and (.loggedIn | type) == "boolean")
  | if .loggedIn then (.authMethod // "" | tostring) else "-" end' <<<"$auth" 2>/dev/null) || auth=''
case $auth in
  claude.ai) report "claude login" PASS "signed in with a claude.ai account" ;;
  -) report "claude login" FAIL "not signed in" "$login_fix" ;;
  '') report "claude login" FAIL "\`claude auth status\` did not answer (exit $rc)" "install Claude Code (see tool claude), then $login_fix" ;;
  *) report "claude login" FAIL "signed in through $auth, not a claude.ai account" "claude auth logout, then $login_fix" ;;
esac
