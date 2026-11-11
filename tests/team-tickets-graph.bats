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
  assert_equal "$(texts header | sed '$d')" "T172 toil
3 tickets in 1 phase, 3 levels; widest level 1 ticket.
Serial 3 tickets; critical path 3 tickets: 01 → 02 → 03."
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
