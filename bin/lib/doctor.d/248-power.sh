# power         macOS only: the power source, from pmset -g batt's first line. Passes on AC
#               power ("on AC power; keep the lid open while this Mac holds the team, since
#               caffeinate keeps it from idle sleep only"); warns on battery power, since a closed
#               lid or a flat battery sleeps the Mac and stops the team, and when pmset is missing,
#               fails or names neither source; never fails, since a standby on battery is fine.
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, from the os check
# reads state from: 010-os.sh

if [[ $os == macos ]]; then
  power=''
  ! command -v pmset >/dev/null || power=$(pmset -g batt 2>&1 </dev/null) || true
  power=$(grep -m1 . <<<"$power" || true)
  case $power in
    "Now drawing from 'AC Power'"*)
      report power PASS "on AC power; keep the lid open while this Mac holds the team, since caffeinate keeps it from idle sleep only"
      ;;
    "Now drawing from 'Battery Power'"*)
      report power WARN "on battery power: a closed lid or a flat battery sleeps this Mac and stops the team, and the lease goes stale after 60 minutes" \
        "plug this Mac in, and keep its lid open while it holds the team"
      ;;
    *)
      report power WARN "could not read the power source (pmset -g batt: ${power:-no output})" \
        "run pmset -g batt and read its first line"
      ;;
  esac
fi
