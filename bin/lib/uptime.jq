# The uptime module: the one place that says when a production check is down and what each of
# team-uptime's posts in #coordinator says; its outages are notices of the uptime source, whose
# lifecycle (when each is posted, reminded and ended) is bin/lib/notice.jq's. bin/team-uptime does
# the I/O (the registry, the fetches, the known-good probe, Discord, the state file and the notice
# record); these are pure functions of the previous state, the notice record, the registry's
# checks, this run's results, now, the lease record's taken_at and the limits.
# jq 1.7. Includes notice, so a caller includes both, uptime first, on one line:
#   jq -L bin/lib 'include "uptime"; include "notice"; ...'
include "notice";
#
# The state, ~/.local/state/agent-team/uptime.json, is team-uptime/1, each check's counting:
#   {schema, written (when a run last wrote it),
#    checks: {"<project>/<name>": {project, name, url, expect,
#      checked (the UTC time of its last counted result), ok, reason (the last failure's, null
#      when up), failures (counted failures in a row, 0 when the last was good), since (the UTC
#      time of the streak's first failure, null when up)}}}
# A check's open outage is the notice uptime/<project>/<name> of the notice record,
# ~/.local/state/agent-team/notices.json (bin/lib/notice.jq's header describes it): its since the
# outage's start, posted and message its down post's, reminded its last still-down post's, and
# ended when it answered again, its back post due. A check's alert key, from before the notice
# record ({since, posted, reminded, message, back}), is the old record the notice record's first
# write moves there (bin/lib/notices.sh) and team-uptime run strips. Keys it does not name are
# kept as they are. Times are UTC ISO 8601, as date -u +%FT%TZ writes.

# The thresholds, each defined here once: a check that fails `down_runs` runs in a row is down; a
# failure more than `gap_minutes` after the check's last counted result counts as the first again
# (the machine slept, or the heartbeat stopped); a check still down `remind_minutes` after its
# down post, or its last reminder, is due a reminder (TEAM_UPTIME_REMIND_MINUTES replaces it); a
# failure's reason is cut to `reason_cut` characters, a post to `post_cut`, Discord's limit, and
# the status line to `line_cut`, as the digest's resources line is.
def uptime_limits: {down_runs: 2, gap_minutes: 15, remind_minutes: 240, reason_cut: 200, post_cut: 2000, line_cut: 200};

# A state with no check in it, for a machine that has none yet.
def uptime_empty: {schema: "team-uptime/1", written: null, checks: {}};

# Cut a text to <n> characters, its last three "..." when cut: uptime_cut($n)
def uptime_cut($n): if length > $n then .[:$n - 3] + "..." else . end;

def uptime_epoch: fromdateiso8601;

# A UTC time as this machine's local hours and minutes, as the heartbeat's posts write it.
def uptime_clock: uptime_epoch | strflocaltime("%H:%M");

# A number of minutes as "<n> minutes", "<h> hours" or "<h> hours <n> minutes", 1 singular.
def uptime_duration:
  def unit($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
  floor as $all | ($all / 60 | floor) as $h | ($all % 60) as $m
  | if $h == 0 then unit($m; "minute")
    elif $m == 0 then unit($h; "hour")
    else "\(unit($h; "hour")) \(unit($m; "minute"))" end;

# The minutes from the UTC time <from> to the UTC time <to>: uptime_minutes($from; $to)
def uptime_minutes($from; $to): (($to | uptime_epoch) - ($from | uptime_epoch)) / 60;

# A check's key in the state: "<project>/<name>".
def uptime_key: "\(.project)/\(.name)";

# A reason as the end of a sentence: one trailing period dropped, so the post adds its own.
def uptime_sentence: rtrimstr(".");

# The texts of one check's posts, the check's state as input, $notice its outage's notice.
def uptime_down_text($machine; $notice):
  "Production down: \(.project) \(.name) (<\(.url)>) since \($notice.since | uptime_clock), \(.failures) checks in a row from \($machine): \(.reason | uptime_sentence).";
def uptime_still_text($now; $notice):
  "Production still down: \(.project) \(.name) (<\(.url)>) since \($notice.since | uptime_clock), \(uptime_minutes($notice.since; $now) | uptime_duration): \(.reason | uptime_sentence).";
def uptime_back_text($notice):
  "Production back: \(.project) \(.name) (<\(.url)>) answers again at \($notice.ended | uptime_clock), down since \($notice.since | uptime_clock) (\(uptime_minutes($notice.since; $notice.ended) | uptime_duration)).";

# One check's new counting from its previous one (null for none) and this run's result {ok,
# reason}: uptime_count($check; $result; $now; $limits), the previous state as input.
def uptime_count($check; $result; $now; $limits):
  . as $prev
  | ($check | {project, name, url, expect}) as $id
  | if $result.ok then
      ($prev // {}) + $id + {checked: $now, ok: true, reason: null, failures: 0, since: null}
    else
      (($prev.failures // 0) > 0 and $prev.checked != null
        and uptime_minutes($prev.checked; $now) <= $limits.gap_minutes) as $streak
      | (if $streak then $prev.failures + 1 else 1 end) as $failures
      | ($prev // {}) + $id
        + {checked: $now, ok: false, reason: ($result.reason | uptime_cut($limits.reason_cut)),
           failures: $failures, since: (if $streak then $prev.since else $now end)}
    end;

# One round of checks: uptime_round($checks; $results; $now; $machine; $limits; $taken_at), the
# input {state, record}, the previous state (uptime_empty for none) and the notice record
# (notice_empty for none), $checks the registry's [{project, name, url, expect}] in registry order,
# $results {"<project>/<name>": {ok, reason}} this run's, $taken_at the lease record's taken_at
# (null for none). Gives {state, record, lines, posts}: the new state and notice record, the lines
# to print, and the posts due, [{kind, keys, content}] in the order to make them (down, still
# down, then back), each one message with a line per check in registry order.
# A check in the state that the registry no longer names, or names with another url or expect, is
# dropped first, so a changed one starts fresh, and its outage, or one of a check the registry
# does not name, is closed without a post, with a line when its down post had been made. A check
# is then wanted down when it is not up and has failed down_runs runs in a row, or has an outage
# not of an earlier holding of the lease (notice_past); notice_plan judges the uptime notices by
# it, reminded after remind_minutes: its post actions are the down posts, its reminds the still
# down posts and its ends the back posts. An outage closed before its down post went through, or
# because it opened in an earlier holding, gets a line.
def uptime_round($checks; $results; $now; $machine; $limits; $taken_at):
  .state as $previous
  | (.record // notice_empty) as $record
  | [$checks[] | {key: uptime_key, check: .}] as $order
  | ($order | map({key, value: .check}) | from_entries) as $wanted
  | ($order | to_entries | map({key: .value.key, value: .key}) | from_entries) as $rank
  | def as_wanted: $wanted[.key] as $w | $w != null and $w.url == .value.url and $w.expect == .value.expect;
    [$previous.checks | to_entries[] | select(as_wanted | not) | .key] as $dropped
  | ($previous | .checks |= with_entries(select(as_wanted))) as $state
  | (reduce $order[] as $c ($state;
       .checks[$c.key] |= uptime_count($c.check; $results[$c.key]; $now; $limits))) as $counted
  | ($counted + {schema: "team-uptime/1", written: $now}) as $new
  | [($record.notices // {}) | to_entries[] | .value | select(.source == "uptime")
     | select(.key as $k | $wanted[$k] == null or any($dropped[]; . == $k))] as $gone
  | (reduce $gone[] as $g ($record; notice_close(notice_id("uptime"; $g.key)))) as $kept
  | [$order[] | .key as $key | $new.checks[$key] as $s
     | $kept.notices[notice_id("uptime"; $key)] as $n
     | select(($s.ok | not)
         and ($s.failures >= $limits.down_runs or ($n != null and ($n | notice_past($taken_at) | not))))
     | {key: $key, since: $s.since, text: null, detail: null}] as $down_now
  | ($kept | notice_plan("uptime"; $down_now; $taken_at; $now; $limits.remind_minutes)) as $plan
  | def ranked: sort_by($rank[.notice.key]);
    ($plan.actions | map(select(.do == "post")) | ranked) as $down
  | ($plan.actions | map(select(.do == "remind")) | ranked) as $still
  | ($plan.actions | map(select(.do == "end")) | ranked) as $back
  | ([$order[] | $new.checks[.key] | select(.ok | not)
       | "\(uptime_key): failed: \(.reason) (\(.failures) in a row, since \(.since))"]
     + [$plan.closed | ranked | .[]
       | if .why == "earlier-holding" and .notice.posted != null then
           "\(.notice.key): its outage was posted in an earlier holding of the lease; closed without a post"
         elif .why == "earlier-holding" then
           "\(.notice.key): its outage was opened in an earlier holding of the lease and never posted; closed"
         else "\(.notice.key): answered again before its outage post went through; closed" end]
     + [$gone[] | select(.posted != null)
       | "\(.key): no longer checked as it was; its open outage is closed without a post"]) as $lines
  | def due($kind; $keys; $texts):
      if $keys == [] then empty
      else {kind: $kind, keys: $keys, content: ($texts | join("\n") | uptime_cut($limits.post_cut))} end;
    {state: $new, record: $plan.record, lines: $lines,
     posts: [due("down"; [$down[].notice.key]; [$down[] | .notice as $n | $new.checks[$n.key] | uptime_down_text($machine; $n)]),
             due("still down"; [$still[].notice.key]; [$still[] | .notice as $n | $new.checks[$n.key] | uptime_still_text($now; $n)]),
             due("back"; [$back[].notice.key]; [$back[] | .notice as $n | $new.checks[$n.key] | uptime_back_text($n)])]};

# The state of a run that counted nothing, since this machine could not reach the known-good
# site: only when it was written changes. uptime_uncounted($now), the previous state as input.
def uptime_uncounted($now): . + {schema: "team-uptime/1", written: $now};

# The notice record (the input) once <post> went through at <at>, Discord's message id <id> (null
# when it gave none): each of its checks' outages has notice_done's outcome of a down post (its
# post), a still down post (its remind) or a back post (its end, which closes it).
# uptime_posted($post; $id; $at)
def uptime_posted($post; $id; $at):
  ({"down": "post", "still down": "remind", "back": "end"}[$post.kind]) as $do
  | if $do == null then .
    else reduce $post.keys[] as $key (.; notice_done(notice_id("uptime"; $key); $do; true; $id; $at)) end;

# A check's outage notice (the input, null for none) as status shows it: {since, posted, reminded,
# message, back}, back its ended.
def uptime_alert: if . == null then null else {since, posted, reminded, message, back: .ended} end;

# When a check not up has been failing, as its posts say it: its outage's start, else its streak's.
def uptime_failing_since: .alert.since // .since;

# The digest's one Production line from uptime_status' checks (as input) and the state's written
# time ($written, null for no state): null with no checks; "Production: all <n> checks up, last
# checked <HH:MM>"; or each check not up ("<project> <name> down since <HH:MM>: <reason>",
# "<project> <name> failed once: <reason>" or "<project> <name> not checked yet") joined by "; ",
# then "; <n> more up" when any is, then ", last checked <HH:MM>" when the state was written; cut
# to line_cut characters. uptime_status_line($written; $limits)
def uptime_status_line($written; $limits):
  if length == 0 then null
  else map(select(.state != "up")) as $not_up
    | (length - ($not_up | length)) as $up
    | "Production: "
      + (if $not_up == [] then "all \(length) check\(if length == 1 then "" else "s" end) up"
         else ($not_up | map(
             if .state == "down" then "\(.project) \(.name) down since \(uptime_failing_since | uptime_clock): \(.reason)"
             elif .state == "failing" then "\(.project) \(.name) failed once: \(.reason)"
             else "\(.project) \(.name) not checked yet" end) | join("; "))
           + (if $up > 0 then "; \($up) more up" else "" end)
         end)
      + (if $written != null then ", last checked \($written | uptime_clock)" else "" end)
    | uptime_cut($limits.line_cut)
  end;

# team-uptime status --json's object: uptime_status($checks; $limits), the input {state, record},
# the state (uptime_empty when there is no state file) and the notice record, $checks the
# registry's [{project, name, url, expect}] in registry order. Gives {schema, written, line,
# checks}: a check per registry entry, {project, name, url, expect, state, checked, since,
# failures, reason, alert}, its state "up", "down" (down_runs failures in a row, or a failure with
# its outage still open, as after a gap), "failing" (any other failure) or "unchecked" (no state
# for it, or a state for another url or expect, which the next run drops), the rest the state's
# (null, and failures 0, for an unchecked one), and alert its outage's notice as uptime_alert
# gives it; line uptime_status_line's.
def uptime_status($checks; $limits):
  .state as $state
  | (.record // notice_empty) as $record
  | [$checks[] | uptime_key as $key | $state.checks[$key] as $s
     | {project, name, url, expect} as $id
     | if $s == null or $s.url != .url or $s.expect != .expect then
         $id + {state: "unchecked", checked: null, since: null, failures: 0, reason: null, alert: null}
       else
         ($record.notices[notice_id("uptime"; $key)] | uptime_alert) as $alert
         | $id + {state: (if $s.ok then "up" elif $alert != null or $s.failures >= $limits.down_runs then "down" else "failing" end)}
           + ($s | {checked, since, failures, reason}) + {alert: $alert}
       end] as $rows
  | {schema: "team-uptime/1", written: $state.written,
     line: ($rows | uptime_status_line($state.written; $limits)),
     checks: $rows};

# team-uptime status's text, a line per check, from uptime_status' object: "<project>/<name>
# <state>[ since <HH:MM>][: <reason>], checked <HH:MM> (<url>)", or "<project>/<name> not checked
# yet (<url>)".
def uptime_status_text:
  .checks[]
  | "\(.project)/\(.name) "
    + (if .state == "unchecked" then "not checked yet"
       else .state
         + (if .state == "up" then "" else " since \(uptime_failing_since | uptime_clock): \(.reason)" end)
         + ", checked \(.checked | uptime_clock)"
       end)
    + " (\(.url))";
