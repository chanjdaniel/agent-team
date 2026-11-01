# records       The team home's records pass the checks the code holds them to: the ledger
#               `team-log --check`, the registry `team-project --check`, and every enabled
#               secret of machine/secrets.json has its row in machine/secrets.md; fails naming
#               each problem (a check's first, with its count). A ledger that passes but holds
#               sent_back or before numbers as strings (the form team-log stored before) warns,
#               naming team-log --fix-sent-back.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's, and secrets and secrets_read, from the secrets check

# The team home's ledger, registry and secrets description, each problem named.
records_problems=() ledger_strings=''
if ledger_out=$(TEAM_HOME=$TEAM_HOME "$bin/team-log" --check 2>"$err" </dev/null); then
  ledger_count=$(cut -d' ' -f1,2 <<<"${ledger_out##*: }")
  if [[ $ledger_out =~ \;\ 1\ holds\ whole\ numbers\ as\ strings ]]; then
    ledger_strings="1 of its lines holds"
  elif [[ $ledger_out =~ \;\ ([0-9]+)\ hold\ whole\ numbers\ as\ strings ]]; then
    ledger_strings="${BASH_REMATCH[1]} of its lines hold"
  fi
else
  records_problems+=("$(first_problem)")
fi
if registry_out=$(team_project --check 2>"$err" </dev/null); then
  registry_count=$(cut -d' ' -f1,2 <<<"${registry_out##*: }")
else
  records_problems+=("$(first_problem)")
fi
if [[ ! -f $TEAM_HOME/machine/secrets.md ]]; then
  records_problems+=("no machine/secrets.md in $TEAM_HOME")
elif ((!secrets_read)); then
  records_problems+=("machine/secrets.md unchecked, since team-secrets refused the manifest (the secrets line)")
else
  undescribed=()
  while IFS= read -r id; do
    grep -qF "| \`$id\` |" "$TEAM_HOME/machine/secrets.md" || undescribed+=("$id")
  done < <(jq -r '.[].id' <<<"$secrets")
  ((${#undescribed[@]} == 0)) ||
    records_problems+=("machine/secrets.md has no row for $(printf '%s, ' "${undescribed[@]}" | sed 's/, $//')")
fi
if ((${#records_problems[@]} == 0)) && [[ -n $ledger_strings ]]; then
  report records WARN "the ledger meets its contract ($ledger_count), but $ledger_strings whole numbers as strings in a sent_back or before, the registry passes ($registry_count) and machine/secrets.md describes every enabled secret" \
    "run team-log --fix-sent-back, which stores them as numbers"
elif ((${#records_problems[@]} == 0)); then
  report records PASS "the ledger meets its contract ($ledger_count), the registry passes ($registry_count) and machine/secrets.md describes every enabled secret"
else
  report records FAIL "$(printf '%s; ' "${records_problems[@]}" | sed 's/; $//')" \
    "fix what it names in the team home (team-log --check and team-project --check list every problem), then run team-doctor again"
fi
