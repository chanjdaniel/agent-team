# team home     Where the records are, and where it was named: TEAM_HOME, or the first line of
#               ~/.config/agent-team/home (relative to HOME unless absolute). Fails while that
#               is not a directory, not a git checkout of its own (a subdirectory or a worktree
#               of another), has no remote origin or is on a detached HEAD; warns while neither
#               names one, so the team home is the code checkout, the directory above bin/,
#               which holds no records (its fix clones ~/agent-team-records when it is missing,
#               then names it in the setting).
# shellcheck shell=bash

# As the library found it, each way it can be unusable named.
home_shown=$(tilde "$TEAM_HOME")
case $TEAM_HOME_FROM in
  variable) home_named=", named by TEAM_HOME," ;;
  setting) home_named=", named by ~/.config/agent-team/home," ;;
  *) home_named=", the code checkout," ;;
esac
name_fix="name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
home_line=''
[[ $TEAM_HOME_FROM != setting ]] || IFS= read -r home_line <"$HOME/.config/agent-team/home" || true
home_top=$(git -C "$TEAM_HOME" rev-parse --show-toplevel 2>/dev/null) || home_top=''
if [[ $TEAM_HOME_FROM == setting && -z $home_line ]]; then
  report "team home" FAIL "the setting ~/.config/agent-team/home names no team home" "$name_fix"
elif [[ ! -d $TEAM_HOME && $TEAM_HOME_FROM == variable ]]; then
  report "team home" FAIL "$home_shown$home_named is not a directory" "clone the team home to $home_shown, or set TEAM_HOME to its checkout"
elif [[ ! -d $TEAM_HOME ]]; then
  report "team home" FAIL "$home_shown$home_named is not a directory" "clone the team home to $home_shown, or $name_fix"
elif ! same_path "$home_top" "$TEAM_HOME"; then
  report "team home" FAIL "$home_shown$home_named is not a git checkout of its own" "move it aside, then clone the team home to $home_shown"
elif home_common=$(git -C "$TEAM_HOME" rev-parse --path-format=absolute --git-common-dir) &&
  ! same_path "$home_common" "$(git -C "$TEAM_HOME" rev-parse --absolute-git-dir)"; then
  report "team home" FAIL "$home_shown$home_named is a worktree of $(tilde "$(dirname "$(realpath -m -- "$home_common")")"), not a checkout of its own" \
    "move it aside, then clone the team home to $home_shown"
elif ! git -C "$TEAM_HOME" remote get-url origin >/dev/null 2>&1; then
  report "team home" FAIL "$home_shown$home_named has no remote origin" "git -C $home_shown remote add origin <the team home's repository URL>"
elif ! home_branch=$(git -C "$TEAM_HOME" symbolic-ref -q --short HEAD); then
  report "team home" FAIL "$home_shown$home_named is on a detached HEAD, so its records would be committed on no branch" \
    "git -C $home_shown switch dev"
elif [[ $TEAM_HOME_FROM == fallback ]]; then
  # Without the clone, the setting would name a missing directory.
  [[ -d $HOME/agent-team-records ]] ||
    name_fix="clone the team home: git clone https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records, then team-bootstrap --home agent-team-records"
  report "team home" WARN "$home_shown$home_named since neither TEAM_HOME nor ~/.config/agent-team/home names one" "$name_fix"
else
  report "team home" PASS "$home_shown${home_named%,}: a checkout of its own on $home_branch, with an origin"
fi
