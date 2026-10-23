# Set up this machine as a host

You are reading this because Daniel said "set up as host" (or the sentence in `README.md`) in a Claude Code session on this machine.
A **host** is a machine that can run Daniel's agent team: `team-doctor` passes, `team-load-check` passes, and it can take the lease whenever Daniel moves the team here.
Setting one up runs `bin/team-bootstrap` stage by stage, and hands Daniel only the steps that are theirs.
Arch Linux and macOS are supported; anything else stops at stage 1 with the reason.

Every stage is idempotent and `team-doctor` decides what is left, so "set up as host" on a half-set-up machine starts here again and picks up where the last run stopped.

## Talking to Daniel

Daniel stays in this conversation and does only what you cannot.
When the next step is Daniel's, stop and ask for that one step: what to do, where to do it, and what you will do once they say it is done.
Each request names one of three places:

- **In this session**, a command Daniel types with the `!` prefix, which runs it here and puts its output in the conversation: give the exact line, for example `! git -C ~/agent-team config core.hooksPath bin/hooks/git`.
  Use it for a short command that asks nothing and is Daniel's by rule.
- **In their own terminal** (Terminal on macOS, Konsole on Arch): anything that asks for a password or a confirmation, or that must keep values away from an agent: `sudo`, the Homebrew installer, `~/agent-team/bin/team-bootstrap --stage <stage>` when the bootstrap says so, `~/agent-team/bin/team-secrets restore`, `claude` in a project root for its trust dialog, and `team-resume --steal`.
  Give the exact command to paste.
- **In a browser or an app**: a login page, a GUI dialog, an app's settings, a Touch ID prompt: say what to click.

Run everything else yourself.
The rules for what you never touch (secrets, `op`, the lease) are in `sops/machine-setup.md`, "Rules for the agent"; read them before stage 2.

## Stage 1: git, gh and the team home

The team home is private, so this stage is the one Daniel's sentence describes before anything here is readable: get `gh`, sign Daniel in, clone, read this file.
Skip each step whose check already passes.

1. **macOS only, Xcode Command Line Tools.** Check: `xcode-select -p` prints a path.
   Otherwise run `xcode-select --install` yourself and ask Daniel to click Install in the dialog it opens and say when it finishes.
2. **macOS only, Homebrew.** Check: `brew --version` (or `/opt/homebrew/bin/brew --version` on Apple silicon, `/usr/local/bin/brew` on Intel).
   Otherwise ask Daniel to run, in their own terminal, the install command from https://brew.sh (it asks for their admin password), then the `brew shellenv` line it prints to add Homebrew to `~/.zprofile`.
   If your own shell still lacks `brew` afterwards, start each command with `eval "$(/opt/homebrew/bin/brew shellenv)" &&`.
3. **git and gh.** Check: `git --version` and `gh --version`.
   macOS: run `brew install bash git gh` yourself (the team's scripts refuse the Bash 3.2 macOS ships).
   Arch: ask Daniel to run `sudo pacman -S --needed git github-cli` in their own terminal.
4. **GitHub login.** Check: `gh auth status` says logged in to github.com.
   Otherwise run `gh auth login --web --git-protocol https --hostname github.com` yourself in the background: it prints a one-time code and https://github.com/login/device, then waits.
   Give Daniel the code and the link to open in a browser, and wait for the command to finish.
   Then run `gh auth setup-git`, so git uses the same login.
5. **The team home.** Check: `git -C ~/agent-team remote get-url origin` prints `https://github.com/chanjdaniel/agent-team.git`.
   Otherwise run `git clone https://github.com/chanjdaniel/agent-team.git ~/agent-team` (exactly this URL: the doctor checks it).

Done when all five checks pass and you are reading `~/agent-team/SETUP.md`.

## Stages 2 to 8, and 9 on Daniel's word

Follow `sops/machine-setup.md` from stage 2: it runs `team-bootstrap` one stage at a time and lists what each stage hands Daniel.
Stage 8 ends it with the doctor and the load check passing and one summary for Daniel in this conversation: ready as a standby, where moving the team here is Daniel saying "hand off" to the coordinator on the machine that holds it, or ready to take the team.
Stage 9 takes the team only when Daniel says it should run here.
