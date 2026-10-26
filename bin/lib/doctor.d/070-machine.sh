# machine       This machine's team name, ~/.config/agent-team/machine.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

if machine=$(machine_name 2>"$err"); then
  report machine PASS "$machine"
else
  reason=$(first_error)
  report machine FAIL "${reason%%; write one with: *}" "echo <name> > ~/.config/agent-team/machine"
fi
