#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt and tickets are helpers/tickets.bash's
# team-tickets --html: a task's tickets drawn as one self-contained HTML page of their dependency
# graph (bin/lib/ticket_graph.py), read as a user would read it: the page's SVG, its header's text,
# each box's text, colour and border, each edge's path, and tests/helpers/graph-check.py, which
# names each edge segment that crosses a box. The wide case is T257's 14 tickets as planned
# (tests/fixtures/tickets-T257/).

load helpers/common
load helpers/tickets

setup() {
  sandbox
  tickets_sandbox
  page=$BATS_TEST_TMPDIR/out/page.html
  mkdir -p "${page%/*}"
}

# draw: write T172's page to $page, which prints nothing.
draw() {
  run_bin -0 --separate-stderr team-tickets T172 --html "$page"
  assert_equal "$output" ""
}

# count <pattern>: how many times the page holds <pattern>, a grep regular expression.
count() {
  grep -o -- "$1" "$page" | wc -l
}

# texts <class>: the text of each of the page's text elements of <class>, a line each, its markup
# removed and its entities kept.
texts() {
  grep -o "<text class=\"$1\"[^>]*>.*</text>" "$page" | sed -E 's/<[^>]*>//g'
}

# box <NN> <attribute>: that attribute of ticket NN's box.
box() {
  grep -o "<rect class=\"ticket\" data-ticket=\"$1\"[^>]*>" "$page" | sed -E "s/.* $2=\"([^\"]*)\".*/\\1/"
}

# edge <NN>-<NN> <attribute>: that attribute of the edge from the first ticket to the second.
edge() {
  grep -o "<path class=\"edge\" data-edge=\"$1\"[^>]*>" "$page" | sed -E "s/.* $2=\"([^\"]*)\".*/\\1/"
}

# no_crossing: graph-check finds no edge segment through a box.
no_crossing() {
  run python3 -I "$REPO_ROOT/tests/helpers/graph-check.py" "$page"
  assert_equal "$status" 0
  assert_contains "$output" " edges, "
}

@test "a chain: three rows, two edges, the whole chain red, the header's counts and path" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: 01"
  ticket 03-three "Blocked by: 02"
  draw
  assert_equal "$(texts level)" "level 1
level 2
level 3"
  assert_equal "$(count 'class="ticket"')" 3
  assert_equal "$(count 'class="edge"')" 2
  (($(box 01 y) < $(box 02 y) && $(box 02 y) < $(box 03 y)))
  assert_equal "$(box 01 stroke) $(box 02 stroke) $(box 03 stroke)" "#dc2626 #dc2626 #dc2626"
  assert_equal "$(edge 01-02 stroke) $(edge 02-03 stroke)" "#dc2626 #dc2626"
  assert_equal "$(texts header | head -3)" "T172 toil
3 tickets in 1 phase, 3 levels; widest level 1 ticket.
Serial 3 tickets; critical path 3 tickets: 01 → 02 → 03."
  # No ticket has minutes: each weighs 1, the header says so, and no box shows minutes.
  assert_equal "$(texts header | sed '$d' | tail -n +4 | paste -sd' ')" \
    "No ticket has build minutes yet, so each weighs 1 and the totals count tickets."
  assert_equal "$(count 'class="minutes"')" 0
  [[ $(texts header | tail -1) =~ ^As\ of\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ UTC\.$ ]]
  assert_equal "$(count 'class="phase"')" 1
  assert_contains "$(cat "$page")" ">phase 1</text>"
  no_crossing
}

@test "a diamond: the middle row two wide, the critical path through the lower number" {
  ticket 01-top "Blocked by: None"
  ticket 02-left "Blocked by: 01"
  ticket 03-right "Blocked by: 01"
  ticket 04-bottom "Blocked by: 02, 03"
  draw
  assert_equal "$(count 'class="level"')" 3
  assert_equal "$(count 'class="edge"')" 4
  assert_equal "$(box 02 y)" "$(box 03 y)"
  (($(box 01 y) < $(box 02 y) && $(box 02 y) < $(box 04 y)))
  assert_contains "$(texts header)" "4 tickets in 1 phase, 3 levels; widest level 2 tickets."
  assert_contains "$(texts header)" "Serial 4 tickets; critical path 3 tickets: 01 → 02 → 04."
  assert_equal "$(box 02 stroke) $(box 03 stroke)" "#dc2626 #9ca3af"
  assert_equal "$(edge 01-02 stroke) $(edge 02-04 stroke)" "#dc2626 #dc2626"
  assert_equal "$(edge 01-03 stroke) $(edge 03-04 stroke)" "#9ca3af #9ca3af"
  # The red edges are drawn after the grey ones, so no grey line covers them.
  assert_equal "$(grep -o '<path class="edge"[^>]*stroke="#[0-9a-f]*"' "$page" | sed 's/.*stroke=//' | uniq)" '"#9ca3af"
"#dc2626"'
  no_crossing
}

@test "phases: each a band in order, a ticket blocked only by an earlier phase on its phase's first row, the critical path per phase summed" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: 01"
  ticket 03-three "Blocked by: 02" "Phase: 2"
  ticket 04-four "Blocked by: 03" "Phase: 2"
  ticket 05-five "Blocked by: 01" "Phase: 2"
  draw
  assert_equal "$(count 'class="phase"')" 2
  assert_equal "$(grep -o '>phase [0-9]</text>' "$page")" ">phase 1</text>
>phase 2</text>"
  assert_equal "$(count 'class="level"')" 4
  assert_equal "$(box 05 y)" "$(box 03 y)"
  (($(box 02 y) < $(box 03 y) && $(box 03 y) < $(box 04 y)))
  assert_contains "$(texts header)" "5 tickets in 2 phases, 4 levels; widest level 2 tickets."
  # The 640-pixel page wraps the header at 65 characters; read as one text, it says the path.
  assert_contains "$(texts header | paste -sd' ')" \
    "Serial 5 tickets; critical path 4 tickets: phase 1 01 → 02 (2); phase 2 03 → 04 (2)."
  # A cross-phase edge is drawn, never red: each phase's path is its own.
  assert_equal "$(edge 02-03 stroke) $(edge 01-05 stroke)" "#9ca3af #9ca3af"
  assert_equal "$(edge 03-04 stroke)" "#dc2626"
  # The edge from 01 to 05 passes phase 1's second row through a slot of its own.
  assert_equal "$(edge 01-05 d | grep -o L | wc -l)" 3
  no_crossing
}

@test "each state is written in its box and shown by its colour; a waiting ticket says what it waits for, escaped" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: 01" 'Waits for: T9 <b>& merged'
  ticket 03-three "Blocked by: 02"
  ticket 04-four "Blocked by: None"
  ticket 05-five "Blocked by: None"
  ticket_done 01
  build_launch 04 a1b2c3d4
  draw
  assert_equal "$(texts head)" "01 done
02 waiting
03 blocked
04 running
05 ready"
  assert_equal "$(for n in 01 02 03 04 05; do box "$n" fill; done)" "#d1fae5
#fde68a
#f3f4f6
#dbeafe
#fef9c3"
  assert_equal "$(texts waits)" "waits for: T9 &lt;b&gt;&amp; merged"
  assert_contains "$(cat "$page")" 'font-style="italic">waits for: T9 &lt;b&gt;&amp; merged</text>'
  [[ $(cat "$page") != *"<b>&"* ]]
  # The legend names each state and the critical path.
  assert_equal "$(grep -o '<g class="legend">.*</g>' "$page" | grep -o '<text[^>]*>[^<]*' | sed 's/.*>//')" "done
running
ready
waiting
blocked
critical path"
  no_crossing
}

@test "a long slug wraps onto more lines, never cut, and a word longer than a line splits with a dash" {
  local slug=the-coordinator-posts-the-ticket-graph-with-the-plan-ask-to-daniel-now
  assert_equal "${#slug}" 70
  ticket "01-$slug" "Blocked by: None"
  ticket 02-supercalifragilisticexpialidocious-ish-words "Blocked by: 01"
  draw
  local word lines
  lines=$(texts slug)
  for word in ${slug//-/ }; do
    grep -qw -- "$word" <<<"$lines" || { echo "the word $word is not on the page" >&2; return 1; }
  done
  assert_equal "$(awk 'length > 28' <<<"$lines")" ""
  [[ $(cat "$page") != *...* ]]
  [[ $(cat "$page") != *…* ]]
  assert_contains "$lines" "supercalifragilisticexpiali-"$'\n'"docious ish words"
}

@test "the page is self-contained and carries the digest of the --json list it was drawn from" {
  cp "$REPO_ROOT"/tests/fixtures/tickets-T257/*.md "$tickets/"
  ticket_done 01
  draw
  local text
  text=$(cat "$page")
  local banned
  for banned in "<script" "<link" "<img" "<iframe" "@import"; do
    [[ $text != *"$banned"* ]] || { echo "the page holds $banned" >&2; return 1; }
  done
  assert_equal "$(grep -o 'http[^"]*' "$page" | sort -u)" "http://www.w3.org/2000/svg"
  assert_equal "$(grep -o 'url([^#]' "$page")" ""
  assert_equal "$(count '<style')" 1
  assert_contains "$text" "<title>T172 tickets</title>"
  run_bin -0 --separate-stderr team-tickets T172 --json
  assert_contains "$text" "<meta name=\"team-tickets-digest\" content=\"$(jq -cS . <<<"$output" | sha256sum | cut -c1-64)\">"
}

@test "T257's 14 tickets: nine levels, three bands, no edge through a box" {
  cp "$REPO_ROOT"/tests/fixtures/tickets-T257/*.md "$tickets/"
  draw
  assert_equal "$(texts level | tail -1)" "level 9"
  assert_equal "$(count 'class="level"')" 9
  assert_equal "$(count 'class="ticket"')" 14
  assert_equal "$(count 'class="phase"')" 3
  assert_equal "$(count 'class="edge"')" 25
  assert_contains "$(texts header)" "14 tickets in 3 phases, 9 levels; widest level 3 tickets."
  assert_contains "$(texts header)" "Serial 14 tickets; critical path 9 tickets: phase 1 01 → 02 → 04 (3); phase 2 05 → 07 → 08 (3);"
  assert_contains "$(texts header)" "phase 3 11 → 12 → 14 (3)."
  no_crossing
  # A graph three tickets wide stays near 1200 pixels.
  local width
  width=$(grep -o '<svg [^>]*' "$page" | sed -E 's/.* width="([0-9]+)".*/\1/')
  ((width > 1000 && width < 1300))
}

# minutes: each ticket's minutes as --json prints them, one line.
minutes() {
  guard_sandbox || return 1
  "$REPO_ROOT/bin/team-tickets" T172 --json | jq -c 'map(.minutes)'
}

@test "a done ticket's minutes run from its latest launch to its ticket-done, rounded half up, at least 1" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: None"
  ticket 03-three "Blocked by: None"
  ticket 04-four "Blocked by: None"
  # An earlier launch on the same brief (a stowed and relaunched builder) is ignored.
  build_launch 01 11111111 2026-11-01T08:00:00Z
  build_launch 01 22222222 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:29:30Z 01
  build_launch 02 33333333 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:00:05Z 02
  build_launch 03 44444444 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:29:29Z 03
  # Done by hand, with no launch: no minutes.
  ticket_done --at 2026-11-01T09:30:00Z 04
  assert_equal "$(minutes)" "[30,1,29,null]"
  # Relaunched after its ticket-done: running again, so no minutes until its next ticket-done.
  build_launch 02 55555555 2026-11-01T10:00:00Z
  assert_equal "$(minutes)" "[30,null,29,null]"
  ticket_done --at 2026-11-01T10:12:00Z 02
  assert_equal "$(minutes)" "[30,12,29,null]"
}

@test "build minutes weigh the critical path: done tickets their own, the others the median, the totals in minutes" {
  ticket 01-top "Blocked by: None"
  ticket 02-left "Blocked by: 01"
  ticket 03-right "Blocked by: 01"
  ticket 04-bottom "Blocked by: 02, 03"
  build_launch 01 11111111 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:10:00Z 01
  build_launch 02 22222222 2026-11-01T09:10:00Z
  build_launch 03 33333333 2026-11-01T09:10:00Z
  ticket_done --at 2026-11-01T09:15:00Z 02
  ticket_done --at 2026-11-01T09:50:00Z 03
  assert_equal "$(minutes)" "[10,5,40,null]"
  draw
  # Counted in tickets the path would go through 02, the lower number; 03's 40 minutes move it.
  assert_contains "$(texts header)" "Serial 65 min; critical path 60 min: 01 → 03 → 04."
  assert_contains "$(texts header | paste -sd' ')" \
    "3 done tickets weigh their build minutes from the ledger; the other 1 weighs their median, 10."
  assert_equal "$(box 03 stroke) $(box 02 stroke)" "#dc2626 #9ca3af"
  assert_equal "$(edge 01-03 stroke) $(edge 03-04 stroke) $(edge 01-02 stroke)" "#dc2626 #dc2626 #9ca3af"
  # Each box's minutes, right-aligned on its first line: measured, or "~" the median.
  assert_equal "$(texts minutes)" "10 min
5 min
40 min
~10 min"
  assert_equal "$(grep -c '<text class="minutes"[^>]* text-anchor="end"' "$page")" 4
  no_crossing
}

@test "the median of an even count rounds half up, and a done ticket with no minutes weighs it" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: 01"
  ticket 03-three "Blocked by: 02" "Phase: 2"
  build_launch 01 11111111 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:10:00Z 01
  build_launch 02 22222222 2026-11-01T09:10:00Z
  ticket_done --at 2026-11-01T09:35:00Z 02
  ticket_done 03
  assert_equal "$(minutes)" "[10,25,null]"
  draw
  assert_equal "$(texts minutes)" "10 min
25 min
~18 min"
  assert_contains "$(texts header | paste -sd' ')" \
    "Serial 53 min; critical path 53 min: phase 1 01 → 02 (35); phase 2 03 (18)."
  assert_contains "$(texts header | paste -sd' ')" \
    "2 done tickets weigh their build minutes from the ledger; the other 1 weighs their median, 18."
}

@test "line 4 says one done ticket weighs its minutes, then that every ticket does" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Blocked by: 01"
  ticket 03-three "Blocked by: 01"
  build_launch 01 11111111 2026-11-01T09:00:00Z
  ticket_done --at 2026-11-01T09:10:00Z 01
  draw
  assert_contains "$(texts header | paste -sd' ')" \
    "1 done ticket weighs its build minutes from the ledger; the other 2 weigh their median, 10."
  assert_contains "$(texts header | paste -sd' ')" "Serial 30 min; critical path 20 min: 01 → 02."
  build_launch 02 22222222 2026-11-01T09:10:00Z
  ticket_done --at 2026-11-01T09:13:00Z 02
  build_launch 03 33333333 2026-11-01T09:13:00Z
  ticket_done --at 2026-11-01T09:20:00Z 03
  draw
  assert_contains "$(texts header | paste -sd' ')" "Every ticket weighs its build minutes from the ledger."
  assert_contains "$(texts header | paste -sd' ')" "Serial 20 min; critical path 17 min: 01 → 03."
  assert_equal "$(texts minutes)" "10 min
3 min
7 min"
}

@test "graph-check names a segment that crosses a box" {
  mkdir -p "$BATS_TEST_TMPDIR/check"
  cat >"$BATS_TEST_TMPDIR/check/page.html" <<'HTML'
<!doctype html><html><body><svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">
<rect class="ticket" data-ticket="01" x="100" y="100" width="100" height="50"/>
<path class="edge" d="M150,0 L150,99"/><path class="edge" d="M0,120 L300,130"/>
</svg></body></html>
HTML
  run python3 -I "$REPO_ROOT/tests/helpers/graph-check.py" "$BATS_TEST_TMPDIR/check/page.html"
  assert_equal "$status" 1
  assert_equal "$output" "segment 0,120 -> 300,130 crosses box 01 at 100,100
2 edges, 1 boxes"
}

@test "a task with no tickets gets a page saying so, with no legend and no graph" {
  rm -r "$tickets"
  run_bin -0 --separate-stderr team-tickets T172 --html "$page"
  assert_equal "$output" ""
  assert_equal "$stderr" "team-tickets: T172 has no tickets in its open worktrees"
  assert_equal "$(texts header | sed '$d')" "T172 toil
No tickets in T172&#x27;s open worktrees."
  [[ $(texts header | tail -1) == "As of "*" UTC." ]]
  assert_equal "$(count 'class="legend"') $(count 'class="ticket"') $(count 'class="phase"')" "0 0 0"
}

@test "the page replaces the file through a temporary one beside it, leaving nothing else" {
  ticket 01-one "Blocked by: None"
  echo old >"$page"
  draw
  assert_contains "$(cat "$page")" "<!doctype html>"
  assert_equal "$(ls -A "${page%/*}")" "page.html"
}

@test "a set the listing refuses is refused the same way, and nothing is written" {
  ticket 01-one "Blocked by: None"
  ticket 02-two "Waits for: T9 merged"
  run_bin -1 --separate-stderr team-tickets T172 --check
  local reasons=$stderr
  echo old >"$page"
  run_bin -1 --separate-stderr team-tickets T172 --html "$page"
  assert_equal "$output" ""
  assert_equal "$stderr" "$reasons"
  assert_equal "$(cat "$page")" "old"
  assert_equal "$(ls -A "${page%/*}")" "page.html"
}

@test "--html refuses a directory that does not exist, naming it, and a directory for its file" {
  ticket 01-one "Blocked by: None"
  run_bin -1 --separate-stderr team-tickets T172 --html "$BATS_TEST_TMPDIR/nowhere/page.html"
  assert_equal "$stderr" "team-tickets: $BATS_TEST_TMPDIR/nowhere is not a directory, so $BATS_TEST_TMPDIR/nowhere/page.html cannot be written"
  [[ ! -e $BATS_TEST_TMPDIR/nowhere ]]
  run_bin -1 --separate-stderr team-tickets T172 --html "${page%/*}"
  assert_contains "$stderr" "is a directory"
}

@test "--html takes a file and goes with no other mode" {
  ticket 01-one "Blocked by: None"
  run_bin -2 team-tickets T172 --html
  run_bin -2 team-tickets T172 --html ""
  run_bin -2 team-tickets T172 --html "$page" --check
  run_bin -2 team-tickets T172 --json --html "$page"
  run_bin -2 team-tickets T172 --html "$page" --html "$page"
  [[ ! -e $page ]]
}

@test "--help documents --html, and no longer says it never writes" {
  run_bin -0 team-tickets --help
  assert_contains "$output" "Usage: team-tickets T<n> [--check] [--json] [--html <file>]"
  assert_contains "$output" "--html <file> writes the tickets as one self-contained HTML page"
  [[ $output != *"never writes"* ]]
}
