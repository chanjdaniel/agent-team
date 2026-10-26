# records       The team home's records pass the checks the code holds them to: the ledger
#               `team-log --check`, the registry `team-project --check`, and every enabled
#               secret of machine/secrets.json has its row in machine/secrets.md; fails naming
#               each problem (a check's first, with its count).
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's, and secrets and secrets_read, from the secrets check

# The team home's ledger, registry and secrets description, each problem named.
records_problems=()
if ledger_out=$(TEAM_HOME=$TEAM_HOME "$bin/team-log" --check 2>"$err" </dev/null); then
  ledger_count=$(cut -d' ' -f1,2 <<<"${ledger_out##*: }")
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
if ((${#records_problems[@]} == 0)); then
  report records PASS "the ledger meets its contract ($ledger_count), the registry passes ($registry_count) and machine/secrets.md describes every enabled secret"
else
  report records FAIL "$(printf '%s; ' "${records_problems[@]}" | sed 's/; $//')" \
    "fix what it names in the team home (team-log --check and team-project --check list every problem), then run team-doctor again"
fi
