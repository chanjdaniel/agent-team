# ~/.no-mistakes/config.yaml's agent_path_override.opencode, the one key of that file the team
# reads and writes: the full path of the gate's opencode wrapper on this machine, no credential.
# No other line of the file is ever printed but into the edited copy.
#
#   awk -f gate-config.awk <config>                       prints the key's value, nothing when unset
#   awk -v set=<path> [-v eol=0] -f gate-config.awk <config>
#       prints the file with the key set to <path>, every other byte as it was (eol=0: the file
#       does not end with a newline, and the copy keeps it so); exit 3 when agent_path_override is
#       in a form this edit leaves to Daniel (a flow mapping over several lines, or a scalar) or
#       <path> holds a quote or a backslash, and then its output is no file.
#
# The key is read from the first top-level agent_path_override, in block form (indented
# "opencode:" lines under it, the first one taken) or in a flow mapping on its own line
# ({opencode: <path>, ...}); a value loses its comment and its quotes. A missing key is appended,
# in block form; one missing from a block goes right under its header, at its first child's indent.

# A value as written, without its comment, trailing blanks or quotes.
function unquote(v) {
  sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); gsub(/^["\047]|["\047]$/, "", v)
  return v
}

# <p> as a YAML scalar: plain when it needs no quotes, else double-quoted.
function scalar(p) {
  return p ~ /^[A-Za-z0-9_.\/~+-]+$/ ? p : "\"" p "\""
}

{ line[++n] = $0 }

END {
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
