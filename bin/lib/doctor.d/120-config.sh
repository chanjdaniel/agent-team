# config        `team-config diff`: warns on each way this machine's Claude config differs from
#               the team home's machine/claude/, plugins and memory aside.
# plugins       Fails while a marketplace or plugin of machine/claude/plugins.txt is missing here
#               (`team-config diff`), with the commands that add them.
# memory        `team-config diff`: warns while a registered project with its primary checkout
#               here does not keep its auto memory in the team home's memory/<project>/.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# The config, plugins and memory lines: one team-config diff.
rc=0
config=$(TEAM_HOME=$TEAM_HOME bounded 60 "$bin/team-config" diff --json 2>"$err" </dev/null) || rc=$?
if ((rc > 1)) || ! jq -e 'type == "array"' <<<"$config" >/dev/null 2>&1; then
  reason=$(first_error)
  reason=${reason:-team-config diff exited $rc}
  report config WARN "$reason" "fix what team-config names, then run team-doctor again"
  report plugins FAIL "unknown, since team-config diff did not answer: $reason" "the config line's fix"
  report memory WARN "unknown, since team-config diff did not answer: $reason" "the config line's fix"
else
  config_others=$(jq -r '[.[] | select(.state != "not installed" and .state != "not added" and .item != "plugins"
    and (.item | startswith("memory ") | not))
    | "\(.item) \(.state)"] | join(", ")' <<<"$config")
  if [[ -z $config_others ]]; then
    report config PASS "this machine's Claude config is the team home's"
  else
    report config WARN "$config_others" \
      "team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's)"
  fi
  if jq -e 'any(.[]; .item == "plugins")' <<<"$config" >/dev/null; then
    report plugins FAIL "\`claude plugin list\` did not answer" "install Claude Code and sign in (the tool claude and claude login lines)"
  else
    plugins_missing=$(jq -r '[.[] | select(.state == "not installed" or .state == "not added") | .item] | join(", ")' <<<"$config")
    if [[ -z $plugins_missing ]]; then
      report plugins PASS "every marketplace and plugin of plugins.txt is installed"
    else
      report plugins FAIL "missing $plugins_missing" "$(jq -r '[.[] | select(.state == "not added") | "claude plugin marketplace add \(.item | ltrimstr("marketplace "))"]
        + [.[] | select(.state == "not installed") | "claude plugin install \(.item | ltrimstr("plugin ")) --scope user"]
        | join("; ")' <<<"$config")"
    fi
  fi
  memory=$(jq -r '[.[] | select(.item | startswith("memory ")) | "\(.item) \(.state)"] | join(", ")' <<<"$config")
  if [[ -z $memory ]]; then
    report memory PASS "every project here keeps its auto memory in the team home"
  else
    report memory WARN "$memory" "team-config apply"
  fi
fi
