# The uptime module: the one place that says when a production check is down, when team-uptime
# posts in #coordinator and what each post says. bin/team-uptime does the I/O (the registry, the
# fetches, Discord, the state file); these are pure functions of the previous state, the
# registry's checks, this run's results, now and the limits.
# jq 1.7, no includes. Included as: jq -L bin/lib 'include "uptime"; ...'
#
# The state, ~/.local/state/agent-team/uptime.json, is team-uptime/1:
#   {schema, written (when a run last wrote it),
#    checks: {"<project>/<name>": {project, name, url, expect,
#      checked (the UTC time of its last counted result), ok, reason (the last failure's, null
#      when up), failures (counted failures in a row, 0 when the last was good), since (the UTC
#      time of the streak's first failure, null when up),
#      alert: the open outage, null when none: {since, posted (when its down post went through,
#        null until then), reminded, message (the down post's id, null when Discord gave none),
#        back (when it answered again, null until then)}}}}
# Keys it does not name are kept as they are. Times are UTC ISO 8601, as date -u +%FT%TZ writes.

# The thresholds, each defined here once: a check that fails `down_runs` runs in a row is down; a
# failure more than `gap_minutes` after the check's last counted result counts as the first again
# (the machine slept, or the heartbeat stopped); a failure's reason is cut to `reason_cut`
# characters and a post to `post_cut`, Discord's limit.
def uptime_limits: {down_runs: 2, gap_minutes: 15, reason_cut: 200, post_cut: 2000};

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

# The texts of one check's posts, the check's state as input.
def uptime_down_text($machine):
  "Production down: \(.project) \(.name) (<\(.url)>) since \(.alert.since | uptime_clock), \(.failures) checks in a row from \($machine): \(.reason | uptime_sentence).";
def uptime_back_text:
  "Production back: \(.project) \(.name) (<\(.url)>) answers again at \(.alert.back | uptime_clock), down since \(.alert.since | uptime_clock) (\(uptime_minutes(.alert.since; .alert.back) | uptime_duration)).";

# One check's new state from its previous one (null for none) and this run's result {ok, reason}:
# uptime_count($check; $result; $now; $limits), the previous state as input.
def uptime_count($check; $result; $now; $limits):
  . as $prev
  | ($check | {project, name, url, expect}) as $id
  | if $result.ok then
      ($prev // {}) + $id + {checked: $now, ok: true, reason: null, failures: 0, since: null}
      | .alert |= (if . == null then null
                   elif .posted == null then null
                   else .back //= $now end)
    else
      (($prev.failures // 0) > 0 and $prev.checked != null
        and uptime_minutes($prev.checked; $now) <= $limits.gap_minutes) as $streak
      | (if $streak then $prev.failures + 1 else 1 end) as $failures
      | ($prev // {}) + $id
        + {checked: $now, ok: false, reason: ($result.reason | uptime_cut($limits.reason_cut)),
           failures: $failures, since: (if $streak then $prev.since else $now end)}
      | .since as $since
      | .alert |= (if . != null then .back = null
                   elif $failures >= $limits.down_runs then
                     {since: $since, posted: null, reminded: null, message: null, back: null}
                   else null end)
    end;

# One round of checks: uptime_round($checks; $results; $now; $machine; $limits), the previous
# state as input (uptime_empty for none), $checks the registry's [{project, name, url, expect}] in
# registry order, $results {"<project>/<name>": {ok, reason}} this run's. Gives {state, lines,
# posts}: the new state, the lines to print, and the posts due, [{kind, keys, content}] in the
# order to make them (down, then back), each one message with a line per check in registry order.
def uptime_round($checks; $results; $now; $machine; $limits):
  . as $state
  | [$checks[] | {key: uptime_key, check: .}] as $order
  | reduce $order[] as $c ($state;
      .checks[$c.key] |= uptime_count($c.check; $results[$c.key]; $now; $limits)) as $counted
  | ($counted + {schema: "team-uptime/1", written: $now}) as $new
  | [$order[] | . as $c | {key, prev: $state.checks[.key], now: $new.checks[.key]}] as $rows
  | [$rows[] | select(.now.ok | not)
      | "\(.key): failed: \(.now.reason) (\(.now.failures) in a row, since \(.now.since))"]
    + [$rows[] | select(.prev.alert != null and .prev.alert.posted == null and .now.alert == null)
      | "\(.key): answered again before its outage post went through; closed"] as $lines
  | def due($kind; $keys; $texts):
      if $keys == [] then empty
      else {kind: $kind, keys: $keys, content: ($texts | join("\n") | uptime_cut($limits.post_cut))} end;
    [$rows[] | select(.now.alert != null and .now.alert.posted == null)] as $down
  | [$rows[] | select(.now.alert.back != null)] as $back
  | {state: $new, lines: $lines,
     posts: [due("down"; [$down[].key]; [$down[].now | uptime_down_text($machine)]),
             due("back"; [$back[].key]; [$back[].now | uptime_back_text])]};

# The state once <post> went through at <at>, Discord's message id <id> (null when it gave none):
# a down post records when and its message, a back post closes the outage.
# uptime_posted($post; $id; $at), the state as input.
def uptime_posted($post; $id; $at):
  reduce $post.keys[] as $key (.;
    if $post.kind == "down" then .checks[$key].alert += {posted: $at, message: $id}
    elif $post.kind == "back" then .checks[$key].alert = null
    else . end);
