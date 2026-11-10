# shellcheck shell=bash
# Fixture transcripts of a worker session's tool calls and their results, for the tests of the
# load check's hook check and refusal probe: load it with `load helpers/transcript` after `load
# helpers/common`. Each helper prints one transcript line, in the shapes recorded on home-pc on
# 2026-11-10 from transcripts of Claude Code 2.1.316 to 2.1.321, trimmed to the fields the load
# check reads (an entry's type, toolDenialKind and permissionDecision, and its message's tool_use
# and tool_result items). A result's content is a string, as most are; a test that needs the other
# shape Claude Code writes, a list of {type: "text", text}, pipes the line through as_text_list.
#
#   tool_call <id> <tool> <input JSON>     an assistant entry with one tool_use
#   tool_result <id> <outcome> [<text>]    a user entry with that call's tool_result, shaped as
#                                          Claude Code records <outcome>:
#     ran            no toolDenialKind, is_error false (text "ok" by default)
#     hook           a PreToolUse hook's block: permission-rule, decision source "hook"
#     rule           a deny rule: permission-rule, source "config", reasonType "rule"
#     safety-check   a built-in safety check: permission-rule, reasonType "safetyCheck"
#     automode       auto mode's classifier refused it: automode-blocked
#     no-verdict     auto mode's classifier gave no verdict: automode-unavailable
#     <other>        any other toolDenialKind (user-rejected, interrupted), with no decision
#   hook_result <id> <hook> <tool> <input JSON> <cwd>
#                                          the hook's result entry for the call: tool_result's
#                                          hook outcome, its text Claude Code's wrapper around
#                                          what the real bin/hooks/<hook> prints on stderr when
#                                          it runs on that call in <cwd> (which is also its
#                                          CLAUDE_PROJECT_DIR), so a reworded hook shows here;
#                                          it runs with a TMPDIR of its own and no
#                                          CLAUDE_JOB_DIR, since the scratch hook lets a shell
#                                          write under either, and the sandbox is under TMPDIR
#   as_text_list                           a filter turning a result's string content into the
#                                          list form

tool_call() {
  jq -nc --arg id "$1" --arg name "$2" --argjson input "$3" \
    '{type: "assistant", message: {content: [{type: "tool_use", id: $id, name: $name, input: $input}]}}'
}

tool_result() {
  local id=$1 outcome=$2 text=${3-}
  jq -nc --arg id "$id" --arg outcome "$outcome" --arg text "$text" '
    {
      ran: {text: "ok"},
      hook: {kind: "permission-rule", decision: {decision: "reject", source: "hook", reasonType: "hook",
        reasonCode: "hook:PreToolUse"}},
      rule: {kind: "permission-rule", decision: {decision: "reject", source: "config", reasonType: "rule",
        ruleSource: "flagSettings", reasonCode: "rule:flagSettings"},
        text: "Permission to use Bash with command probe has been denied."},
      "safety-check": {kind: "permission-rule", decision: {decision: "reject", source: "config",
        reasonType: "safetyCheck", reasonCode: "safetyCheck"},
        text: "Permission for this command was denied by a built-in Claude Code safety check"},
      automode: {kind: "automode-blocked",
        text: "Permission for this action was denied by the Claude Code auto mode classifier. Reason: [...]"},
      "no-verdict": {kind: "automode-unavailable", decision: {decision: "reject", source: "config",
        reasonType: "classifier", reasonCode: "classifier:auto-mode:unavailable"},
        text: "The server-side auto mode classifier gave no verdict (error)"}
    }[$outcome] // {kind: $outcome, text: "The user does not want to proceed with this tool use."}
    | {type: "user"}
      + (if .kind then {toolDenialKind: .kind} else {} end)
      + (if .decision then {permissionDecision: .decision} else {} end)
      + {message: {content: [{type: "tool_result", tool_use_id: $id, is_error: ($outcome != "ran"),
          content: (if $text != "" then $text else .text // "" end)}]}}'
}

hook_result() {
  local id=$1 hook=$2 tool=$3 input=$4 cwd=$5 message
  message=$(jq -cn --arg tool "$tool" --argjson input "$input" --arg cwd "$cwd" \
    '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool, tool_input: $input}' |
    TMPDIR=$BATS_TEST_TMPDIR/hook-tmp CLAUDE_JOB_DIR='' CLAUDE_PROJECT_DIR=$cwd \
      "$REPO_ROOT/bin/hooks/$hook" 2>&1 >/dev/null) && {
    echo "hook_result: bin/hooks/$hook let the $tool call through" >&2
    return 1
  }
  tool_result "$id" hook "PreToolUse:$tool hook error: [$REPO_ROOT/bin/hooks/$hook]: $message"$'\n'
}

as_text_list() {
  jq -c '.message.content |= map(if .type == "tool_result" and (.content | type) == "string"
    then .content |= [{type: "text", text: .}] else . end)'
}
