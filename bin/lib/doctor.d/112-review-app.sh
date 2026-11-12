# review app    The reviewer App, whose agent-review check run the team's own project merges
#               behind (review_app in bin/lib/team.sh): passes saying it is off with no
#               bin/lib/review-app; else fails on the first of a malformed bin/lib/review-app, its
#               key ~/.config/agent-team/review-app.pem missing, not a file or off mode 600 (no
#               byte of it read), no registered project the team's own, or such a project's base,
#               read from GitHub, whose protection does not require agent-review from the App's
#               id or enforces its required checks for anyone but everyone.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

review_app_check() {
  local app app_id app_slug key=$HOME/.config/agent-team/review-app.pem shown own project repo base mode branch problem
  local restore="Daniel runs team-secrets restore in their own terminal"
  if ! app=$(review_app 2>"$err"); then
    report "review app" FAIL "$(first_error)" "give bin/lib/review-app its two lines through a PR to dev"
    return
  fi
  if [[ -z $app ]]; then
    report "review app" PASS "off, since no bin/lib/review-app names the reviewer App: the team's own project merges on the per-head word alone"
    return
  fi
  read -r app_id app_slug <<<"$app"
  shown=$(tilde "$key")
  local on="the reviewer App $app_slug ($app_id) is on, but its key $shown"
  if [[ ! -e $key ]]; then
    report "review app" FAIL "$on is missing" "$restore"
    return
  elif [[ ! -f $key ]]; then
    report "review app" FAIL "$on is not a file" "move aside what is at $shown, then $restore"
    return
  fi
  mode=$(stat -L -c %a -- "$key")
  if [[ $mode != 600 ]]; then
    report "review app" FAIL "$on is mode $mode, not 600" "Daniel runs chmod 600 $shown"
    return
  fi

  # Each project that is the team's own: its base's protection, as team-merge reads it.
  if ! own=$(own_projects 2>"$err"); then
    report "review app" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
    return
  fi
  if jq -e '.projects == []' <<<"$own" >/dev/null; then
    report "review app" FAIL "the reviewer App $app_slug ($app_id) is on, but no registered project is the team's own, so no base's protection is read" \
      "register agent-team in projects.toml (team-project --help)"
    return
  fi
  local where=()
  while IFS= read -r project; do
    if ! project_registry "$project" 2>"$err"; then
      report "review app" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
      return
    fi
    repo=$(jq -r .repo <<<"$registry_reply") base=$(jq -r .base <<<"$registry_reply")
    if ! branch=$(bounded 30 gh api "repos/$repo/branches/$base" 2>"$err" </dev/null); then
      report "review app" FAIL "$base on $repo cannot be read from GitHub: $(first_error)" \
        "the github login line's fix, then run team-doctor again"
      return
    fi
    problem=$(ledger_jq 'first(review_app_pin_problems($app))
      | if .kind == "pin" then
          "pin\t\($base)'"'"'s protection on \($repo) does not require agent-review from the reviewer App \($app), so GitHub does not hold its check"
        else
          "admins\t\($base)'"'"'s protection on \($repo) enforces its required checks for \(.level), not everyone, so an administrator could merge past them"
        end' -r --argjson app "$app_id" --arg base "$base" --arg repo "$repo" <<<"$branch") ||
      problem="pin	$base on $repo answered GitHub's branch read with no JSON"
    case ${problem%%$'\t'*} in
      pin)
        report "review app" FAIL "${problem#*$'\t'}" \
          "Daniel takes step 6 of sops/merging.md, agent-review pinned to App $app_id in $base's required checks"
        return
        ;;
      admins)
        report "review app" FAIL "${problem#*$'\t'}" "Daniel turns on enforce_admins in $base's protection on $repo"
        return
        ;;
    esac
    where+=("$base's protection on $repo")
  done < <(jq -r '.projects[]' <<<"$own")
  local joined
  joined=$(printf '%s, ' "${where[@]}")
  report "review app" PASS "the reviewer App $app_slug ($app_id) is on: its key $shown is in place with mode 600, and ${joined%, } requires agent-review from it, enforced for everyone"
}
review_app_check
