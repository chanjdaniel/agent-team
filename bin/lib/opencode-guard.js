// The gate's opencode plugin that runs command-guard before each bash call of the gate's agents, as
// gate-claude-settings.json's PreToolUse hook does on a Claude gate. bin/lib/opencode-gate loads it
// for the gate's opencode alone, by $HOME/agent-team/bin/lib/opencode-guard.js in
// OPENCODE_CONFIG_CONTENT's plugin list, which opencode adds to the plugins of Daniel's
// opencode-gate.json without changing that file.
//
// Its tool.execute.before hook, which opencode runs before a tool and whose throw ends the call
// unrun, the error's message shown to the agent, gives this checkout's bin/hooks/command-guard a
// Claude-shaped input: tool_name "Bash", tool_input.command the call's command, and cwd its workdir
// resolved from the session's directory, with CLAUDE_PROJECT_DIR the session's git worktree (left
// to command-guard's own git lookup when opencode names none, as "/"), and no AGENT_TEAM_ROLE,
// AGENT_TEAM_TASK or CLAUDE_JOB_DIR, so the gate's agents take the no-role suffix and have no job
// tmp.
// command-guard's exit 0 passes the call; its exit 2 refuses it with its stderr; any other end (an
// exit code, a signal, its 10-second timeout, a start that fails, a command that is not a string)
// refuses it too, naming why, so a guard that cannot decide refuses. Another tool passes.
//
// opencode calls every export of a plugin module as a plugin, so this file exports one function.
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const guard = fileURLToPath(new URL("../hooks/command-guard", import.meta.url));
const timeoutMs = 10000;

// Run command-guard on input with env: resolves to { code, signal, stderr }, or rejects when it
// cannot start.
function runGuard(input, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(guard, [], { env, stdio: ["pipe", "ignore", "pipe"], timeout: timeoutMs });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal, stderr: stderr.trim() }));
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(input));
  });
}

export const CommandGuard = async ({ directory, worktree }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "bash") return;
    const command = output?.args?.command;
    if (typeof command !== "string") {
      throw new Error("Blocked by command-guard: it could not read the bash call's command (args.command, a string); a guardrail, so do not reach it another way.");
    }
    const workdir = output.args.workdir;
    const cwd = path.resolve(directory, typeof workdir === "string" ? workdir : ".");
    const env = { ...process.env };
    delete env.AGENT_TEAM_ROLE;
    delete env.AGENT_TEAM_TASK;
    delete env.CLAUDE_JOB_DIR;
    delete env.CLAUDE_PROJECT_DIR;
    if (worktree && worktree !== "/") env.CLAUDE_PROJECT_DIR = worktree;
    let result;
    try {
      result = await runGuard({ tool_name: "Bash", tool_input: { command }, cwd }, env);
    } catch (error) {
      throw new Error(`Blocked by command-guard: it could not start (${error.message}); a guardrail, so do not reach it another way.`);
    }
    if (result.code === 0) return;
    if (result.code === 2 && result.stderr) throw new Error(result.stderr);
    const end = result.signal ? `was ended by ${result.signal}` : `exited ${result.code}`;
    const said = result.stderr ? `: ${result.stderr}` : "";
    throw new Error(`Blocked by command-guard: it ${end}${said}; a guardrail, so do not reach it another way.`);
  },
});
