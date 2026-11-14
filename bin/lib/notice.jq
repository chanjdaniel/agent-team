# The notice module: the one lifecycle of every notice the heartbeat gives Daniel in #coordinator
# of a standing problem, none -> open -> posted -> (reminded)* -> ended -> closed. Its callers judge
# their notices through it and do the I/O (Discord, the record's file, its lock): bin/team-timers
# for the health alerts, the offline hold's posts, the login refusal's and the quota's crossings,
# and bin/team-uptime for the production outages (through bin/lib/uptime.jq), both through
# bin/lib/notices.sh. These are pure functions of the record, a source's standing problems, the
# lease record's taken_at and now; nothing here knows a source's texts or thresholds.
# No includes. Included as: jq -L bin/lib 'include "notice"; ...'
#
# The record, ~/.local/state/agent-team/notices.json, is team-notices/1, one per machine:
#   {schema, written (when it was last written),
#    upgraded: the sources whose old record has been moved in, each never folded again,
#    notices: {<id>: {
#      source (health, offline, login-refused, uptime or quota), key (the source's own key: a
#        health problem's key, "<project>/<name>", "<window>/<threshold>/<resets_at>", or the
#        source's name for a single notice),
#      state: open (not yet told), posted (told) or ended (its end action is due),
#      since (when its problem began, as the source dates it, null allowed), text (its open post's
#        text as last judged, null for a source that writes each post from its own state),
#      holding (the lease record's taken_at when it opened, null when the lease record had none
#        or its source is judged with no holding, as quota is),
#      opened (when it opened), tried (when its open post last failed, null when none has),
#      posted (when its open post went through, null until then), message (Discord's id of that
#      post, null when none or Discord gave none), reminded (when its last reminder went through,
#      null for none), ended (when its problem ended, null while it stands), detail (the source's
#      own extra fields, null for none)}}}
# A notice's id is "<source>/<key>", or the source's name for a single notice (key == source).
# Closed is not a stored state: a closed notice is removed. Keys the module does not name are kept
# as they are. Times are UTC ISO 8601, as date -u +%FT%TZ writes.

# The empty record, for a machine that has none yet.
def notice_empty: {schema: "team-notices/1", written: null, upgraded: [], notices: {}};

# The one table, a row per source: whether a notice's open post is tried again at each judging
# after one failed (retry_open), what its end does (end: "edit" its message, "post" a message, or
# null for nothing), whether a notice never posted gets the end action too at its end
# (unposted_end; else it closes silently), and whether a failed end action is tried again
# (retry_end; else the notice closes all the same). Reminders are the judging's parameter, not a
# row.
def notice_sources:
  {health: {retry_open: true, end: "edit", unposted_end: false, retry_end: false},
   offline: {retry_open: false, end: "post", unposted_end: true, retry_end: false},
   "login-refused": {retry_open: true, end: null, unposted_end: false, retry_end: false},
   uptime: {retry_open: true, end: "post", unposted_end: false, retry_end: true},
   quota: {retry_open: true, end: null, unposted_end: false, retry_end: false}};

# The id of the notice of <source>'s problem <key>: notice_id($source; $key)
def notice_id($source; $key): if $key == $source then $source else "\($source)/\($key)" end;

# Now, a number of seconds or a UTC time, as a UTC time.
def notice_time: if type == "number" then floor | todate else . end;

# Whether the notice (the input) opened in an earlier holding of the lease than the one that began
# at $taken_at: its holding another time, or, with none, its post (else its opening) before it. A
# $taken_at that is not a time makes no notice earlier: notice_past($taken_at)
def notice_past($taken_at):
  ($taken_at | type) == "string"
  and (if (.holding | type) == "string" then .holding != $taken_at
       else ((.posted // .opened) | type) == "string" and (.posted // .opened) < $taken_at end);

# One judging of $source's notices in the record (the input) at $now (seconds or a UTC time):
# notice_plan($source; $wanted; $taken_at; $now; $remind_minutes), $wanted the source's problems
# that stand now, in its own order, each {key, since, text, detail} (text and detail may be null),
# $taken_at the lease record's taken_at (null when none), $remind_minutes the minutes after which a
# posted notice is reminded (null for never). Gives {record, actions, closed}: the record with
# every open and silent close applied; the actions the caller performs, each {do, id, notice}, do
# one of post, remind or end, the posts and reminders in $wanted's order, then the ends in the
# record's order; and the silent closes, each {id, notice, why}. Its rules, for the source's
# notices only:
#   1. A notice of an earlier holding (notice_past) is closed, why earlier-holding, so a problem
#      that stands is opened afresh by rule 4.
#   2. A notice whose key is wanted: an open one gets a post action, with this judging's text and
#      detail and its since kept, when its source retries its open post or it was never tried; an
#      ended one goes back to posted, its ended cleared; then a posted one gets a remind action once
#      $remind_minutes have passed since its last reminder, else its post. A posted notice keeps
#      its text whatever its reason becomes.
#   3. A notice whose key is not wanted: an open one closes, why unposted, unless its source gives
#      an unposted notice the end action (offline), when it is ended with an end action; a posted
#      or ended one by its source's end: none closes it, why ended; an edit with no message closes
#      it, why no-message; else it is ended (its ended $now unless set) with an end action.
#   4. A wanted key with no notice opens one, holding $taken_at, with a post action.
def notice_plan($source; $wanted; $taken_at; $now; $remind_minutes):
  notice_sources[$source] as $row
  | ($now | notice_time) as $at
  | ($wanted | map(.key)) as $keys
  | {record: ((if type == "object" then . else notice_empty end) | .notices = (.notices // {})),
     actions: [], closed: []}
  | reduce (.record.notices | to_entries[] | select(.value.source == $source and (.value | notice_past($taken_at)))) as $e (.;
      .closed += [{id: $e.key, notice: $e.value, why: "earlier-holding"}] | del(.record.notices[$e.key]))
  | reduce $wanted[] as $w (.;
      notice_id($source; $w.key) as $id
      | .record.notices[$id] as $n
      | if $n == null then
          .record.notices[$id] = {source: $source, key: $w.key, state: "open", since: $w.since, text: $w.text,
            holding: $taken_at, opened: $at, tried: null, posted: null, message: null, reminded: null,
            ended: null, detail: $w.detail}
          | .actions += [{do: "post", id: $id, notice: .record.notices[$id]}]
        elif $n.state == "open" then
          if $row.retry_open or $n.tried == null then
            .record.notices[$id] += {text: $w.text, detail: $w.detail}
            | .actions += [{do: "post", id: $id, notice: .record.notices[$id]}]
          else . end
        else
          (if $n.state == "ended" then .record.notices[$id] += {state: "posted", ended: null} else . end)
          | .record.notices[$id] as $p
          | ($p.reminded // $p.posted) as $last
          | if ($remind_minutes | type) == "number" and ($last | type) == "string"
              and ($at | fromdateiso8601) - ($last | fromdateiso8601) >= $remind_minutes * 60 then
              .actions += [{do: "remind", id: $id, notice: $p}]
            else . end
        end)
  | reduce (.record.notices | to_entries[]
      | select(.value.source == $source and (.value.key as $k | any($keys[]; . == $k) | not))) as $e (.;
      $e.key as $id | $e.value as $n
      | if $n.state == "open" and ($row.unposted_end | not) then
          .closed += [{id: $id, notice: $n, why: "unposted"}] | del(.record.notices[$id])
        elif $n.state != "open" and $row.end == null then
          .closed += [{id: $id, notice: $n, why: "ended"}] | del(.record.notices[$id])
        elif $n.state != "open" and $row.end == "edit" and $n.message == null then
          .closed += [{id: $id, notice: $n, why: "no-message"}] | del(.record.notices[$id])
        else
          .record.notices[$id] += {state: "ended", ended: ($n.ended // $at)}
          | .actions += [{do: "end", id: $id, notice: .record.notices[$id]}]
        end);

# The outcome of one action of a judging, at $at, in the record (the input):
# notice_done($id; $do; $ok; $message; $at). A post that went through makes the notice posted,
# with its message ($message, null for none) and no failed try; one that failed keeps it open,
# tried at $at. A reminder that went through is dated $at; one that failed changes nothing. An end
# that went through removes the notice, and one that failed too, unless its source retries its end
# action, when it stays ended. A notice the record no longer holds is left alone.
def notice_done($id; $do; $ok; $message; $at):
  if (.notices[$id] | type) != "object" then .
  elif $do == "post" then
    if $ok then .notices[$id] += {state: "posted", posted: $at, message: $message, tried: null}
    else .notices[$id].tried = $at end
  elif $do == "remind" then
    if $ok then .notices[$id].reminded = $at else . end
  elif $do == "end" then
    if $ok or (notice_sources[.notices[$id].source].retry_end | not) then del(.notices[$id]) else . end
  else . end;

# Remove the notice <id>, for the closes a caller decides itself: notice_close($id)
def notice_close($id): del(.notices[$id]);

# The notices an old record holds, each {id, notice}, holding null and opened its posted, else its
# since, else now. The health record's alerts ({<key>: {since, text, posted, message}}): one posted
# is posted, with its message; any other is open, never tried: notice_fold_health
def notice_fold_health:
  (now | floor | todate) as $now
  | [(if type == "object" then .alerts else null end) | objects | to_entries[]
      | select(.value | type == "object")
      | .key as $key | .value as $a
      | ($a.posted | if type == "string" then . else null end) as $posted
      | {id: notice_id("health"; $key),
         notice: {source: "health", key: $key, state: (if $posted then "posted" else "open" end),
           since: $a.since, text: $a.text, holding: null, opened: ($posted // $a.since // $now),
           tried: null, posted: $posted, message: (if $posted then $a.message else null end),
           reminded: null, ended: null, detail: null}}];

# team-uptime's state (uptime.json, {checks: {<project>/<name>: {alert}}}), its checks' alerts
# ({since, posted, reminded, message, back}): one never posted is open, never tried; one posted
# with no back is posted, with its message and reminded; one with a back is ended, at its back:
# notice_fold_uptime
def notice_fold_uptime:
  (now | floor | todate) as $now
  | [(if type == "object" then .checks else null end) | objects | to_entries[]
      | select(.value | type == "object" and (.alert | type) == "object")
      | .key as $key | .value.alert as $a
      | ($a.posted | if type == "string" then . else null end) as $posted
      | ($a.back | if type == "string" then . else null end) as $back
      | {id: notice_id("uptime"; $key),
         notice: {source: "uptime", key: $key,
           state: (if $posted == null then "open" elif $back == null then "posted" else "ended" end),
           since: $a.since, text: null, holding: null, opened: ($posted // $a.since // $now),
           tried: null, posted: $posted, message: (if $posted then $a.message else null end),
           reminded: (if $posted then $a.reminded else null end), ended: (if $posted then $back else null end),
           detail: null}}];

# team-timers' offline flag ({since, posted}, its since filled from the file's time when it has
# none): one whose posted is true is posted, at its since; any other is open, tried at its since,
# so it is not posted again while the hold lasts and its back post carries the outage line:
# notice_fold_offline
def notice_fold_offline:
  [objects | (.since | strings) as $since
    | (.posted == true) as $told
    | {id: "offline",
       notice: {source: "offline", key: "offline", state: (if $told then "posted" else "open" end),
         since: $since, text: null, holding: null, opened: $since,
         tried: (if $told then null else $since end), posted: (if $told then $since else null end),
         message: null, reminded: null, ended: null, detail: null}}];

# team-timers' login-refused file ({since, reason}, its since filled from the file's time when it
# has none), written when the refusal's post was tried: posted, at its since, with its reason:
# notice_fold_login_refused
def notice_fold_login_refused:
  [objects | (.since | strings) as $since
    | {id: "login-refused",
       notice: {source: "login-refused", key: "login-refused", state: "posted", since: $since, text: null,
         holding: null, opened: $since, tried: null, posted: $since, message: null, reminded: null,
         ended: null, detail: {reason: ((.reason | strings) // null)}}}];

# The notices of the old record $old of <source>, or none for a source with no fold:
# notice_fold($source; $old)
def notice_fold($source; $old):
  if $source == "health" then ($old | notice_fold_health)
  elif $source == "uptime" then ($old | notice_fold_uptime)
  elif $source == "offline" then ($old | notice_fold_offline)
  elif $source == "login-refused" then ($old | notice_fold_login_refused)
  else [] end;

# Move the old records' notices into the record (the input): notice_upgrade($sources; $old), $old
# an object of each named source's old record (null for none). For each source not yet upgraded,
# each of its old notices whose id the record does not already hold is added, and the source is
# marked upgraded, so a field left in an old record after its move never brings a notice back.
def notice_upgrade($sources; $old):
  (if type == "object" then . else notice_empty end)
  | .upgraded = (.upgraded // []) | .notices = (.notices // {})
  | reduce ($sources[] | strings) as $s (.;
      if any(.upgraded[]; . == $s) then .
      else
        reduce notice_fold($s; $old[$s])[] as $f (.;
          if .notices[$f.id] == null then .notices[$f.id] = $f.notice else . end)
        | .upgraded += [$s]
      end);
