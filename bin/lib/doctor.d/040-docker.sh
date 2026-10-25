# docker        `docker info` answers: the daemon runs and this user may reach it. Docker access
#               is Daniel's: on Arch the daemon enabled and the docker group (sudo, then a new
#               login), on macOS Docker Desktop opened once and its license accepted.
# shellcheck shell=bash

# Asked only of an installed docker, on an OS the tools were checked for.
if [[ -n $os && -z ${installed[docker]:-} ]]; then
  report docker FAIL "docker is not installed" "the tool docker line's fix"
elif [[ -n $os ]]; then
  rc=0
  out=$(bounded 30 docker info --format '{{.ServerVersion}}' 2>&1 </dev/null) || rc=$?
  if ((rc == 0)); then
    report docker PASS "the Docker daemon answers (server $(grep -m1 . <<<"$out" || true))"
  else
    reason=$(grep -m1 . <<<"$out" || echo "exit $rc")
    if [[ $os == macos ]]; then
      docker_fix="Daniel opens Docker Desktop once and accepts its license"
    elif [[ $out == *"permission denied"* ]]; then
      docker_fix="Daniel runs sudo usermod -aG docker \$USER, then logs out and in"
    else
      docker_fix="Daniel runs sudo systemctl enable --now docker.service"
    fi
    report docker FAIL "\`docker info\` cannot reach the daemon: $reason" "$docker_fix"
  fi
fi
