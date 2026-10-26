# secret <id>   `team-secrets check`: fails for each enabled secret of machine/secrets.json that
#               is missing, empty or off its mode here, with team-secrets restore (Daniel's, in
#               their own terminal); no byte of a secret is read.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's
# shellcheck disable=SC2034 # secrets_read, for the records check

# team-secrets check, from each file's existence, size and mode alone.
rc=0
secrets=$(TEAM_HOME=$TEAM_HOME bounded 30 "$bin/team-secrets" check --json 2>"$err" </dev/null) || rc=$?
secrets_read=1
if ((rc > 1)) || ! jq -e 'type == "array"' <<<"$secrets" >/dev/null 2>&1; then
  secrets_read=0
  reason=$(first_error)
  report secrets FAIL "${reason:-team-secrets check exited $rc}" "fix what team-secrets names, then run team-doctor again"
else
  while IFS=$'\t' read -r id verdict reason; do
    if [[ $verdict == PASS ]]; then
      report "secret $id" PASS "in place"
    elif [[ $reason == "not a file" ]]; then
      report "secret $id" FAIL "$reason" "move aside what is at its target in machine/secrets.json, then Daniel runs team-secrets restore in their own terminal"
    else
      report "secret $id" FAIL "$reason" "Daniel runs team-secrets restore in their own terminal"
    fi
  done < <(jq -r '.[] | [.id, .verdict, .reason] | @tsv' <<<"$secrets")
fi
