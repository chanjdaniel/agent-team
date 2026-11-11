# The notice record's I/O, sourced after team.sh by the scripts that judge notices (team-timers,
# team-uptime):
#
#   # shellcheck source=bin/lib/notices.sh
#   source "$TEAM_LIB/notices.sh"
#
# The record, ~/.local/state/agent-team/notices.json (team-notices/1), and its lifecycle are
# bin/lib/notice.jq's; each write is whole, to a temporary file moved into place, under
# notices.lock beside it. It provides:
#   NOTICES                      the record's path.
#   notices_taken_at             prints the lease record's taken_at as JSON, the holding a
#                                notice opens in: null when lease.json is missing, unreadable or
#                                has none.
#   TEAM_NOTICES_LOCK_SECONDS    how long a writer waits for the lock, 10 s unless set (a test
#                                seam).
#   notices_read                 prints the record, with the old records of the sources not yet
#                                upgraded folded in, writing nothing; with no file, notice_empty
#                                with the folds. Fails, saying "<file> is not a team-notices/1
#                                record" on stderr, for a file that is not one JSON object of it.
#   notices_update <modules> <program> [jq arguments...]
#                                under the lock, reads as notices_read does and runs <program>
#                                with each module of <modules> (space-separated) included in the
#                                order given, the record as input; the program prints an object
#                                whose record is the new record, which is written with written set
#                                to now, and the whole object is printed as one line. A record that
#                                is not team-notices/1 is first set aside as <file>.bad (one file,
#                                overwritten), saying so on stderr, and the program runs on
#                                notice_empty with the folds. Fails, writing nothing and saying why
#                                on stderr, when the lock is not had in time ("another writer held
#                                <lock> for <n> s"), the program fails or the write fails.
#   notices_upgrade <source>...  moves each named source's old record into the record, under the
#                                lock: the record written first, its sources marked upgraded, then
#                                the old field stripped (health: health.json's alerts; offline:
#                                the offline flag rewritten as {since}, still the hold;
#                                login-refused: the login-refused file removed; uptime: each
#                                check's alert in uptime.json). Fails as notices_update
#                                does, the old field left for the next try. A record that lists
#                                every named source upgraded already is neither locked nor
#                                written: only the old field is stripped, under the caller's own
#                                lock of that record.
# The old records folded: health, health.json's alerts; offline, the offline flag's posted;
# login-refused, the login-refused file ({since, reason}); uptime, uptime.json's checks' alerts.
# The offline flag and the login-refused file are read whatever their age, a since they lack taken
# from the file's time; a missing or unreadable record folds nothing.
# shellcheck shell=bash

NOTICES_STATE=$HOME/.local/state/agent-team
NOTICES=$NOTICES_STATE/notices.json
NOTICES_LOCK=$NOTICES_STATE/notices.lock
TEAM_NOTICES_LOCK_SECONDS=${TEAM_NOTICES_LOCK_SECONDS:-10}

# The lease record's taken_at as JSON, null when it has none: the holding a notice opens in.
notices_taken_at() {
  jq -c '.taken_at | strings' "$NOTICES_STATE/lease.json" 2>/dev/null | grep . || echo null
}

# The flag file <file> as an object, its since the file's time when it gives none (a file that is
# not JSON included), or nothing when there is no file: notices_flag <file>
notices_flag() {
  local mtime
  [[ -e $1 ]] || return 0
  mtime=$(date -u -r "$1" +%FT%TZ 2>/dev/null) || mtime=''
  jq -c --arg mtime "$mtime" 'objects | .since = ((.since | strings) // ($mtime | select(. != "")) // null)' "$1" 2>/dev/null ||
    jq -cn --arg mtime "$mtime" '{since: (($mtime | select(. != "")) // null)}'
}

# The old records of the sources with a fold, as one object: {health: {alerts} or null, offline:
# the offline flag or null, "login-refused": the login-refused file or null, uptime: {checks} or
# null}.
notices_old() {
  local health offline refused uptime
  health=$(jq -c 'objects | {alerts: (.alerts // null)}' "$NOTICES_STATE/health.json" 2>/dev/null) || health=''
  offline=$(notices_flag "$NOTICES_STATE/offline")
  refused=$(notices_flag "$NOTICES_STATE/login-refused")
  uptime=$(jq -c 'objects | {checks: (.checks // null)}' "$NOTICES_STATE/uptime.json" 2>/dev/null) || uptime=''
  jq -cn --argjson health "${health:-null}" --argjson offline "${offline:-null}" --argjson refused "${refused:-null}" \
    --argjson uptime "${uptime:-null}" '{health: $health, offline: $offline, "login-refused": $refused, uptime: $uptime}'
}

# Whether the file <file> is one JSON object of team-notices/1: notices_valid <file>
notices_valid() {
  jq -se 'length == 1 and (.[0] | type == "object" and .schema == "team-notices/1")' "$1" >/dev/null 2>&1
}

# The record as it stands, folded with the old records <old>, from the file or from empty; with
# --set-aside, a file that is not a record is moved to <file>.bad first and the fold starts from
# empty: notices_folded <old> [--set-aside]
notices_folded() {
  local base
  if [[ ! -e $NOTICES ]]; then
    base=notice_empty
  elif notices_valid "$NOTICES"; then
    base=.
  elif [[ ${2:-} == --set-aside ]]; then
    mv -f "$NOTICES" "$NOTICES.bad" || return 1
    echo "$NOTICES is not a team-notices/1 record; it is set aside as $NOTICES.bad, and the notices start again from empty" >&2
    base=notice_empty
  else
    echo "$NOTICES is not a team-notices/1 record" >&2
    return 1
  fi
  if [[ $base == . ]]; then
    jq -c -L "$TEAM_LIB" --argjson old "$1" 'include "notice"; notice_upgrade($old | keys_unsorted; $old)' "$NOTICES"
  else
    jq -cn -L "$TEAM_LIB" --argjson old "$1" 'include "notice"; notice_empty | notice_upgrade($old | keys_unsorted; $old)'
  fi
}

notices_read() {
  notices_folded "$(notices_old)"
}

# Take the lock on fd NOTICES_FD, or fail saying who held it; for a subshell, whose end frees it.
notices_lock() {
  mkdir -p "$NOTICES_STATE" || return 1
  exec {NOTICES_FD}>>"$NOTICES_LOCK" || return 1
  flock -w "$TEAM_NOTICES_LOCK_SECONDS" "$NOTICES_FD" && return 0
  echo "another writer held $NOTICES_LOCK for $TEAM_NOTICES_LOCK_SECONDS s" >&2
  return 1
}

# Write the record <record> whole, written now, and move it into place: notices_write <record>
notices_write() {
  if jq -c --arg now "$(date -u +%FT%TZ)" '.written = $now' <<<"$1" >"$NOTICES.$$" &&
    mv -f "$NOTICES.$$" "$NOTICES"; then
    return 0
  fi
  rm -f "$NOTICES.$$"
  echo "cannot write $NOTICES" >&2
  return 1
}

# The run of <program> on the folded record, its record written: notices_apply <old> <modules>
# <program> [jq arguments...]; prints the program's object, its record as written.
notices_apply() {
  local record includes='' module out
  record=$(notices_folded "$1" --set-aside) || return 1
  for module in $2; do includes+="include \"$module\"; "; done
  out=$(jq -c -L "$TEAM_LIB" "${@:4}" "$includes$3" <<<"$record") || return 1
  if ! jq -e '(.record | type) == "object" and .record.schema == "team-notices/1"' <<<"$out" >/dev/null 2>&1; then
    echo "the program gave no team-notices/1 record" >&2
    return 1
  fi
  notices_write "$(jq -c .record <<<"$out")" || return 1
  jq -c --slurpfile record "$NOTICES" '.record = $record[0]' <<<"$out"
}

notices_update() (
  notices_lock || exit 1
  notices_apply "$(notices_old)" "$@" || exit 1
)

# Strip the old field of <source> once its notices are in the record: notices_strip <source>
notices_strip() {
  local file
  case $1 in
    health)
      file=$NOTICES_STATE/health.json
      jq -e 'type == "object" and has("alerts")' "$file" >/dev/null 2>&1 || return 0
      if jq 'del(.alerts)' "$file" >"$file.$$" && mv -f "$file.$$" "$file"; then return 0; fi
      rm -f "$file.$$"
      echo "cannot strip the alerts from $file" >&2
      return 1
      ;;
    offline)
      # Only a flag that holds more than its since is rewritten, so the hold never goes meanwhile.
      file=$NOTICES_STATE/offline
      jq -e 'type == "object" and (keys - ["since"]) != []' "$file" >/dev/null 2>&1 || return 0
      if jq -c '{since}' "$file" >"$file.$$" && mv -f "$file.$$" "$file"; then return 0; fi
      rm -f "$file.$$"
      echo "cannot rewrite $file as the hold alone" >&2
      return 1
      ;;
    login-refused)
      file=$NOTICES_STATE/login-refused
      [[ -e $file ]] || return 0
      rm -f "$file" && return 0
      echo "cannot remove $file" >&2
      return 1
      ;;
    uptime)
      file=$NOTICES_STATE/uptime.json
      jq -e 'type == "object" and (.checks | type) == "object" and any(.checks[]; type == "object" and has("alert"))' \
        "$file" >/dev/null 2>&1 || return 0
      if jq '.checks |= map_values(if type == "object" then del(.alert) else . end)' "$file" >"$file.$$" &&
        mv -f "$file.$$" "$file"; then
        return 0
      fi
      rm -f "$file.$$"
      echo "cannot strip the alerts from $file" >&2
      return 1
      ;;
  esac
}

# Whether the record lists every source of the JSON array <sources> upgraded:
# notices_upgraded <sources>
notices_upgraded() {
  [[ -e $NOTICES ]] && notices_valid "$NOTICES" &&
    jq -e --argjson sources "$1" '.upgraded as $u | all($sources[]; . as $s | any($u[]?; . == $s))' \
      "$NOTICES" >/dev/null 2>&1
}

notices_upgrade() (
  local source sources
  sources=$(jq -cn '$ARGS.positional' --args "$@")
  # A record that holds every source upgraded already is neither locked nor written again, so a
  # run whose move is done never waits on another writer for it.
  # The read folds every source not yet upgraded, so the program only passes its record on.
  if ! notices_upgraded "$sources"; then
    notices_lock || exit 1
    if ! notices_upgraded "$sources"; then
      notices_apply "$(notices_old)" notice '{record: .}' >/dev/null || exit 1
    fi
  fi
  for source in "$@"; do notices_strip "$source" || exit 1; done
)
