# opencode-gate ~/.no-mistakes/bin/opencode-gate, the gate's opencode, which sets its
#               environment (bin/lib/opencode-gate): installed, the code's bytes, executable;
#               opencode itself installed (the tool opencode line); and ~/.no-mistakes/config.yaml
#               running the gate on it: its agent is opencode (auto would pick whichever agent
#               no-mistakes finds first) and its agent_path_override names the wrapper for
#               opencode, the two keys of that file read (it holds no credential), none of the
#               rest printed; the fix for agent_path_override is team-bootstrap --stage tools,
#               which sets it.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's

# The wrapper by its bytes and mode, opencode by its tool line; of config.yaml, the top-level
# agent and agent_path_override's opencode alone (bin/lib/gate-config.awk, in block or flow form),
# which the bootstrap's tools stage sets.
wrapper=$HOME/.no-mistakes/bin/opencode-gate gate_config=$HOME/.no-mistakes/config.yaml
wrapper_fix="mkdir -p ~/.no-mistakes/bin && install -m 755 $(tilde "$bin/lib/opencode-gate") ~/.no-mistakes/bin/opencode-gate"
setting="agent_path_override: {opencode: $wrapper}" tools="$(tilde "$bin/team-bootstrap") --stage tools"
step="as manual-steps.md's install of the no-mistakes fork says"
if [[ ! -e $wrapper ]]; then
  report opencode-gate FAIL "$(tilde "$wrapper") is not installed" "$wrapper_fix"
elif ! cmp -s "$bin/lib/opencode-gate" "$wrapper"; then
  report opencode-gate FAIL "$(tilde "$wrapper") is not the code's bin/lib/opencode-gate" "$wrapper_fix"
elif [[ ! -x $wrapper ]]; then
  report opencode-gate FAIL "$(tilde "$wrapper") is not executable" "$wrapper_fix"
elif [[ -z ${installed[opencode]:-} ]]; then
  report opencode-gate FAIL "opencode is not installed, so the wrapper has nothing to run" "the tool opencode line's fix"
elif [[ ! -f $gate_config ]]; then
  report opencode-gate FAIL "$(tilde "$gate_config") is not there" \
    "Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $tools sets $setting in it"
elif [[ $(awk -f "$bin/lib/gate-config.awk" "$gate_config") != "$wrapper" ]]; then
  report opencode-gate FAIL "$(tilde "$gate_config")'s agent_path_override does not name $(tilde "$wrapper") for opencode, so the gate's opencode reads Claude Code's config and not the gate's own" \
    "$tools, which sets $setting in ~/.no-mistakes/config.yaml, that key alone"
elif agent=$(awk '
    /^agent:/ { v = $0; sub(/^agent:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v); print v; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$gate_config") && [[ $agent == opencode ]]; then
  report opencode-gate PASS "$(tilde "$wrapper") is the code's bin/lib/opencode-gate, config.yaml runs the gate on opencode through it, and opencode is installed"
else
  if [[ -n ${agent:-} ]]; then reason="$(tilde "$gate_config")'s agent is $agent, not opencode,"; else reason="$(tilde "$gate_config") names no agent,"; fi
  report opencode-gate FAIL "$reason so the gate runs on whichever agent no-mistakes finds first and not through the wrapper" \
    "Daniel sets agent: opencode in ~/.no-mistakes/config.yaml, $step"
fi
