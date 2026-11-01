# ~/.no-mistakes/config.yaml's keys the team reads: agent_path_override.opencode, the one it also
# writes, the full path of the gate's opencode wrapper on this machine; and agent_args_override's
# flags for one agent, which keep a Claude gate off Daniel's user settings. Neither holds a
# credential. No other line of the file is ever printed but into the edited copy.
#
#   awk -f gate-config.awk <config>                       prints the key's value, nothing when unset
#   awk -v set=<path> [-v eol=0] -f gate-config.awk <config>
#       prints the file with the key set to <path>, every other byte as it was (eol=0: the file
#       does not end with a newline, and the copy keeps it so); exit 3 when agent_path_override is
#       in a form this edit leaves to Daniel (a flow mapping over several lines, or a scalar) or
#       <path> holds a quote or a backslash, and then its output is no file.
#   awk -v args=<agent> -f gate-config.awk <config>
#       prints agent_args_override.<agent>'s items, one per line, nothing when unset; exit 3 and
#       nothing printed when agent_args_override or the list is in a form this read leaves to
#       Daniel (a flow collection over several lines, a nested one, or a scalar).
#
# The key is read from the first top-level agent_path_override, in block form (indented
# "opencode:" lines under it, the first one taken) or in a flow mapping on its own line
# ({opencode: <path>, ...}); a value loses its comment and its quotes. A missing key is appended,
# in block form; one missing from a block goes right under its header, at its first child's indent.
# The list is read from the first top-level agent_args_override, under its child <agent>: at the
# first child's indent ("- <item>" lines at that indent or deeper, or a flow sequence on its line)
# or in a flow mapping on its own line ({<agent>: [<item>, ...], ...}), by a key at the mapping's
# own level outside quotes, never one nested in a value or after its closing brace; a flow sequence
# splits on every comma outside quotes, as YAML does, so [a, b,c] is three items; a comment inside
# a one-line flow collection (a # after a blank, an opener or a comma, outside quotes) leaves it open
# on its line, which exits 3, and a quoted item keeps its #.

# A value as written, without its comment, trailing blanks or the quotes around it.
function unquote(v) {
  sub(/[ \t]+#.*$/, "", v)
  return bare(v)
}

# A value without its trailing blanks or the quotes around it: a flow item, whose comment is the
# line's.
function bare(v) {
  sub(/[ \t]+$/, "", v)
  if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
  return v
}

# <p> as a YAML scalar: plain when it needs no quotes, else double-quoted.
function scalar(p) {
  return p ~ /^[A-Za-z0-9_.\/~+-]+$/ ? p : "\"" p "\""
}

{ line[++n] = $0 }

END {
  if (args != "") { read_args(); exit }
  writing = set != ""
  if (writing && set ~ /["\\]/) exit 3
  for (h = 1; h <= n; h++) if (line[h] ~ /^agent_path_override:/) break
  if (h > n) {
    if (!writing) exit
    for (i = 1; i <= n; i++) print line[i]
    print "agent_path_override:"
    print "  opencode: " scalar(set)
    exit
  }
  key = line[h]; match(key, /^agent_path_override:[ \t]*/); key = substr(key, 1, RLENGTH)
  rest = substr(line[h], length(key) + 1)
  if (rest ~ /^\{/) {
    if (rest !~ /\}/) { if (writing) exit 3; exit }
    if (match(rest, /(^\{|,)[ \t]*opencode:[ \t]*[^,}]+/)) {
      pre = substr(rest, 1, RSTART - 1); found = substr(rest, RSTART, RLENGTH); post = substr(rest, RSTART + RLENGTH)
      match(found, /^[{,][ \t]*opencode:[ \t]*/); name = substr(found, 1, RLENGTH); v = substr(found, RLENGTH + 1)
      if (!writing) { print unquote(v); exit }
      match(v, /[ \t]*$/); blank = substr(v, RSTART)
      line[h] = key pre name scalar(set) blank post
    } else if (!writing) {
      exit
    } else if (rest ~ /^\{[ \t]*\}/) {
      sub(/^\{[ \t]*\}/, "{opencode: " scalar(set) "}", rest); line[h] = key rest
    } else {
      sub(/^\{[ \t]*/, "&opencode: " scalar(set) ", ", rest); line[h] = key rest
    }
    emit(n)
    exit
  }
  if (rest != "" && rest !~ /^#/) { if (writing) exit 3; exit }
  # The block: every line under the header up to the next top-level key.
  indent = "  "; child = 0
  for (j = h + 1; j <= n && line[j] !~ /^[^ \t#]/; j++) {
    if (!child && line[j] ~ /^[ \t]+[^ \t#]/) { match(line[j], /^[ \t]+/); indent = substr(line[j], 1, RLENGTH); child = 1 }
    if (line[j] ~ /^[ \t]+opencode:/) break
  }
  if (j <= n && line[j] ~ /^[ \t]+opencode:/) {
    match(line[j], /^[ \t]+opencode:[ \t]*/); name = substr(line[j], 1, RLENGTH); v = substr(line[j], RLENGTH + 1)
    if (!writing) { print unquote(v); exit }
    if (name !~ /[ \t]$/) name = name " "
    comment = match(v, /[ \t]+#.*$/) ? substr(v, RSTART) : ""
    line[j] = name scalar(set) comment
    emit(n)
    exit
  }
  if (!writing) exit
  emit(h)
  print indent "opencode: " scalar(set)
  for (j = h + 1; j <= n; j++) last(j)
}

# Print lines 1 to <to>, each with its newline but the file's last when eol=0 and <to> is it.
function emit(to,   i) { for (i = 1; i <= to; i++) last(i) }
function last(i) { if (i == n && eol == "0") printf "%s", line[i]; else print line[i] }

# agent_args_override.<args>'s items, one per line; nothing when the key or the agent is unset;
# exit 3, printing nothing, on a form this read leaves to Daniel.
function read_args(   h, rest, j, k, indent, keyre, v, at, pos) {
  for (h = 1; h <= n; h++) if (line[h] ~ /^agent_args_override:/) break
  if (h > n) return
  rest = line[h]; sub(/^agent_args_override:[ \t]*/, "", rest)
  keyre = "^[ \t]+" args ":[ \t]*"
  if (rest ~ /^\{/) {
    pos = flow_key(rest)
    if (pos < 0) exit 3
    if (!pos) return
    v = substr(rest, pos); sub(/^[ \t]+/, "", v)
    if (v !~ /^\[/ || !flow(v)) exit 3
    print_items()
    return
  }
  if (rest != "" && rest !~ /^#/) exit 3
  # The agent's key among the block's children, at their indent.
  indent = -1
  for (j = h + 1; j <= n && line[j] !~ /^[^ \t#]/; j++) {
    if (line[j] !~ /^[ \t]+[^ \t#]/) continue
    match(line[j], /^[ \t]+/)
    if (indent < 0) indent = RLENGTH
    if (RLENGTH == indent && line[j] ~ keyre) break
  }
  if (j > n || line[j] !~ keyre) return
  v = line[j]; sub(keyre, "", v)
  if (v ~ /^\[/) {
    if (!flow(v)) exit 3
    print_items()
    return
  }
  sub(/^#.*$/, "", v)
  if (v != "") exit 3
  # A block sequence: "- item" lines at the key's indent or deeper, blank and comment lines skipped.
  for (k = j + 1; k <= n; k++) {
    if (line[k] ~ /^[ \t]*(#.*)?$/) continue
    match(line[k], /^[ \t]*/); at = RLENGTH
    if (at < indent || (at == indent && line[k] !~ /^[ \t]*-([ \t]|$)/)) break
    if (line[k] !~ /^[ \t]*-[ \t]+[^ \t#]/) exit 3
    v = line[k]; sub(/^[ \t]*-[ \t]+/, "", v)
    items[++count] = unquote(v)
  }
  print_items()
}

# The items of the flow sequence <s> starts with into items[]: split on the commas outside quotes,
# up to its closing bracket; 0 when it has none on this line (a comment, a # after a blank or an
# opener outside quotes, ends the line), or holds a nested collection.
function flow(s,   i, c, q, item) {
  q = ""; item = ""
  for (i = 2; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; item = item c; continue }
    if (comment_at(s, i)) return 0
    if (c == "\"" || c == "\047") { q = c; item = item c; continue }
    if (c == "[" || c == "{") return 0
    if (c == "," || c == "]") {
      sub(/^[ \t]+/, "", item); sub(/[ \t]+$/, "", item)
      if (item != "") items[++count] = bare(item)
      else if (c == ",") return 0
      if (c == "]") return 1
      item = ""
      continue
    }
    item = item c
  }
  return 0
}

# Where the value of <args>'s key starts in the one-line flow mapping <s> starts with, a key of
# its own level outside quotes; 0 when it has none, -1 when the mapping does not close on this line
# (a comment inside it ends the line).
function flow_key(s,   i, c, q, depth, key, value, found) {
  q = ""; depth = 0; key = ""; value = 0; found = 0
  for (i = 2; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; if (!depth && !value) key = key c; continue }
    if (comment_at(s, i)) return -1
    if (c == "\"" || c == "\047") { q = c; if (!depth && !value) key = key c; continue }
    if (c == "[" || c == "{") { depth++; continue }
    if (c == "]" || c == "}") { if (!depth) return c == "}" ? found : -1; depth--; continue }
    if (depth) continue
    if (c == ",") { key = ""; value = 0; continue }
    if (value) continue
    if (c == ":") {
      sub(/^[ \t]+/, "", key)
      if (!found && bare(key) == args) found = i + 1
      value = 1
      continue
    }
    key = key c
  }
  return -1
}

# Whether a comment starts at <i> in <s>, outside quotes: a # after a blank or a flow opener or comma.
function comment_at(s, i) { return substr(s, i, 1) == "#" && substr(s, i - 1, 1) ~ /^[ \t\[{,]$/ }

function print_items(   i) { for (i = 1; i <= count; i++) print items[i] }
