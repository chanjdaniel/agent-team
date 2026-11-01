# Shared setup for the team home's bats tests: load it with `load helpers/common` and call
# `sandbox` from `setup`. Every test then runs real scripts from this checkout's bin/ against a
# temporary team home and HOME, with claude, gh, curl, op, systemctl, launchctl and busctl replaced
# by logging stubs, so no test reaches this machine's own service managers, cgroups or 1Password. A test of
# a script that runs Docker adds a stub docker with `load helpers/docker` (tests/helpers/docker.bash
# documents it), and never reaches this machine's Docker, which DOCKER_HOST points away from.
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

# The scripts' platform rules apply to the tests too: on macOS, .bats files get the GNU tools.
# shellcheck source=bin/lib/platform.sh
source "$BATS_TEST_DIRNAME/../bin/lib/platform.sh"

# The checkout under test, whichever worktree it is.
REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
FAKE_DISCORD_TOKEN=fake-discord-token-for-tests

# macOS assesses every new executable file on its first run, a quarter of a second each, so a
# test that wrote its stubs or copied bin/ afresh spent most of its time waiting on that. The
# executables tests share are therefore made once per bats run, read-only, under
# $BATS_RUN_TMPDIR/shared, and each test hard-links them in (link_shared): the same file to macOS,
# a file of its own to the test, which may replace or remove it but never write into it.

# shared <name> [<source>]: the path of the run's read-only <name>, made the first time from
# <source> (a file or a directory, copied) or, without one, from stdin as an executable.
shared() {
  local dir=$BATS_RUN_TMPDIR/shared new
  if [[ ! -e $dir/$1 ]]; then
    mkdir -p "$dir/$(dirname "$1")"
    new=$(mktemp -d "$dir/.new.XXXXXX")
    if (($# > 1)); then cp -R "$2" "$new/it"; else cat >"$new/it" && chmod +x "$new/it"; fi
    find "$new/it" -type f -exec chmod a-w {} +
    # A file or directory another test made meanwhile stays: either is the same.
    mv -T "$new/it" "$dir/$1" 2>/dev/null || true
    rm -rf "$new"
  fi
  echo "$dir/$1"
}

# link_shared <name> <source> <dest>: <dest> as `cp -R <source> <dest>` makes it, but each file
# a hard link to the run's shared copy <name> of <source>.
link_shared() {
  cp -Rl "$(shared "$1" "$2")" "$3"
}

# stub_command <cmd>...: each <cmd> on the sandbox's PATH is the logging stub, tests/helpers/stub.
stub_command() {
  local cmd
  for cmd; do ln -f "$(shared stub "$REPO_ROOT/tests/helpers/stub")" "$BATS_TEST_TMPDIR/stubs/$cmd"; done
}

# copy_bin <dest>: a copy of this checkout's bin/ at <dest>, its files linked to the run's shared
# copy (link_shared).
copy_bin() {
  link_shared bin "$REPO_ROOT/bin" "$1"
}

# Build the test's sandbox and point TEAM_HOME, HOME and PATH into it.
sandbox() {
  # macOS keeps temporary directories under /var, a symlink to /private/var, and the scripts see
  # the resolved path (from pwd, git or realpath): resolve it once, so every path a test builds
  # from BATS_TEST_TMPDIR is the one the scripts print, on Linux and macOS alike.
  BATS_TEST_TMPDIR=$(realpath "$BATS_TEST_TMPDIR")
  local root=$BATS_TEST_TMPDIR
  # The ledger reads a path under /home/<user>/ or /Users/<user>/ as under some machine's HOME
  # (local_path in bin/lib/ledger.jq), so a sandbox there would see its own paths moved.
  if [[ $root =~ ^/(home|Users)/[^/]+/ ]]; then
    echo "sandbox: the test's directory $root is under a home directory, whose paths the ledger" \
      "reads as any machine's HOME; run the tests with TMPDIR outside /home and /Users (e.g. TMPDIR=/tmp)" >&2
    return 1
  fi
  export TEAM_HOME=$root/team HOME=$root/home
  export STUB_CALLS=$root/calls STUB_FIXTURES=$root/fixtures
  # The library's system tool directories (treehouse's /usr/local/bin on Arch) are under this
  # directory, so a PATH a test trims never gets the machine's own tools back, its 1Password CLI
  # above all (tool_dirs in bin/lib/team.sh).
  export TEAM_SYSTEM_ROOT=$root/system
  mkdir -p "$TEAM_HOME" "$HOME/.claude/channels/discord" "$STUB_CALLS" "$STUB_FIXTURES" "$root/stubs"
  : >"$TEAM_HOME/ledger.jsonl"
  echo "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN" >"$HOME/.claude/channels/discord/.env"

  stub_command claude gh curl op systemctl launchctl busctl
  export PATH=$root/stubs:$PATH
  # The user manager's D-Bus answers every call with a job (fake_placement makes it move the
  # processes), and the cgroup tree and /proc team-capacity reads are under TEAM_CGROUP_ROOT, empty
  # until a test writes them (user_controllers, fake_process), never the machine's own.
  stub_reply busctl 'o "/org/freedesktop/systemd1/job/1"'
  export TEAM_CGROUP_ROOT=$root/cgroup-root
  mkdir -p "$TEAM_CGROUP_ROOT/proc"

  # The machine team-slots reads its load from (its seams): no process, 12 cores and 24 GiB of 32
  # available, and a Docker socket nothing listens on, so no reading depends on the machine the
  # suite runs on, macOS (whose sysctl and vm_stat TEAM_MEMINFO stands for too) or Linux, and no
  # test reaches its Docker unless it stubs one (helpers/docker).
  export TEAM_SLOTS_PROCS=$root/slots-procs TEAM_SLOTS_CPUS=12 TEAM_MEMINFO=$root/meminfo
  export DOCKER_HOST=unix://$root/no-docker.sock
  : >"$TEAM_SLOTS_PROCS"
  printf 'MemTotal:       %s kB\nMemFree:         1048576 kB\nMemAvailable:   %s kB\n' $((32 * 1024 * 1024)) \
    $((24 * 1024 * 1024)) >"$TEAM_MEMINFO"

  # git reads only the sandbox's config.
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git config --global user.name "Team Test"
  git config --global user.email team-test@example.invalid
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false

  # nvm lives under HOME unless NVM_DIR says otherwise: the real one must not leak in, nor the
  # heavy run tests/run holds (team-heavy), nor the role and task of the session running the suite
  # (worker_refusal).
  unset TEAM_COORDINATOR_CHANNEL TEAM_INTERVIEW_CHANNEL CLAUDE_PROJECT_DIR NVM_DIR TEAM_HEAVY_HELD TEAM_HEAVY_WAIT_MINUTES
  unset AGENT_TEAM_ROLE AGENT_TEAM_TASK
  guard_sandbox
}

# Fail unless TEAM_HOME and HOME are inside this test's temporary directory, so no test can
# reach the real team home or the real HOME.
guard_sandbox() {
  local root var path
  root=$(realpath "$BATS_TEST_TMPDIR")
  for var in TEAM_HOME HOME; do
    path=$(realpath -m -- "${!var:-/}")
    if [[ $path != "$root"/* ]]; then
      echo "sandbox guard: $var=${!var:-} is outside the test's directory $root" >&2
      return 1
    fi
  done
}

# Run a script from this checkout's bin/ (or from CODE_CHECKOUT's, when a test made a code
# checkout of its own) with bats' `run`, after the sandbox guard.
# Leading options go to `run` (e.g. `run_bin -2 team-thread`, `run_bin --separate-stderr ...`).
# team-resume fast-forwards the checkout it runs from, so it runs only from a code checkout of the
# test's own (code_checkout), but for --help.
run_bin() {
  local opts=()
  while [[ $1 == -* ]]; do opts+=("$1"); shift; done
  guard_sandbox || return 1
  if [[ $1 == team-resume && ${2:-} != --help && -z ${CODE_CHECKOUT:-} ]]; then
    echo "run_bin: team-resume fast-forwards its code checkout, so it runs only from the test's own: call code_checkout first" >&2
    return 1
  fi
  run "${opts[@]}" "${CODE_CHECKOUT:-$REPO_ROOT}/bin/$1" "${@:2}"
}

# Make CODE_CHECKOUT, a code checkout of the test's own for run_bin to run from, so a script that
# fast-forwards its code checkout never touches this one: <checkout> when given (a clone with an
# origin), else a clone on dev of a bare origin standing in for GitHub, CODE_ORIGIN
# ($BATS_TEST_TMPDIR/code-origin.git), with one commit. Either way it gets a copy of the code the
# scripts read from their checkout (bin/, roles/, settings/, templates/, plugins/, toolkits/ and
# coordinator.settings.json), which git ignores there: code_checkout [<checkout>]
code_checkout() {
  export CODE_CHECKOUT CODE_ORIGIN
  if [[ -n ${1:-} ]]; then
    CODE_CHECKOUT=$(realpath "$1")
  else
    CODE_ORIGIN=$BATS_TEST_TMPDIR/code-origin.git
    CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
    git init -q --bare -b dev "$CODE_ORIGIN"
    git clone -q "$CODE_ORIGIN" "$CODE_CHECKOUT" 2>/dev/null
    git -C "$CODE_CHECKOUT" checkout -q -B dev
    echo "code" >"$CODE_CHECKOUT/README.md"
    git -C "$CODE_CHECKOUT" add README.md
    git -C "$CODE_CHECKOUT" commit -q -m "chore: start the code"
    git -C "$CODE_CHECKOUT" push -q -u origin dev
  fi
  local path exclude
  exclude=$(git -C "$CODE_CHECKOUT" rev-parse --path-format=absolute --git-path info/exclude)
  copy_bin "$CODE_CHECKOUT/bin"
  for path in roles settings templates plugins toolkits coordinator.settings.json; do
    cp -R "$REPO_ROOT/$path" "$CODE_CHECKOUT/$path"
  done
  printf '/%s\n' bin roles settings templates plugins toolkits coordinator.settings.json >>"$exclude"
}

# Push a commit touching <path> to <origin>'s dev from a clone of its own, as another machine's
# merge would; prints the new commit: push_to_dev <origin> <path>
push_to_dev() {
  local clone
  clone=$(mktemp -d "$BATS_TEST_TMPDIR/push.XXXXXX")
  git clone -q "$1" "$clone"
  git -C "$clone" checkout -q dev
  mkdir -p "$(dirname "$clone/$2")"
  echo "$RANDOM" >>"$clone/$2"
  git -C "$clone" add "$2"
  git -C "$clone" commit -q -m "feat: change $2"
  git -C "$clone" push -q origin dev
  git -C "$clone" rev-parse HEAD
}

# The effective cap's reason when team-slots took its own reading on the sandbox's idle machine,
# the newest under <home> (default HOME): sampled_reason [<home>]
sampled_reason() {
  tail -n 1 "${1:-$HOME}/.local/state/agent-team/slots/readings.jsonl" |
    jq -r '"other programs use 8.0 GiB of 32.0 GiB (the reading of \(.at | fromdateiso8601 | strflocaltime("%H:%M")))"'
}

# The stub <cmd> prints <stdout> and exits with <status> (default 0).
stub_reply() {
  printf '%s\n' "$2" >"$STUB_FIXTURES/$1.out"
  echo "${3:-0}" >"$STUB_FIXTURES/$1.status"
}

# The stub <cmd> runs the Bash read from stdin, with the call's arguments as "$@".
stub_script() {
  cat >"$STUB_FIXTURES/$1.sh"
}

# The calls made to stub <cmd>, one JSON array of arguments per line (nothing if never called).
stub_calls() {
  cat "$STUB_CALLS/$1.log" 2>/dev/null || true
}

# Make the systemctl and launchctl stubs behave as the user's systemd and launchd would, each
# machine's units kept under its own HOME: systemctl --user daemon-reload, enable, disable (with
# --now), restart, is-enabled and is-active on unit files under ~/.config/systemd/user, and show -P
# <property> [<unit>], which answers the manager's Version as 262 and a unit's property from
# ~/.fake-systemd/<unit>.<property> (empty without one), a test's to write; every call fails as a
# user manager that does not answer once ~/.fake-systemd/down exists; launchctl
# bootstrap gui/<uid> <plist>, bootout gui/<uid>/<label> and print gui/<uid>/<label>, refusing as
# launchctl does a bootstrap of a loaded job or a bootout of one not loaded.
fake_service_managers() {
  stub_script systemctl <<'EOF'
units=$HOME/.config/systemd/user state=$HOME/.fake-systemd
mkdir -p "$state"
[[ ${1:-} == --user ]] || { echo "systemctl stub: only --user calls are planned: $*" >&2; exit 1; }
if [[ -e $state/down ]]; then echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2; exit 1; fi
if [[ ${2:-} == show && ${3:-} == -P ]]; then
  if [[ -z ${5:-} ]]; then
    [[ $4 == Version ]] || { echo "systemctl stub: unplanned manager property: $4" >&2; exit 127; }
    echo 262
  else
    cat "$state/$5.$4" 2>/dev/null || echo
  fi
  exit 0
fi
verb=${2:-} now=0 quiet=0 names=()
for arg in "${@:3}"; do
  case $arg in
    --now) now=1 ;;
    --quiet) quiet=1 ;;
    *) names+=("$arg") ;;
  esac
done
for name in "${names[@]}"; do
  if [[ $verb != is-* && ! -f $units/$name ]]; then
    echo "Failed to $verb unit: Unit file $name does not exist." >&2
    exit 1
  fi
done
case $verb in
  daemon-reload) ;;
  enable) for name in "${names[@]}"; do touch "$state/$name.enabled"; if ((now)); then touch "$state/$name.active"; fi; done ;;
  disable) for name in "${names[@]}"; do rm -f "$state/$name.enabled"; if ((now)); then rm -f "$state/$name.active"; fi; done ;;
  restart) for name in "${names[@]}"; do touch "$state/$name.active"; done ;;
  is-enabled)
    if [[ -e $state/${names[0]}.enabled ]]; then ((quiet)) || echo enabled; exit 0; fi
    ((quiet)) || echo disabled
    exit 1 ;;
  is-active)
    if [[ -e $state/${names[0]}.active ]]; then ((quiet)) || echo active; exit 0; fi
    ((quiet)) || echo inactive
    exit 3 ;;
  *) echo "systemctl stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
  stub_script launchctl <<'EOF'
state=$HOME/.fake-launchd domain=gui/$(id -u)
mkdir -p "$state"
case ${1:-} in
  bootstrap)
    [[ $2 == "$domain" && -f $3 ]] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    label=$(sed -n '/<key>Label<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$3")
    [[ ! -e $state/$label ]] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    cp "$3" "$state/$label" ;;
  bootout | print)
    label=${2#"$domain"/}
    if [[ $2 != "$domain/$label" || ! -e $state/$label ]]; then
      echo "Could not find service \"$label\" in domain for user gui: $(id -u)" >&2
      exit 113
    fi
    if [[ $1 == bootout ]]; then rm "$state/$label"; else echo "$domain/$label = {"; echo "	state = running"; echo "}"; fi ;;
  *) echo "launchctl stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
}

# The user manager's cgroup delegates the controllers <controller>... (cpu memory pids on home-pc),
# as its cgroup.controllers under TEAM_CGROUP_ROOT says; none given writes an empty list.
user_controllers() {
  local dir
  dir=$TEAM_CGROUP_ROOT/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service
  mkdir -p "$dir"
  echo "$*" >"$dir/cgroup.controllers"
}

# user_cgroup <unit> [<slice>]: the cgroup path of the user manager's <unit>, in <slice> when it is
# a scope or service (app.slice without one), as systemd nests a slice under each dash prefix of
# its name: agent-team-T7.slice is agent.slice/agent-team.slice/agent-team-T7.slice.
user_cgroup() {
  local unit=$1 name path='' prefix='' part
  if [[ $unit == *.slice ]]; then name=${unit%.slice}; else name=${2:-app.slice} && name=${name%.slice}; fi
  for part in ${name//-/ }; do
    prefix+=${prefix:+-}$part
    path+=/$prefix.slice
  done
  [[ $unit == *.slice ]] || path+=/$unit
  echo "/user.slice/user-$(id -u).slice/user@$(id -u).service$path"
}

# fake_process <pid> <ppid> <cgroup> [<arg>...]: a process under TEAM_CGROUP_ROOT's /proc, its
# parent <ppid>, in the cgroup <cgroup> (a path, or - for the Konsole tab's scope the claude
# daemon's sessions are in on home-pc), running <arg>... (default sleep).
fake_process() {
  local dir=$TEAM_CGROUP_ROOT/proc/$1 cgroup=$3
  [[ $cgroup != - ]] || cgroup="/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/app-org.kde.konsole-2626.scope/tab(305042).scope"
  mkdir -p "$dir"
  printf 'Name:\t%s\nPid:\t%s\nPPid:\t%s\n' "$(basename "${4:-sleep}")" "$1" "$2" >"$dir/status"
  echo "0::$cgroup" >"$dir/cgroup"
  if (($# > 3)); then printf '%s\0' "${@:4}" >"$dir/cmdline"; else printf 'sleep\0' >"$dir/cmdline"; fi
}

# The cgroup the fake process <pid> is in.
cgroup_of() {
  sed -n 's/^0:://p' "$TEAM_CGROUP_ROOT/proc/$1/cgroup"
}

# Make the busctl stub do what the user manager does for StartTransientUnit: move each of its PIDs
# into the scope, under its Slice, and answer with a job; a call naming a pid listed in
# $STUB_FIXTURES/busctl-refuse is refused and moves nothing, and so is one naming a pid listed in
# $STUB_FIXTURES/busctl-gone, whose process then exits (its /proc entry goes), as one that ends
# between the read of the tree and the call.
fake_placement() {
  stub_script busctl <<'EOF'
[[ ${2:-} == call && ${6:-} == StartTransientUnit ]] || { echo "busctl stub: unplanned call: $*" >&2; exit 127; }
scope=$8 args=("${@:11}") pids=() slice=''
while ((${#args[@]})); do
  case ${args[0]} in
    PIDs) n=${args[2]} && pids=("${args[@]:3:n}") && args=("${args[@]:3+n}") ;;
    Slice) slice=${args[2]} && args=("${args[@]:3}") ;;
    0) args=("${args[@]:1}") ;;
    *) args=("${args[@]:3}") ;;
  esac
done
for pid in "${pids[@]}"; do
  if grep -qxF "$pid" "$STUB_FIXTURES/busctl-gone" 2>/dev/null; then
    rm -rf "${TEAM_CGROUP_ROOT:?}/proc/$pid"
    echo "Call failed: Failed to add PID $pid to scope unit: No such process" >&2
    exit 1
  fi
  if grep -qxF "$pid" "$STUB_FIXTURES/busctl-refuse" 2>/dev/null; then
    echo "Call failed: Access denied" >&2
    exit 1
  fi
done
path='' prefix='' name=${slice%.slice}
for part in ${name//-/ }; do prefix+=${prefix:+-}$part && path+=/$prefix.slice; done
for pid in "${pids[@]}"; do
  echo "0::/user.slice/user-$(id -u).slice/user@$(id -u).service$path/$scope" >"$TEAM_CGROUP_ROOT/proc/$pid/cgroup"
done
echo 'o "/org/freedesktop/systemd1/job/7"'
EOF
}

# Run the sandbox as macOS: uname stubbed to say Darwin, and a fake Homebrew (HOMEBREW_PREFIX)
# with the directories of the GNU tools bin/lib/platform.sh puts first on PATH.
as_macos() {
  [[ -e $BATS_TEST_TMPDIR/stubs/uname ]] || stub_command uname
  stub_reply uname Darwin
  export HOMEBREW_PREFIX=$BATS_TEST_TMPDIR/brew
  local dir
  for dir in coreutils/libexec/gnubin findutils/libexec/gnubin gnu-sed/libexec/gnubin \
    grep/libexec/gnubin flock/bin; do
    mkdir -p "$HOMEBREW_PREFIX/opt/$dir"
  done
}

# Build a bare repo as origin and a primary clone at $HOME/projects/<name>, with one commit on
# <branch> (default main) pushed; prints the clone's path.
make_repo() {
  local name=$1 branch=${2:-main}
  local origin=$BATS_TEST_TMPDIR/origin/$name.git clone=$HOME/projects/$name
  git init -q --bare -b "$branch" "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" checkout -q -B "$branch"
  echo "$name" >"$clone/README.md"
  git -C "$clone" add README.md
  git -C "$clone" commit -q -m "chore: start $name"
  git -C "$clone" push -q -u origin "$branch"
  git -C "$clone" remote set-head origin "$branch"
  echo "$clone"
}

# other_spelling <path>: another spelling of the existing <path>, its last part upper-cased, which
# names the same directory: by itself on a case-insensitive filesystem (APFS, as on a Mac), where
# realpath keeps the case it is given, else through a symlink so named.
other_spelling() {
  local other
  other=$(dirname "$1")/$(basename "$1" | tr '[:lower:]' '[:upper:]')
  [[ $other != "$1" ]] || other=$1-OTHER
  [[ $other -ef $1 ]] || ln -s "$(basename "$1")" "$other"
  echo "$other"
}

# Make the sandbox's team home a clone of a bare origin standing in for GitHub (at
# $BATS_TEST_TMPDIR/origin/agent-team.git), fetching only dev and lease as SETUP.md clones it,
# with its files committed on dev and pushed, and name this machine <name> (default home-pc);
# prints the origin's path.
make_team_home() {
  local origin
  origin=$BATS_TEST_TMPDIR/origin/agent-team.git
  git init -q --bare -b dev "$origin"
  git -C "$TEAM_HOME" init -q -b dev
  git -C "$TEAM_HOME" remote add origin "$origin"
  git -C "$TEAM_HOME" remote set-branches origin dev lease
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q -m "chore: start the team home"
  git -C "$TEAM_HOME" push -q -u origin dev
  mkdir -p "$HOME/.config/agent-team"
  echo "${1:-home-pc}" >"$HOME/.config/agent-team/machine"
  echo "$origin"
}

# Make the sandbox's team home a clone of a bare origin (make_team_home) and take the lease as
# this machine, named <name> (default home-pc), so the team's sessions may launch here; prints
# the origin's path.
hold_lease() {
  local origin
  origin=$(make_team_home "${1:-home-pc}")
  "$REPO_ROOT/bin/team-lease" take >/dev/null
  echo "$origin"
}

# A backlog story of <project> in the team home, its front matter as the backlog writes it:
# backlog_story <project> <path under backlog/> <id> [<status> [<pr list>]]
backlog_story() {
  local file=$TEAM_HOME/projects/$1/backlog/$2
  mkdir -p "${file%/*}"
  printf -- '---\nid: %s\ntitle: A story\ntype: story\nstatus: %s\nblocked_by: []\npr: %s\n---\n\n## What to build\n\nstatus: ready\npr: []\n' \
    "$3" "${4:-ready}" "${5:-[]}" >"$file"
}

# add_loose <n> [--unreachable]: <n> new loose blobs in the team home, kept reachable by a commit
# of them (one more tree and commit) at a refs/keep/ ref of their own, or with --unreachable, none.
add_loose() {
  local dir i shas tree commit
  dir=$(mktemp -d "$BATS_TEST_TMPDIR/loose.XXXXXX")
  for ((i = 1; i <= $1; i++)); do echo "$dir $i" >"$dir/$i"; done
  shas=$(find "$dir" -type f | git -C "$TEAM_HOME" hash-object -w --stdin-paths)
  [[ ${2:-} != --unreachable ]] || return 0
  tree=$(awk '{printf "100644 blob %s\tf%d\n", $1, NR}' <<<"$shas" | git -C "$TEAM_HOME" mktree)
  commit=$(git -C "$TEAM_HOME" commit-tree "$tree" -m "test: loose objects")
  git -C "$TEAM_HOME" update-ref "refs/keep/${dir##*.}" "$commit"
}

# The team home's loose objects, as git counts them.
loose_count() {
  git -C "$TEAM_HOME" count-objects -v | sed -n 's/^count: //p'
}

# lease_json [<git dir>]: the lease on the lease branch of the team home's origin (make_team_home),
# or of <git dir>.
lease_json() {
  git -C "${1:-$BATS_TEST_TMPDIR/origin/agent-team.git}" show lease:lease.json
}

# Rewrite the lease on the team home's origin as if its holder last renewed <minutes> ago: a new
# commit on the branch.
age_lease() {
  local origin blob tree commit
  origin=$BATS_TEST_TMPDIR/origin/agent-team.git
  blob=$(lease_json | jq -c --argjson m "$1" '.renewed_at = (now - $m * 60 | floor | todate)' |
    git -C "$origin" hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tlease.json\n' "$blob" | git -C "$origin" mktree)
  commit=$(git -C "$origin" commit-tree "$tree" -p lease -m "test: age the lease")
  git -C "$origin" update-ref refs/heads/lease "$commit"
}

# Build a second machine named <name> (make_team_home first): its own HOME, with this HOME's git
# identity and Discord token and its own machine name, its own team home cloned from the team
# home's origin as SETUP.md clones it (dev and lease only), and a clone at <its HOME>/projects/<repo> of every other bare origin made so
# far (make_repo). Run commands there with on_machine.
make_machine() {
  local name=$1 root origin repo
  root=$BATS_TEST_TMPDIR/machines/$name
  mkdir -p "$root/home/.config/agent-team" "$root/home/.claude/channels/discord"
  cp "$HOME/.gitconfig" "$root/home/.gitconfig"
  cp "$HOME/.claude/channels/discord/.env" "$root/home/.claude/channels/discord/.env"
  echo "$name" >"$root/home/.config/agent-team/machine"
  git clone -q --single-branch --branch dev "$BATS_TEST_TMPDIR/origin/agent-team.git" "$root/team"
  git -C "$root/team" remote set-branches --add origin lease
  for origin in "$BATS_TEST_TMPDIR"/origin/*.git; do
    repo=${origin##*/}
    repo=${repo%.git}
    [[ $repo != agent-team ]] || continue
    git clone -q "$origin" "$root/home/projects/$repo" 2>/dev/null
  done
}

# Run <command...> on the machine make_machine built: with its HOME and its team home, e.g.
# `on_machine laptop run_bin -0 team-lease take`.
on_machine() {
  local root
  root=$BATS_TEST_TMPDIR/machines/$1
  [[ -d $root ]] || { echo "on_machine: no machine $1 (make_machine $1 first)" >&2; return 1; }
  HOME=$root/home TEAM_HOME=$root/team "${@:2}"
}

# Steal the lease on machine <name> (make_machine) from its holder <holder>, typing the holder's
# name on the steal's terminal as Daniel would: steal_lease <name> <holder>
steal_lease() {
  local tty
  tty=$BATS_TEST_TMPDIR/steal-tty
  echo "$2" >"$tty"
  TEAM_LEASE_TTY=$tty on_machine "$1" "$REPO_ROOT/bin/team-lease" take --steal >/dev/null
}

# The subcommands of <command>, one per line and trimmed: its parts between the ;, &, && , | and
# || that stand outside quotes, as Claude Code splits a chain before it matches each part against
# the deny rules: subcommands <command>
subcommands() {
  local command=$1 part='' quote='' c i
  for ((i = 0; i < ${#command}; i++)); do
    c=${command:i:1}
    if [[ -n $quote ]]; then
      [[ $c != "$quote" ]] || quote=''
    elif [[ $c == "'" || $c == '"' ]]; then
      quote=$c
    elif [[ $c == ';' || $c == '&' || $c == '|' ]]; then
      printf '%s\n' "$part"
      part=''
      continue
    fi
    part+=$c
  done
  printf '%s\n' "$part"
}

# The texts Claude Code matches a Bash deny or ask rule against for <command>, one per line: the
# command and each of its subcommands, each also past its leading variable assignments, and that
# with its first word's directory dropped, so a rule naming a bare command also matches it run by
# path (rQ, eyt and V$ in Claude Code 2.1.312; allow rules get none but the first): deny_forms <command>
deny_forms() {
  local whole=$1 part command
  printf '%s\n' "$whole"
  while IFS= read -r part; do
    part=${part#"${part%%[![:space:]]*}"} part=${part%"${part##*[![:space:]]}"}
    [[ -n $part ]] || continue
    command=$part
    printf '%s\n' "$part"
    while [[ $command =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do command=${BASH_REMATCH[1]}; done
    [[ $command == "$part" ]] || printf '%s\n' "$command"
    if [[ $command =~ ^[^[:space:]]*/([^[:space:]/]+)(.*)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    fi
  done < <(subcommands "$whole")
}

# Whether the Bash rule's content <pattern> matches <text> as Claude Code's i8 does (2.1.314): each
# * matches any text, and a rule whose one * ends it after a space also matches the text before
# that space alone, so `git config core.hooksPath *` matches `git config core.hooksPath`, a read,
# while a rule of two stars never drops its last: rule_text_matches <pattern> <text>
rule_text_matches() {
  local stars=${1//[^*]/}
  # shellcheck disable=SC2053 # the rule is a glob
  [[ $2 == $1 ]] || [[ ${#stars} -eq 1 && $1 == *' *' && $2 == "${1% \*}" ]]
}

# Whether one of the settings file <file>'s Bash deny rules matches <command> in one of its
# deny_forms, as rule_text_matches says: denied_in <file> <command>
denied_in() {
  local pattern form forms
  forms=$(deny_forms "$2")
  while IFS= read -r pattern; do
    while IFS= read -r form; do
      rule_text_matches "$pattern" "$form" && return 0
    done <<<"$forms"
  done < <(jq -r '.permissions.deny[] | select(startswith("Bash(")) | .[5:-1]' "$1")
  return 1
}

# Fail, naming each, when the settings file <file> takes away a tool or skill that one of the
# prompts or briefs <text>... names: a bare tool deny rule whose tool is a word of the text, or a
# skillOverrides entry that hides a skill the text names as `/<skill>`, as a path
# skills/<skill>/SKILL.md, or as the `<skill>` skill. keeps_named <file> <text>...
keeps_named() {
  local settings=$1 tool skill found=0
  shift
  while IFS= read -r tool; do
    if grep -qw -- "$tool" "$@"; then echo "denies $tool, which $(grep -lw -- "$tool" "$@" | head -n 1) names" >&2 && found=1; fi
  done < <(jq -r '.permissions.deny // [] | .[] | select(test("^[A-Za-z][A-Za-z0-9_]*$"))' "$settings")
  while IFS= read -r skill; do
    case $(jq -r --arg s "$skill" '.skillOverrides[$s] // "on"' "$settings") in
      off | user-invocable-only) echo "hides the skill $skill, which the prompt or a brief names" >&2 && found=1 ;;
    esac
  done < <(grep -ohE '`/[a-z][a-z0-9-]*`|skills/[a-z][a-z0-9-]*/SKILL\.md|the `[a-z][a-z0-9-]*` skill' "$@" |
    sed -E 's#^`/##; s#`$##; s#^skills/##; s#/SKILL\.md$##; s#^the `##; s#` skill$##' | sort -u)
  return "$found"
}

assert_equal() {
  if [[ $1 != "$2" ]]; then
    printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_contains() {
  if [[ $1 != *"$2"* ]]; then
    printf 'expected to contain: %s\nactual: %s\n' "$2" "$1" >&2
    return 1
  fi
}
