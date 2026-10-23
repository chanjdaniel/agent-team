# machine/tools.lock, resolved for one machine: include "tools"; tools_for($os; $machine).
# $os is arch or macos (team-doctor's os line), $machine what `uname -m` prints.
# Each result is {name, version_cmd, version_pattern, pin, min, pin_mismatch, source}, source being
# the exact install command for this machine; a tool whose lock entry does not name $os is left out.
#
# A tool the lock installs from GitHub has no pin or source of its own: `from` picks "release" or
# "fork", and the pin and the command come from that object.
#   release  {repo, tag, sha256: {<os>-<arch>: hash}}: the archive <name>-<tag>-<os>-<arch>.tar.gz
#            of the GitHub release, its binary <name> at the archive's root, checked against the
#            recorded SHA-256 before it is unpacked.
#   fork     {repo, commit, version}: a build of that commit (make build, then bin/<name>); version
#            is what the build reports, `git describe` of the commit.
#   dir      {<os>: directory}: where the binary goes on each OS, which also says which OSes check it.

# The release's platform name for this machine: linux or darwin, then amd64 or arm64.
def platform($os; $machine):
  (if $os == "macos" then "darwin" else "linux" end) + "-"
  + ({"x86_64": "amd64", "amd64": "amd64", "arm64": "arm64", "aarch64": "arm64"}[$machine] // $machine);

# A directory under ~ is the user's own; any other needs sudo to write.
def sudo_for($dir): if $dir | startswith("~") then "" else "sudo " end;

def release_source($os; $machine):
  .name as $name | .release as $r | .dir[$os] as $dir | platform($os; $machine) as $p
  | "\($name)-\($r.tag)-\($p).tar.gz" as $archive
  | if $r.sha256[$p] == null then
      "machine/tools.lock records no \($p) archive of \($name) \($r.tag); see https://github.com/\($r.repo)/releases/tag/\($r.tag)"
    else
      (if $os == "macos" then "shasum -a 256 -c" else "sha256sum -c -" end) as $check
      | "f=$(mktemp) && curl -fsSLo \"$f\" https://github.com/\($r.repo)/releases/download/\($r.tag)/\($archive)"
        + " && echo \"\($r.sha256[$p])  $f\" | \($check)"
        + " && \(sudo_for($dir))mkdir -p \($dir) && \(sudo_for($dir))tar -xzf \"$f\" -C \($dir) \($name) && rm -f \"$f\""
    end;

def fork_source($os):
  .name as $name | .fork as $f | .dir[$os] as $dir
  | "d=$(mktemp -d) && git clone -q https://github.com/\($f.repo) \"$d\" && git -C \"$d\" checkout -q \($f.commit)"
    + " && make -C \"$d\" build && \(sudo_for($dir))mkdir -p \($dir)"
    + " && \(sudo_for($dir))install -m 755 \"$d/bin/\($name)\" \($dir)/\($name) && rm -rf \"$d\"";

def tools_for($os; $machine):
  .tools[]
  | if has("from") then
      select(.dir[$os])
      | . + (if .from == "fork" then {pin: .fork.version, source: fork_source($os)}
             else {pin: (.release.tag | ltrimstr("v")), source: release_source($os; $machine)} end)
    else
      select(.source[$os]) | .source = .source[$os]
    end
  | {name, version_cmd, version_pattern, pin: (.pin // ""), min: (.min // ""),
     pin_mismatch: (.pin_mismatch // "FAIL"), source};
