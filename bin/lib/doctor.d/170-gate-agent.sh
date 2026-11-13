# gate-agent    ~/.no-mistakes/config.yaml's agent, the gate's, set up one of the two ways the team
#               runs it. agent: opencode: the wrapper ~/.no-mistakes/bin/opencode-gate, which sets
#               opencode's environment (bin/lib/opencode-gate), installed, the code's bytes,
#               executable; opencode itself installed (the tool opencode line); and
#               agent_path_override naming the wrapper for opencode, whose fix is
#               team-bootstrap --stage tools, which sets it. agent: claude: claude installed (the
#               tool claude line), and agent_args_override.claude carrying --setting-sources with
#               sources that leave out user, and --strict-mcp-config, so the gate's claude loads
#               none of Daniel's user settings (their hooks, the Discord plugin, Remote Control) and
#               none of their MCP servers, and --settings naming a file whose attribution.commit is
#               empty (bin/lib/gate-claude-settings.json), since the user settings are what turn
#               commit attribution off; with no --settings at all and nothing else lacking it only
#               warns, so a resume goes on until Daniel adds it, since team-merge still refuses a
#               commit that carries the line, while a --settings naming a file that is not there or
#               leaves attribution on fails. It also warns, the gate still running, when a
#               --settings file runs no command-guard on Bash that is this checkout's
#               bin/hooks/command-guard (a PreToolUse command hook on a matcher of none, *, or a
#               |-list naming Bash, whose command's first word, unquoted and with a leading $HOME,
#               ${HOME} or ~ expanded as the hook's shell does, is that file), so the gate's
#               agents may kill or delete what is not their own; and when an item right after the
#               sources is no flag, which claude takes as an argument of its own (the second half
#               of an unquoted project,local in a flow list). Any other agent, or none (auto would pick whichever
#               agent no-mistakes finds first), fails. Only those keys of the file are read (none
#               holds a credential), and none of the rest printed.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's
# reads state from: 030-tools.sh

# Of config.yaml, the top-level agent, and agent_path_override's opencode or agent_args_override's
# claude (bin/lib/gate-config.awk, in block or flow form); the wrapper by its bytes and mode, each
# agent by its tool line.
wrapper=$HOME/.no-mistakes/bin/opencode-gate gate_config=$HOME/.no-mistakes/config.yaml
wrapper_fix="mkdir -p ~/.no-mistakes/bin && install -m 755 $(tilde "$bin/lib/opencode-gate") ~/.no-mistakes/bin/opencode-gate"
setting="agent_path_override: {opencode: $wrapper}" tools="$(tilde "$bin/team-bootstrap") --stage tools"
claude_args="agent_args_override: {claude: [--setting-sources, \"project,local\", --strict-mcp-config, --settings, $bin/lib/gate-claude-settings.json]}"
agent_fix="Daniel sets agent: opencode in ~/.no-mistakes/config.yaml (then $tools names the wrapper in it), or agent: claude with $claude_args"
agent=''
if [[ -f $gate_config ]]; then
  agent=$(awk '
    /^agent:/ { v = $0; sub(/^agent:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v); print v; exit }
  ' "$gate_config")
fi

# Whether the settings file <file> runs this checkout's command-guard on Bash, as the header says:
# gate_guarded <file>
gate_guarded() {
  local command word
  while IFS= read -r command; do
    case $command in
      \"*) word=${command#\"} && word=${word%%\"*} ;;
      \'*) word=${command#\'} && word=${word%%\'*} && [[ $word != *'$'* ]] || continue ;;
      '~/'*) word=$HOME/${command#'~/'} && word=${word%%[[:space:]]*} ;;
      *) word=${command%%[[:space:]]*} ;;
    esac
    case $word in
      '$HOME/'*) word=$HOME/${word#'$HOME/'} ;;
      '${HOME}/'*) word=$HOME/${word#'${HOME}/'} ;;
    esac
    [[ $word != *'$'* && $word -ef $bin/hooks/command-guard ]] && return 0
  done < <(jq -r '.hooks.PreToolUse // [] | .[]
    | select((.matcher // "") as $m | $m == "" or $m == "*" or ($m | split("|") | any(. == "Bash")))
    | .hooks // [] | .[] | select(.type == "command") | .command // empty' "$1" 2>/dev/null)
  return 1
}

if [[ $agent == claude ]]; then
  # The flags as no-mistakes passes them: --setting-sources takes the next item, or its own after
  # an =, and claude splits it on commas; every one given must leave out user. An item right after
  # that value which is no flag is an argument of claude's own: the second half of an unquoted
  # project,local in a flow list, say. --settings takes the next item or its own after an =, and
  # every one given must name a file whose commit attribution is off.
  gate_rc=0 gate_strict=0 gate_sources=() gate_user=0 gate_stray='' gate_settings=() gate_attributed=0 gate_unguarded=''
  gate_args=$(awk -v args=claude -f "$bin/lib/gate-config.awk" "$gate_config") || gate_rc=$?
  mapfile -t gate_items <<<"$gate_args"
  for ((i = 0; i < ${#gate_items[@]}; i++)); do
    case ${gate_items[i]} in
      --strict-mcp-config) gate_strict=1 && continue ;;
      --settings) gate_settings+=("${gate_items[i + 1]:-}") && i=$((i + 1)) && continue ;;
      --settings=*) gate_settings+=("${gate_items[i]#--settings=}") && continue ;;
      --setting-sources) gate_shown="--setting-sources ${gate_items[i + 1]:-}" gate_value=${gate_items[i + 1]:-} && i=$((i + 1)) ;;
      --setting-sources=*) gate_shown=${gate_items[i]} gate_value=${gate_items[i]#--setting-sources=} ;;
      *) continue ;;
    esac
    gate_sources+=("$gate_value")
    if [[ -z $gate_stray ]] && ((i + 1 < ${#gate_items[@]})) && [[ ${gate_items[i + 1]} != -* ]]; then
      gate_stray="${gate_items[i + 1]} right after $gate_shown"
    fi
  done
  for gate_value in "${gate_sources[@]}"; do
    [[ -n ${gate_value//[ ,]/} && ,${gate_value// /}, != *,user,* ]] || gate_user=1
  done
  for gate_value in "${gate_settings[@]}"; do
    [[ -f $gate_value ]] && jq -e '.attribution.commit == ""' "$gate_value" >/dev/null 2>&1 || gate_attributed=1
    [[ -n $gate_unguarded ]] || gate_guarded "$gate_value" || gate_unguarded=$gate_value
  done
  gate_missing=()
  ((${#gate_sources[@]} && !gate_user)) ||
    gate_missing+=("--setting-sources with sources that leave out user, so the gate's claude loads Daniel's user settings (their hooks, the Discord plugin, Remote Control)")
  ((gate_strict)) || gate_missing+=("--strict-mcp-config, so the gate's claude loads Daniel's MCP servers")
  ((${#gate_settings[@]} && !gate_attributed)) ||
    gate_missing+=("--settings naming a file whose attribution.commit is empty, so the gate's own commits carry no agent line")
  if [[ -z ${installed[claude]:-} ]]; then
    report gate-agent FAIL "claude is not installed, so the gate has no agent to run" "the tool claude line's fix"
  elif ((gate_rc)); then
    report gate-agent FAIL "$(tilde "$gate_config")'s agent_args_override is in a form team-doctor does not read (a flow collection over several lines, a nested one, or a scalar)" \
      "Daniel writes its claude list as a block or a one-line flow sequence: $claude_args"
  elif ((${#gate_missing[@]} == 1 && ${#gate_settings[@]} == 0)); then
    gate_reason="config.yaml runs the gate on claude with --setting-sources $(printf '%s\n' "${gate_sources[@]}" | paste -sd ' ' -) and --strict-mcp-config, but its agent_args_override.claude has no --settings naming a file whose attribution.commit is empty, so the gate's own commits may carry an agent line, which team-merge refuses, and its agents run no command-guard, so they may kill or delete what is not their own"
    [[ -z $gate_stray ]] || gate_reason+=", and it has $gate_stray, which claude takes as an argument of its own (an unquoted project,local in a flow list is two items)"
    report gate-agent WARN "$gate_reason" "Daniel sets $claude_args in ~/.no-mistakes/config.yaml"
  elif ((${#gate_missing[@]})); then
    gate_reason=$(printf '%s; ' "${gate_missing[@]}")
    report gate-agent FAIL "$(tilde "$gate_config") runs the gate on claude, but its agent_args_override.claude lacks ${gate_reason%; }" \
      "Daniel sets $claude_args in ~/.no-mistakes/config.yaml"
  else
    gate_shown="config.yaml runs the gate on claude with --setting-sources $(printf '%s\n' "${gate_sources[@]}" | paste -sd ' ' -), --strict-mcp-config, commit attribution off and command-guard on Bash"
    gate_quote="Daniel quotes the sources as one item in ~/.no-mistakes/config.yaml: $claude_args"
    gate_stray_reason="agent_args_override.claude has $gate_stray, which claude takes as an argument of its own (an unquoted project,local in a flow list is two items)"
    if [[ -n $gate_unguarded ]]; then
      gate_reason="config.yaml runs the gate on claude, but its --settings file $(tilde "$gate_unguarded") runs no command-guard on Bash, so the gate's agents may kill or delete what is not their own"
      gate_fix="Daniel's config names $bin/lib/gate-claude-settings.json, and the code checkout is ~/agent-team"
      [[ -z $gate_stray ]] || gate_reason+=", and $gate_stray_reason" gate_fix+="; and $gate_quote"
      report gate-agent WARN "$gate_reason" "$gate_fix"
    elif [[ -n $gate_stray ]]; then
      report gate-agent WARN "$gate_shown, but $gate_stray_reason" "$gate_quote"
    else
      report gate-agent PASS "$gate_shown, and claude is installed"
    fi
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
