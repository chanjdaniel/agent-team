# The working set of each cgroup v2 group, the one measure of memory use team-capacity,
# team-heavy and team-level read a cgroup by: its memory.current less the reclaimable page cache
# (memory.stat's file less its shmem, which cannot be dropped), never below 0, so a finished
# session's cached reads never count as its use.
# Input: one "<key>\t<cgroup path>" per line, the path as systemd's ControlGroup gives it (from
# the cgroup root, /user.slice/...). Output: "<key>\t<bytes>" for each whose memory.current and
# memory.stat could be read, in the input's order; one that cannot be read (an empty path, a
# group gone) prints nothing.
#   awk -F '\t' -v root="${TEAM_CGROUP_ROOT:-}" -f bin/lib/working-set.awk
# root stands for / (the tests' TEAM_CGROUP_ROOT), so the groups are read under
# <root>/sys/fs/cgroup.
$2 ~ /^\// {
  dir = root "/sys/fs/cgroup" $2
  current = ""
  file = ""
  shmem = 0
  if ((getline line < (dir "/memory.current")) > 0) current = line
  close(dir "/memory.current")
  while ((getline line < (dir "/memory.stat")) > 0) {
    split(line, f, " ")
    if (f[1] == "file") file = f[2]
    else if (f[1] == "shmem") shmem = f[2]
  }
  close(dir "/memory.stat")
  if (current !~ /^[0-9]+$/ || file !~ /^[0-9]+$/) next
  cache = file - shmem
  if (cache < 0) cache = 0
  used = current - cache
  if (used < 0) used = 0
  printf "%s\t%.0f\n", $1, used
}
