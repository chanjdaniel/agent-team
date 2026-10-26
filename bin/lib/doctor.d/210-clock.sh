# clock         Within 60 s of the Date header of https://api.github.com (curl -sI); warns.
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, from the os check

# awk reads to the end, since a reader that stopped at the Date line would break curl's later
# writes, and pipefail would then throw the Date away.
github_date=$(bounded 30 curl -sSI --max-time 20 https://api.github.com 2>/dev/null </dev/null |
  awk 'tolower($1) == "date:" && !found { found = 1; sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print }') ||
  github_date=''
if [[ -n $github_date ]] && github_epoch=$(date -d "$github_date" +%s 2>/dev/null); then
  skew=$((github_epoch - $(date +%s)))
  if ((skew > 60)); then
    direction=behind
  elif ((skew < -60)); then
    direction="ahead of" skew=$((-skew))
  else
    direction=''
  fi
  if [[ -z $direction ]]; then
    report clock PASS "within 60 s of GitHub's"
  else
    clock_fix="sudo timedatectl set-ntp true"
    [[ $os != macos ]] || clock_fix="sudo systemsetup -setusingnetworktime on"
    report clock WARN "this clock is $skew s $direction GitHub's" "$clock_fix"
  fi
else
  report clock WARN "cannot read the Date of https://api.github.com" "check the network, then run team-doctor again"
fi
