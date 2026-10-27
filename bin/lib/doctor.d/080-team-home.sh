# team home     Where the records are, and where it was named: TEAM_HOME, or the first line of
#               ~/.config/agent-team/home (relative to HOME unless absolute). Fails while that
#               is not a directory, not a git checkout of its own (a subdirectory or a worktree
#               of another), is the code checkout, has no remote origin or is on a detached
#               HEAD, and while neither names one (its fix clones ~/agent-team-records first
#               when it is missing, fetching only dev and lease as the team home fetch line
#               asks, then names it in the setting).
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's
# shellcheck disable=SC2034 # home_ok, for the team home fetch check

# As the library found it, each way it can be unusable named.
name_fix="name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
# Whether the line passed, so the team home is a checkout of its own with an origin.
home_ok=0
if [[ $TEAM_HOME_FROM == none ]]; then
  # Without the clone, the setting would name a missing directory.
  [[ -d $HOME/agent-team-records ]] ||
    name_fix="clone the team home, then name it: git clone --single-branch --branch dev https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records && git -C ~/agent-team-records remote set-branches --add origin lease && echo agent-team-records > ~/.config/agent-team/home"
  report "team home" FAIL "neither TEAM_HOME nor ~/.config/agent-team/home names one" "$name_fix"
else
  home_shown=$(tilde "$TEAM_HOME")
  home_named=", named by TEAM_HOME,"
  [[ $TEAM_HOME_FROM == variable ]] || home_named=", named by ~/.config/agent-team/home,"
  home_line=''
  [[ $TEAM_HOME_FROM != setting ]] || IFS= read -r home_line <"$HOME/.config/agent-team/home" || true
  home_top=$(git -C "$TEAM_HOME" rev-parse --show-toplevel 2>/dev/null) || home_top=''
  if [[ $TEAM_HOME_FROM == setting && -z $home_line ]]; then
    report "team home" FAIL "the setting ~/.config/agent-team/home names no team home" "$name_fix"
  elif [[ ! -d $TEAM_HOME && $TEAM_HOME_FROM == variable ]]; then
    report "team home" FAIL "$home_shown$home_named is not a directory" "clone the team home to $home_shown, or set TEAM_HOME to its checkout"
  elif [[ ! -d $TEAM_HOME ]]; then
    report "team home" FAIL "$home_shown$home_named is not a directory" "clone the team home to $home_shown, or $name_fix"
  elif same_path "$TEAM_HOME" "$(dirname "$bin")"; then
    report "team home" FAIL "$home_shown$home_named is the code checkout, which holds no records" \
      "clone the team home to ~/agent-team-records, then $name_fix"
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
  else
    home_ok=1
    report "team home" PASS "$home_shown${home_named%,}: a checkout of its own on $home_branch, with an origin"
  fi
fi
