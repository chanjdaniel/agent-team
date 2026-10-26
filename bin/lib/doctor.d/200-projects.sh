# per project   For each project of projects.toml (`projects` fails when team-project refuses
#               the registry), the lines below with the project's name after the check's;
#               a missing checkout is its one line:
#   checkout    The primary checkout at its registry path: a git checkout of its own, not a
#               worktree of another; missing, the fix is the clone.
#   origin      Exactly https://github.com/<repo>.git, the URL the bootstrap clones from.
#   task dir    git ignores the task directory, as team-open requires.
#   gate        no-mistakes projects only: `no-mistakes status` in the checkout shows a gate.
#   slots       treehouse pools only: every slot is in the pool treehouse names from origin,
#               <checkout's folder name>-<the first 3 bytes of the SHA-256 of origin's URL,
#               in hex>, so the registry's slots hold on any machine with that origin.
#   trust       `claude --bg --name team-doctor-trust-<project>` with no prompt in the checkout
#               fails on "Workspace not trusted"; the probe session (by the id it printed, and
#               any session of that name) is stopped and removed either way, and one left
#               behind turns a pass into a warning.
#   branches    Warns on each local branch with commits on no origin branch (no upstream and
#               never pushed, or ahead of what was pushed; a checkpoint's wip/<project>/T<n>
#               on the team home's origin is no branch), with their count.
#   changes     Warns while the primary checkout has changes to tracked files or untracked files.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

# team-project refuses a missing or broken registry itself, the first problem first.
# The pool treehouse names for the checkout <path> with origin <url>: <path's folder name>-<the
# first 3 bytes of the SHA-256 of the URL, in hex> (treehouse's ResolvePoolDir).
pool_name() {
  printf '%s-%s\n' "${1##*/}" "$(printf '%s' "$2" | sha256sum | cut -c1-6)"
}

# The lines of the registered project <name> (see the header).
check_project() {
  local project=$1 facts path shown repo url top common origin task_dir exclude out rc pool slot
  local wrong=() unpushed=() found=() branch count
  facts=$(team_project "$project")
  path=$(jq -r .path <<<"$facts") repo=$(jq -r .repo <<<"$facts") task_dir=$(jq -r .task_dir <<<"$facts")
  shown=$(tilde "$path") url=https://github.com/$repo.git

  # checkout
  if [[ ! -e $path ]]; then
    report "checkout $project" FAIL "$shown is missing" "git clone $url $shown"
    return
  fi
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || top=''
  if [[ -z $top || $(realpath -m -- "$top") != "$(realpath -m -- "$path")" ]]; then
    report "checkout $project" FAIL "$shown is not a git checkout" "move it aside, then git clone $url $shown"
    return
  fi
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)
  if [[ $(realpath -m -- "$common") != "$(realpath -m -- "$(git -C "$path" rev-parse --absolute-git-dir)")" ]]; then
    report "checkout $project" FAIL "$shown is a worktree of $(tilde "$(dirname "$(realpath -m -- "$common")")"), not a primary checkout" \
      "move it aside, then git clone $url $shown"
    return
  fi
  report "checkout $project" PASS "$shown, a primary checkout"

  # origin
  origin=$(git -C "$path" remote get-url origin 2>/dev/null) || origin=''
  if [[ $origin == "$url" ]]; then
    report "origin $project" PASS "$url"
  elif [[ -z $origin ]]; then
    report "origin $project" FAIL "no remote origin" "git -C $shown remote add origin $url"
  else
    report "origin $project" FAIL "origin is $origin, not $url" "git -C $shown remote set-url origin $url"
  fi

  # task dir: with its trailing slash, so a pattern for folders only matches one not made yet.
  if git -C "$path" check-ignore -q -- "$task_dir/"; then
    report "task dir $project" PASS "git ignores $task_dir/"
  else
    exclude=$(git -C "$path" rev-parse --path-format=absolute --git-path info/exclude)
    report "task dir $project" FAIL "git does not ignore $task_dir/" "echo /$task_dir/ >> $(tilde "$exclude")"
  fi

  # gate
  if [[ $(jq -r .delivery <<<"$facts") == no-mistakes ]]; then
    rc=0
    out=$(cd "$path" && bounded 30 no-mistakes status 2>&1 </dev/null) || rc=$?
    if ((rc == 127)); then
      report "gate $project" FAIL "no-mistakes is not installed" "the tool no-mistakes line's fix, then cd $shown && no-mistakes init"
    elif grep -qE '^[[:space:]]*gate:[[:space:]]' <<<"$out"; then
      report "gate $project" PASS "no-mistakes has a gate for it"
    elif [[ $out == *"not initialized"* ]]; then
      report "gate $project" FAIL "no-mistakes has no gate for $shown" "cd $shown && no-mistakes init"
    else
      report "gate $project" FAIL "\`no-mistakes status\` printed no gate: $(grep -m1 . <<<"$out" || echo "exit $rc")" \
        "cd $shown && no-mistakes init"
    fi
  fi

  # slots: a treehouse slot is <root>/<pool>/<n>/<folder>.
  if [[ $(jq -r .pool.provider <<<"$facts") == treehouse ]]; then
    if [[ -z $origin ]]; then
      report "slots $project" FAIL "unknown, since treehouse names the pool from origin, which is missing" "the origin line's fix"
    else
      pool=$(pool_name "$path" "$origin")
      while IFS= read -r slot; do
        [[ $(basename "$(dirname "$(dirname "$slot")")") == "$pool" ]] || wrong+=("$(tilde "$slot")")
      done < <(jq -r '.pool.slots[]' <<<"$facts")
      if ((${#wrong[@]} == 0)); then
        report "slots $project" PASS "every slot is in the pool $pool, as treehouse names it from origin"
      elif [[ $origin != "$url" ]]; then
        report "slots $project" FAIL "not in the pool $pool, as treehouse names it from origin $origin: $(printf '%s, ' "${wrong[@]}" | sed 's/, $//')" \
          "the origin line's fix"
      else
        report "slots $project" FAIL "not in the pool $pool, as treehouse names it from origin: $(printf '%s, ' "${wrong[@]}" | sed 's/, $//')" \
          "put $project's pool.slots in projects.toml under the pool's directory, ~/.treehouse/$pool/ unless its treehouse.toml sets another root"
      fi
    fi
  fi

  probe_trust "$project" "$path"

  # branches: commits no remote-tracking branch of origin has, as of the last fetch. A checkpoint's
  # wip/<project>/T<n> is none, since the next checkpoint replaces it and team-close deletes it:
  # team-open --resume fetches it into refs/remotes/team-home/, and origin/wip/* is left out for a
  # project whose origin is the team home's (or a snapshot from before they moved there).
  while IFS= read -r branch; do
    count=$(git -C "$path" rev-list --count "refs/heads/$branch" --not --exclude='origin/wip/*' --remotes=origin)
    ((count == 0)) || unpushed+=("$branch ($count commit$( ((count == 1)) || echo s))")
  done < <(git -C "$path" for-each-ref --format='%(refname:lstrip=2)' refs/heads)
  if ((${#unpushed[@]} == 0)); then
    report "branches $project" PASS "every local branch is on origin"
  else
    report "branches $project" WARN "$(printf '%s, ' "${unpushed[@]}" | sed 's/, $//') on no origin branch" \
      "push each (git -C $shown push -u origin <branch>) or delete it"
  fi

  # changes
  mapfile -t found < <(worktree_changes "$path")
  if ((${#found[@]} == 0)); then
    report "changes $project" PASS "the primary checkout is clean"
  else
    report "changes $project" WARN "$(printf '%s; ' "${found[@]}" | sed 's/; $//')" "commit, stash or remove them in $shown"
  fi
}

if projects=$(team_project --list 2>"$err"); then
  while IFS= read -r project; do check_project "$project"; done <<<"$projects"
else
  report projects FAIL "$(first_error)" "fix what team-project names (team-project --check), then run team-doctor again"
fi
