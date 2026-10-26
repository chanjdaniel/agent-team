# trust team home
#               `claude --bg --name team-doctor-home-trust` with no prompt in the team home,
#               where claude-coordinator starts by default, judged as a project's trust line
#               below; not probed when the team home is a registered project's primary checkout
#               (the code checkout, say, which is agent-team's), whose own trust line probes it,
#               nor while it is no directory, which warns (the team home line fails).
# shellcheck shell=bash
# shellcheck disable=SC2154 # home_shown, from the team home check

# Its probe is team-doctor-home-trust, a name no project's probe can have. A broken registry is
# the projects line's, and the team home is probed as if it were no project's.
home_project=''
if [[ -d $TEAM_HOME ]] && projects=$(team_project --list 2>/dev/null); then
  while IFS= read -r project; do
    [[ -n $project ]] || continue
    ! same_path "$(team_project "$project" | jq -r .path)" "$TEAM_HOME" || home_project=$project
  done <<<"$projects"
fi
if [[ ! -d $TEAM_HOME ]]; then
  report "trust team home" WARN "not probed, since $home_shown is not a directory" "the team home line's fix"
elif [[ -n $home_project ]]; then
  report "trust team home" PASS "not probed apart, since $home_shown is $home_project's primary checkout, which the trust $home_project line probes"
else
  probe_trust "team home" "$TEAM_HOME" team-doctor-home-trust
fi
