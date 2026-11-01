# team home pack
#               The team home's loose objects and the size of its packs. Warns at twice
#               PACK_LOOSE (bin/lib/team.sh), since the lease holder's heartbeat packs it at
#               PACK_LOOSE (team-timers run's pack step), so a heartbeat that is off or whose
#               pack fails (its log says why) lets them pile up; its fix packs it now. Left out
#               while the team home line fails.
# shellcheck shell=bash
# shellcheck disable=SC2154 # home_ok and home_shown, from the team home check

if ((home_ok)); then
  if ! home_loose=$(loose_objects 2>"$err"); then
    report "team home pack" WARN "cannot count its loose objects: $(first_error)" "git -C $home_shown count-objects -v"
  elif ((home_loose >= 2 * PACK_LOOSE)); then
    report "team home pack" WARN "$home_loose loose objects, $(pack_size) in packs; the lease holder's heartbeat packs it at $PACK_LOOSE (team-timers run's pack step)" \
      "git -C $home_shown gc --quiet"
  else
    report "team home pack" PASS "$home_loose loose objects (the heartbeat packs it at $PACK_LOOSE), $(pack_size) in packs"
  fi
fi
