# gate-agent    ~/.no-mistakes/config.yaml's agent, the gate's, set up one of the two ways the team
#               runs it. agent: opencode: the wrapper ~/.no-mistakes/bin/opencode-gate, which sets
#               opencode's environment (bin/lib/opencode-gate), installed, the code's bytes,
#               executable; opencode itself installed (the tool opencode line); and
#               agent_path_override naming the wrapper for opencode, whose fix is
#               team-bootstrap --stage tools, which sets it. agent: claude: claude installed (the
#               tool claude line), and agent_args_override.claude carrying --setting-sources with
#               sources that leave out user, and --strict-mcp-config, so the gate's claude loads
#               none of Daniel's user settings (their hooks, the Discord plugin, Remote Control) and
#               none of their MCP servers. Any other agent, or none (auto would pick whichever agent
#               no-mistakes finds first), fails. Only those keys of the file are read (none holds a
#               credential), and none of the rest printed.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's

# Of config.yaml, the top-level agent, and agent_path_override's opencode or agent_args_override's
# claude (bin/lib/gate-config.awk, in block or flow form); the wrapper by its bytes and mode, each
# agent by its tool line.
wrapper=$HOME/.no-mistakes/bin/opencode-gate gate_config=$HOME/.no-mistakes/config.yaml
wrapper_fix="mkdir -p ~/.no-mistakes/bin && install -m 755 $(tilde "$bin/lib/opencode-gate") ~/.no-mistakes/bin/opencode-gate"
setting="agent_path_override: {opencode: $wrapper}" tools="$(tilde "$bin/team-bootstrap") --stage tools"
claude_args='agent_args_override: {claude: [--setting-sources, "project,local", --strict-mcp-config]}'
agent_fix="Daniel sets agent: opencode in ~/.no-mistakes/config.yaml (then $tools names the wrapper in it), or agent: claude with $claude_args"
agent=''
if [[ -f $gate_config ]]; then
  agent=$(awk '
    /^agent:/ { v = $0; sub(/^agent:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v); print v; exit }
  ' "$gate_config")
fi

if [[ $agent == claude ]]; then
  # The flags as no-mistakes passes them: --setting-sources takes the next item, or its own after
  # an =, and claude splits it on commas; every one given must leave out user.
  gate_rc=0 gate_strict=0 gate_sources=() gate_user=0
  gate_args=$(awk -v args=claude -f "$bin/lib/gate-config.awk" "$gate_config") || gate_rc=$?
  mapfile -t gate_items <<<"$gate_args"
  for ((i = 0; i < ${#gate_items[@]}; i++)); do
    case ${gate_items[i]} in
      --strict-mcp-config) gate_strict=1 ;;
      --setting-sources) gate_sources+=("${gate_items[i + 1]:-}"); i=$((i + 1)) ;;
      --setting-sources=*) gate_sources+=("${gate_items[i]#--setting-sources=}") ;;
    esac
  done
  for gate_value in "${gate_sources[@]}"; do
    [[ -n ${gate_value//[ ,]/} && ,${gate_value// /}, != *,user,* ]] || gate_user=1
  done
  gate_missing=()
  ((${#gate_sources[@]} && !gate_user)) ||
    gate_missing+=("--setting-sources with sources that leave out user, so the gate's claude loads Daniel's user settings (their hooks, the Discord plugin, Remote Control)")
  ((gate_strict)) || gate_missing+=("--strict-mcp-config, so the gate's claude loads Daniel's MCP servers")
  if [[ -z ${installed[claude]:-} ]]; then
    report gate-agent FAIL "claude is not installed, so the gate has no agent to run" "the tool claude line's fix"
  elif ((gate_rc)); then
    report gate-agent FAIL "$(tilde "$gate_config")'s agent_args_override is in a form team-doctor does not read (a flow collection over several lines, a nested one, or a scalar)" \
      "Daniel writes its claude list as a block or a one-line flow sequence: $claude_args"
  elif ((${#gate_missing[@]})); then
    gate_reason=$(printf '%s; ' "${gate_missing[@]}")
    report gate-agent FAIL "$(tilde "$gate_config") runs the gate on claude, but its agent_args_override.claude lacks ${gate_reason%; }" \
      "Daniel sets $claude_args in ~/.no-mistakes/config.yaml"
  else
    report gate-agent PASS "config.yaml runs the gate on claude with --setting-sources $(printf '%s\n' "${gate_sources[@]}" | paste -sd ' ' -) and --strict-mcp-config, and claude is installed"
  fi
elif [[ ! -e $wrapper ]]; then
  report gate-agent FAIL "$(tilde "$wrapper") is not installed" "$wrapper_fix"
elif ! cmp -s "$bin/lib/opencode-gate" "$wrapper"; then
  report gate-agent FAIL "$(tilde "$wrapper") is not the code's bin/lib/opencode-gate" "$wrapper_fix"
elif [[ ! -x $wrapper ]]; then
  report gate-agent FAIL "$(tilde "$wrapper") is not executable" "$wrapper_fix"
elif [[ -z ${installed[opencode]:-} ]]; then
  report gate-agent FAIL "opencode is not installed, so the wrapper has nothing to run" "the tool opencode line's fix"
elif [[ ! -f $gate_config ]]; then
  report gate-agent FAIL "$(tilde "$gate_config") is not there" \
    "Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $tools sets $setting in it"
elif [[ $(awk -f "$bin/lib/gate-config.awk" "$gate_config") != "$wrapper" ]]; then
  report gate-agent FAIL "$(tilde "$gate_config")'s agent_path_override does not name $(tilde "$wrapper") for opencode, so the gate's opencode reads Claude Code's config and not the gate's own" \
    "$tools, which sets $setting in ~/.no-mistakes/config.yaml, that key alone"
elif [[ $agent == opencode ]]; then
  report gate-agent PASS "config.yaml runs the gate on opencode through $(tilde "$wrapper"), the code's bin/lib/opencode-gate, and opencode is installed"
elif [[ -n $agent ]]; then
  report gate-agent FAIL "$(tilde "$gate_config")'s agent is $agent, neither opencode nor claude, so the gate runs on neither setup the team checks" "$agent_fix"
else
  report gate-agent FAIL "$(tilde "$gate_config") names no agent, so the gate runs on whichever agent no-mistakes finds first" "$agent_fix"
fi
