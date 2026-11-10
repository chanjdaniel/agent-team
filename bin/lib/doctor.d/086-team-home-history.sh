# team home history
#               The team home shares history with origin's dev as last fetched (no fetch here):
#               fails when HEAD and refs/remotes/origin/dev have no merge base, a clone from
#               before a rewrite of the records' history (the records rewrite of 2026-10-28), which
#               nothing should read or pull; its fix is the re-clone of sops/records-rewrite.md
#               step 10. Ahead or behind passes, since team-resume and the salvage lines judge
#               those. team-bootstrap's machine stage fetches the team home and stops on it. Left
#               out without origin/dev, and while the team home line fails.
# shellcheck shell=bash
# shellcheck disable=SC2154 # home_ok and home_shown, from the team home check
# reads state from: 080-team-home.sh

if ((home_ok)) && git -C "$TEAM_HOME" rev-parse -q --verify refs/remotes/origin/dev >/dev/null; then
  if git -C "$TEAM_HOME" merge-base HEAD refs/remotes/origin/dev >/dev/null; then
    report "team home history" PASS "shares history with origin's dev"
  else
    report "team home history" FAIL "$home_shown shares no history with origin's dev, so its history was rewritten since it was cloned (the records rewrite of 2026-10-28, say), and nothing should read or pull it" \
      "re-clone it, keeping this one aside, as sops/records-rewrite.md step 10 says: mv $home_shown $home_shown.pre-rewrite, a fresh clone of dev with lease added, its records guard, and the ignored files carried over; never git pull into this clone"
  fi
fi
