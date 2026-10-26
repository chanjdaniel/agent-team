# heavy runs    Who holds the machine's heavy-run lock (team-heavy status): free, or held by
#               the run its line names, which every other heavy run waits for; warns only when
#               team-heavy cannot answer (on macOS without Homebrew's GNU tools, say).
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# One at a time on this machine, so a holder is the queue working, not a problem.
if ! heavy=$("$bin/team-heavy" status 2>"$err"); then
  report "heavy runs" WARN "\`team-heavy status\` did not answer: $(first_error)" "fix what it names, then run team-doctor again"
elif [[ $heavy == free ]]; then
  report "heavy runs" PASS "free (team-heavy queues full test suites and local checks)"
else
  report "heavy runs" PASS "$heavy"
fi
