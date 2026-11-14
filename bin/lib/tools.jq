# bin/lib/tools.lock, resolved for one machine: include "tools"; tools_for($os; $machine).
# $os is arch or macos (team-doctor's os line), $machine what `uname -m` prints.
# Each result is {name, version_cmd, version_pattern, pin, min, pin_mismatch, show_path, source},
# source being the exact install command for this machine; a tool whose lock entry does not name
# $os is left out. tool_dirs($os; $home; $nvm; $brew; $root) gives the directories the tools are
# installed into on $os, for the library's PATH; download_sources($os; $machine) gives each
# download tool's install command alone, for CI.
#
# A tool the lock installs from GitHub or a publisher's archive has no pin or source of its own:
# `from` picks "release", "fork" or "download", and the pin and the command come from that object.
#   release  {repo, tag, sha256: {<os>-<arch>: hash}}: the archive <name>-<tag>-<os>-<arch>.tar.gz
#            of the GitHub release, its binary <name> at the archive's root, checked against the
#            recorded SHA-256 before it is unpacked.
#   fork     {repo, commit, version}: a build of that commit (make build, then bin/<name>); version
#            is what the build reports, `git describe` of the commit.
#   download {version, index, archives: {<os>-<arch>: {url, sha256}}}: a publisher's archive outside
#            GitHub (MongoDB's Database Tools), a .tgz or a .zip whose <root>/bin/<name> is the
#            binary, <root> being the archive's file name without its extension; it is downloaded
#            to a mktemp file, checked against the recorded SHA-256, unpacked into a mktemp -d
#            directory, only that binary installed with mode 755, and both removed. index is the
#            publisher's release index, which a platform with no recorded archive is pointed at.
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
      "bin/lib/tools.lock records no \($p) archive of \($name) \($r.tag); see https://github.com/\($r.repo)/releases/tag/\($r.tag)"
    else
      (if $os == "macos" then "shasum -a 256 -c" else "sha256sum -c -" end) as $check
      | "f=$(mktemp) && curl -fsSLo \"$f\" https://github.com/\($r.repo)/releases/download/\($r.tag)/\($archive)"
        + " && echo \"\($r.sha256[$p])  $f\" | \($check)"
        + " && \(sudo_for($dir))mkdir -p \($dir) && \(sudo_for($dir))tar -xzf \"$f\" -C \($dir) \($name) && rm -f \"$f\""
    end;

def download_source($os; $machine):
  .name as $name | .download as $d | .dir[$os] as $dir | platform($os; $machine) as $p
  | $d.archives[$p] as $a
  | if $a == null then
      "bin/lib/tools.lock records no \($p) archive of \($name) \($d.version); see \($d.index)"
    else
      ($a.url | split("/") | last) as $file
      | ($file | sub("\\.(tgz|zip)$"; "")) as $root
      | (if $os == "macos" then "shasum -a 256 -c" else "sha256sum -c -" end) as $check
      | (if $file | endswith(".zip") then "unzip -q \"$f\" \($root)/bin/\($name) -d \"$d\""
         else "tar -xzf \"$f\" -C \"$d\" \($root)/bin/\($name)" end) as $unpack
      | "f=$(mktemp) && d=$(mktemp -d) && curl -fsSLo \"$f\" \($a.url)"
        + " && echo \"\($a.sha256)  $f\" | \($check) && \($unpack)"
        + " && \(sudo_for($dir))mkdir -p \($dir) && \(sudo_for($dir))install -m 755 \"$d/\($root)/bin/\($name)\" \($dir)/\($name)"
        + " && rm -rf \"$f\" \"$d\""
    end;

# The install command of each download tool on $os and $machine, in the lock's order: what CI's
# toolkits job runs, so a new download entry needs no change there.
def download_sources($os; $machine):
  .tools[] | select(.from == "download" and .dir[$os]) | download_source($os; $machine);

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
             elif .from == "download" then {pin: .download.version, source: download_source($os; $machine)}
             else {pin: (.release.tag | ltrimstr("v")), source: release_source($os; $machine)} end)
    else
      select(.source[$os]) | .source = .source[$os]
    end
  | {name, version_cmd, version_pattern, pin: (.pin // ""), min: (.min // ""),
     pin_mismatch: (.pin_mismatch // "FAIL"), show_path: (.show_path // false), source};

# The directories the tools are installed into on $os, in the lock's order, each once: a GitHub
# build's dir, any other tool's path. ~ is $home, @NVM_DIR@ $nvm and @HOMEBREW_PREFIX@ $brew; a
# directory under a prefix that is "" (no Homebrew) is left out; an absolute one (a system
# directory) goes under $root, "" but in the test sandbox.
def tool_dirs($os; $home; $nvm; $brew; $root):
  [.tools[] | (if has("from") then .dir else .path end) // {} | .[$os] // empty
   | select(contains("@HOMEBREW_PREFIX@") and $brew == "" | not)
   | if startswith("/") then $root + . else . end
   | sub("^~"; $home) | sub("@NVM_DIR@"; $nvm) | sub("@HOMEBREW_PREFIX@"; $brew)]
  | reduce .[] as $dir ([]; if index([$dir]) then . else . + [$dir] end) | .[];
