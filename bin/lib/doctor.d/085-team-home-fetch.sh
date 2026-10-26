# team home fetch
#               The team home's remote.origin.fetch is exactly dev's and lease's refspecs, as
#               SETUP.md clones it, and it keeps no other remote-tracking branch of origin: the
#               wip/* and salvage/* branches on its origin are whole project histories, which
#               the scripts reach by URL and a fetch of every branch downloads for nothing (T56).
#               Warns otherwise, its fix `git remote set-branches origin dev lease` and the
#               `git branch -r -d` of the others; team-bootstrap's machine stage runs it. Left
#               out while the team home line fails or warns.
# shellcheck shell=bash
# shellcheck disable=SC2154 # home_ok and home_shown, from the team home check

if ((home_ok)); then
  mapfile -t fetch_specs < <(git -C "$TEAM_HOME" config --get-all remote.origin.fetch || true)
  # Every remote-tracking branch of origin but its HEAD and the two it fetches.
  mapfile -t fetch_kept < <(git -C "$TEAM_HOME" for-each-ref --format='%(refname:lstrip=2)' refs/remotes/origin/ |
    grep -vxE 'origin/(HEAD|dev|lease)' || true)
  fetch_problems=() fetch_fixes=()
  if [[ $(printf '%s\n' "${fetch_specs[@]}" | sort | paste -sd ' ') != \
    '+refs/heads/dev:refs/remotes/origin/dev +refs/heads/lease:refs/remotes/origin/lease' ]]; then
    fetch_shown='no branch'
    ((${#fetch_specs[@]} == 0)) || fetch_shown=$(printf '%s, ' "${fetch_specs[@]}" | sed 's/, $//')
    fetch_problems+=("fetches $fetch_shown, not only dev and lease")
    fetch_fixes+=("git -C $home_shown remote set-branches origin dev lease")
  fi
  if ((${#fetch_kept[@]})); then
    fetch_problems+=("keeps $(printf '%s, ' "${fetch_kept[@]}" | sed 's/, $//')")
    fetch_fixes+=("git -C $home_shown branch -r -d ${fetch_kept[*]}")
  fi
  if ((${#fetch_problems[@]})); then
    report "team home fetch" WARN "$(printf '%s, and ' "${fetch_problems[@]}" | sed 's/, and $//')" \
      "$(printf '%s && ' "${fetch_fixes[@]}" | sed 's/ && $//')"
  else
    report "team home fetch" PASS "fetches only dev and lease"
  fi
fi
