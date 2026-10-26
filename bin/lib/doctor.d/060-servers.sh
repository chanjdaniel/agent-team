# servers       servers/node_modules (the code checkout's) is the install of servers/package.json
#               and its lock, by the stamp servers/install leaves: the toolkits' MCP servers and
#               the chrome-devtools-mcp every session's chrome-devtools-axi runs. The fix is
#               servers/install.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's

# The stamp servers/install writes, against the package.json and lock it came from.
servers=$(dirname "$bin")/servers
if [[ ! -d $servers/node_modules ]]; then
  report servers FAIL "servers/node_modules is missing, so the toolkits' servers and the sessions' chrome-devtools-mcp cannot start" "$(tilde "$servers")/install"
elif [[ $(cat "$servers/node_modules/.installed-from" 2>/dev/null) != "$(cat "$servers/package.json" "$servers/package-lock.json" | sha256sum | cut -d' ' -f1)" ]]; then
  report servers FAIL "servers/node_modules is not the install of servers/package-lock.json, so a toolkit or chrome-devtools-axi may run another server" "$(tilde "$servers")/install"
else
  report servers PASS "servers/node_modules is the install of servers/package-lock.json"
fi
