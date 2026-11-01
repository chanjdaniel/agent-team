# A worker's message, read whole into the events the coordinator's message table gives it, for
# team-log --from-message. Every value is the raw text the message wrote (a comma list, key:value
# counts, a JSON object), which team-log then types and checks as it does a hand-typed key=value.
include "ledger";

# The forms a message takes after its task, as the role prompts and brief templates write them.
def message_forms:
  ["QUESTION <text>", "BLOCKED <what> <why>", "NEED toolkit <name>", "PAUSED <why>",
   "PR <full url> [merged <base> conflicts: <files or none>]",
   "DONE <NN> <sha>... <line>", "DONE review-ready <sha>", "DONE merged <base> <sha> conflicts: <files or none>",
   "DONE pass <PR url or head> findings=<kind:n,...> [before=<list>] guarded=<list>",
   "DONE findings <path> findings=<kind:n,...> [before=<list>] guarded=<list>",
   "DONE gate <key=value>...", "DONE <report>", "FAILED <why>", "INJECTION <where> <what it asked>"];

def message_sha: test("^[0-9a-f]{7,40}$");
def message_pr_url: test("^https://github\\.com/[^/\\s]+/[^/\\s]+/pull/[0-9]+/?$");

# A refusal of the message, which nothing is logged after.
def message_refused($why): {problems: [$why]};

# The key=value pairs of a text, each value running to the next " <key>=" so that a JSON object
# with spaces stays one value: [[key, value]...], or a refusal naming the malformed part; $what
# names the message's form in it.
def message_pairs($what):
  . as $text
  | [match("(?:^|\\s)([a-z][a-z0-9_]*)="; "g")] as $ms
  | if $ms == [] then message_refused("\($what) takes key=value pairs, got '\($text)'")
    elif ($text[:$ms[0].offset] | test("\\S")) then
      message_refused("\($what) takes key=value pairs, got '\($text[:$ms[0].offset] | gsub("^\\s+|\\s+$"; ""))' before the first")
    else
      [range($ms | length) as $i | $ms[$i] as $m
        | [$m.captures[0].string,
           ($text[$m.offset + $m.length:(if $i + 1 < ($ms | length) then $ms[$i + 1].offset else ($text | length) end)]
            | gsub("^\\s+|\\s+$"; ""))]] as $pairs
      | ([$pairs[] | select(.[1] == "") | .[0]] | first) as $empty
      | ([$pairs[] | .[0]] | group_by(.) | map(select(length > 1) | first) | first) as $twice
      | if $empty != null then message_refused("\($what) has \($empty)= with no value")
        elif $twice != null then message_refused("\($what) has \($twice)= twice")
        else {pairs: $pairs} end
    end;

# The task's launches, each with its index in the events: $events | message_launches
def message_launches: [to_entries[] | select(.value.event == "launch") | .value + {i: .key}];

# A launch's session name and id, as a refusal names it: "T7-builder (b0000001)".
def message_launch_name($task): "\($task)-\(.role) (\(.session))";

# The latest launch of each role with no event since that ends it (ends_worker): the workers
# whose message has not been reported yet.
def message_unreported($events):
  $events | message_launches | group_by(.role) | map(max_by(.i))
  | map(. as $l | select(all($events[$l.i + 1:][]; ends_worker($l.role) | not))) | sort_by(.i);

# The message's sender: {role, session, brief} of the latest launch of the role the kind implies
# ($implied, or null), else of --from's role ($from, a session name T<n>-<role> or a launch's
# session id, or ""), else of the only launch with no report since; or a refusal.
def message_sender($task; $events; $from; $implied):
  ($events | message_launches) as $launches
  | def latest($role): $launches | map(select(.role == $role)) | last;
    def from_role:
      if $from == "" then null
      else ($launches | map(select("\($task)-\(.role)" == $from or .session == $from)) | last) as $l
        | if $l != null then $l.role
          else {problems: ["--from \($from) names no launch of \($task)"
            + if $launches == [] then ": it has none"
              else ": its sessions are " + ($launches | group_by(.role) | map(max_by(.i)) | sort_by(.i)
                | map(message_launch_name($task)) | join(", ")) end]} end end;
    from_role as $from_role
    | if ($from_role | type) == "object" then $from_role
      elif $implied != null then
        if $from_role != null and $from_role != $implied then
          message_refused("the message is a \($implied)'s, but --from names \($task)-\($from_role)")
        else latest($implied) as $l
          | if $l == null then message_refused("the message is a \($implied)'s, but \($task) has no \($implied) launch")
            else {sender: $l} end end
      elif $from_role != null then {sender: latest($from_role)}
      else message_unreported($events) as $open
        | if ($open | length) == 1 then {sender: $open[0]}
          elif $launches == [] then
            message_refused("the message's sender is not known: \($task) has no launch; name it with --from <session>")
          elif $open == [] then
            message_refused("the message's sender is not known: every launch of \($task) has a report since; name it with --from <session>")
          else message_refused("the message's sender is not known: "
            + ($open | map(message_launch_name($task)) | .[:-1] | join(", ")) + " and "
            + ($open | last | message_launch_name($task)) + " have no report since their launch; name it with --from <session>")
          end end;

# Runs f on the sender's {sender} when it is known, passing a refusal through.
def with_sender($task; $events; $from; $implied; f):
  message_sender($task; $events; $from; $implied) as $s
  | if $s.problems then $s else $s.sender | f end;

# One event: {event, fields: [[key, raw value]...]}.
def message_event($event; $fields): {event: $event, fields: $fields};

# A reviewer's DONE pass or findings: the review and the reviewer's done. Its head is the head of
# the brief record its latest launch read ($records, by brief name), else the message's own head
# for a pass on a head, else it is refused naming head=.
def message_review($task; $events; $records; $from; $sent_back; $verdict; $rest):
  ($rest | capture("^(?<target>\\S+)(?:\\s+(?<pairs>.*))?$"; "s") // null) as $m
  | if $m == null or ($m.pairs // "") == "" then message_refused("DONE \($verdict) needs findings= and guarded=")
    elif $verdict == "pass" and ($m.target | (message_sha or message_pr_url) | not) then
      message_refused("DONE pass takes a PR url or a head of 7 to 40 hex digits, got '\($m.target)'")
    else ($m.pairs | message_pairs("DONE \($verdict)")) as $p
      | if $p.problems then $p
        elif any($p.pairs[]; .[0] | IN("findings", "before", "guarded") | not) then
          message_refused("DONE \($verdict) takes findings=<kind:n,...>, before=<list> and guarded=<list>, got "
            + ([$p.pairs[] | .[0] | select(IN("findings", "before", "guarded") | not)] | join(", ")))
        elif ([$p.pairs[] | .[0] | select(IN("findings", "guarded"))] | length) < 2 then
          message_refused("DONE \($verdict) needs findings= and guarded=")
        else with_sender($task; $events; $from; "reviewer";
          . as $l
          | ($records[$l.brief // ""].values.head // null) as $recorded
          | (if $recorded != null then $recorded
             elif $verdict == "pass" and ($m.target | message_sha) then $m.target
             else null end) as $head
          | if $head == null then
              message_refused("the review's head is not known: the reviewer's latest launch (\($l.session)) "
                + (if $l.brief then "read \($l.brief), which has no record with a head" else "read no brief" end)
                + ", and DONE \($verdict) "
                + (if $verdict == "pass" then "names \($m.target), not a head" else "names no head" end)
                + "; log the review by hand with head=<the full sha reviewed>")
            else {events: [
              message_event("review"; [["verdict", $verdict], ["head", $head]] + $p.pairs
                + if $sent_back == "" then [] else [["sent_back", $sent_back]] end),
              message_event("done"; [["role", "reviewer"], ["session", $l.session]])]} end)
        end
    end;

# A builder's DONE <NN> <sha>... <line>: the ticket-done and the builder's done.
def message_ticket($task; $events; $from; $ticket; $rest):
  ($rest | [splits("\\s+")]) as $words
  | ([$words | to_entries[] | select(.value | message_sha | not) | .key] | first // ($words | length)) as $n
  | if $n == 0 then
      message_refused("DONE \($ticket) takes one or more shas of 7 to 40 hex digits after the ticket, then a line, got '\($words[0] // "")'")
    else ($rest | sub("^\\s*(\\S+\\s*){\($n)}"; "")) as $line
      | with_sender($task; $events; $from; "builder";
          {events: [
            message_event("ticket-done"; [["ticket", $ticket], ["commits", ($words[:$n] | join(","))]]
              + if $line == "" then [] else [["note", $line]] end),
            message_event("done"; [["role", "builder"], ["session", .session]])]})
    end;

# The builder's done for a DONE whose report it carries whole.
def message_builder_done($task; $events; $from; $report):
  with_sender($task; $events; $from; "builder"; {events: [message_event("done"; [["role", "builder"], ["session", .session], ["report", $report]])]});

# A DONE: the forms above by their first word, else the sender's done with its report.
def message_done($task; $events; $records; $from; $sent_back; $rest):
  ($rest | capture("^(?<word>\\S+)(?:\\s+(?<more>.*))?$"; "s")) as $d
  | ($d.more // "") as $more
  | if ($d.word | test("^[0-9]{2}$")) then message_ticket($task; $events; $from; $d.word; $more)
    elif $d.word == "review-ready" then
      if ($more | message_sha) then message_builder_done($task; $events; $from; $rest)
      else message_refused("DONE review-ready takes 'DONE review-ready <sha>', got 'DONE \($rest)'") end
    elif $d.word == "merged" then
      if ($more | test("^\\S+\\s+[0-9a-f]{7,40}\\s+conflicts:\\s*\\S"; "s")) then message_builder_done($task; $events; $from; $rest)
      else message_refused("DONE merged takes 'DONE merged <base> <sha> conflicts: <files or none>', got 'DONE \($rest)'") end
    elif $d.word == "pass" or $d.word == "findings" then
      message_review($task; $events; $records; $from; $sent_back; $d.word; $more)
    elif $d.word == "gate" then
      ($more | message_pairs("DONE gate")) as $p
      | if $p.problems then $p else {events: [message_event("gate-run"; $p.pairs)]} end
    else with_sender($task; $events; $from; null;
      {events: [message_event("done"; [["role", .role], ["session", .session], ["report", $rest]])]}) end;

# The message (the input) of $task read into {events: [{event, fields}...]}, or {problems}. $events
# are the task's events, $records its brief records by name (brief-review: {template, project,
# values}), $from the --from session or "", $sent_back the --sent-back list or "". A pr event's
# head is left for the caller to read from GitHub: it carries github: <url> and no head.
def parse_message($task; $events; $records; $from; $sent_back):
  gsub("^\\s+|\\s+$"; "") as $text
  | ($text | capture("^(?<task>T[0-9]+)\\s+(?<kind>\\S+)(?:\\s+(?<rest>.*))?$"; "s") // null) as $m
  | ($m.rest // "") as $rest
  | def unreadable: message_refused("cannot read '\($text)': expected one of \(message_forms | join(", "))");
    if $m == null or ($text | test("^T[0-9]+\\s") | not) then
      message_refused("a worker's message starts with its task, \($task), then its kind; got '\($text)'")
    elif $m.task != $task then message_refused("the message is for \($m.task), not \($task)")
    elif $sent_back != "" and ($m.kind != "DONE" or ($rest | test("^(findings|pass)(\\s|$)") | not)) then
      message_refused("--sent-back is taken only with a DONE findings or DONE pass message, not "
        + (if $m.kind == "DONE" then "DONE " + ([$rest | splits("\\s+")][0]) else $m.kind end))
    elif $rest == "" then unreadable
    elif $m.kind == "QUESTION" then
      with_sender($task; $events; $from; null; {events: [message_event("question"; [["role", .role], ["text", $rest]])]})
    elif $m.kind == "BLOCKED" then {events: [message_event("blocked"; [["reason", $rest]])]}
    elif $m.kind == "NEED" then
      if ($rest | test("^toolkit\\s+\\S+$")) then {events: [message_event("blocked"; [["reason", "needs " + ($rest | sub("\\s+"; " "))]])]}
      else message_refused("NEED takes 'NEED toolkit <name>', got 'NEED \($rest)'") end
    elif $m.kind == "PAUSED" then {events: [message_event("paused"; [["reason", $rest]])]}
    elif $m.kind == "PR" then
      ($rest | capture("^(?<url>\\S+)(?:\\s+merged\\s+\\S+\\s+conflicts:\\s*\\S.*)?$"; "s") // null) as $pr
      | if $pr == null or ($pr.url | message_pr_url | not) then
          message_refused("PR takes 'PR <full url>', optionally followed by 'merged <base> conflicts: <files or none>', got 'PR \($rest)'")
        else {events: [message_event("pr"; [["url", $pr.url]]) + {github: $pr.url}]} end
    elif $m.kind == "DONE" then message_done($task; $events; $records; $from; $sent_back; $rest)
    elif $m.kind == "FAILED" then {events: [message_event("failed"; [["reason", $rest]])]}
    elif $m.kind == "INJECTION" then
      ($rest | capture("^(?<source>\\S+)\\s+(?<text>\\S.*)$"; "s") // null) as $i
      | if $i == null then message_refused("INJECTION takes 'INJECTION <where> <what it asked>', got 'INJECTION \($rest)'")
        else with_sender($task; $events; $from; null;
          {events: [message_event("injection"; [["role", .role], ["source", $i.source], ["text", $i.text]])]}) end
    else unreadable end;
