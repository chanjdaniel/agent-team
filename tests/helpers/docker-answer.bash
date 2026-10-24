# The stub docker's answers, sourced by tests/helpers/stub for every docker call once
# docker_stub (tests/helpers/docker.bash, which documents the calls) has installed it: each call
# is answered from the machine's state in $DOCKER_STATE as Docker would answer it.
# shellcheck shell=bash

# The message Docker gives when its daemon does not answer.
DOCKER_DOWN='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'

# Answer one docker call: docker_stub_answer <arguments...>
docker_stub_answer() {
  DOCKER_STUB_CALL=$*
  local -a args=("$@")
  # Docker's global options, before the command.
  while [[ ${args[0]:-} == -* ]]; do
    case ${args[0]} in
      -c | --context | -H | --host | --config | -l | --log-level) args=("${args[@]:2}") ;;
      *) args=("${args[@]:1}") ;;
    esac
  done
  local cmd=${args[0]:-} key
  args=("${args[@]:1}")
  case $cmd in
    compose)
      # Compose's global options, before its subcommand.
      while [[ ${args[0]:-} == -* ]]; do
        case ${args[0]} in
          -f | --file | -p | --project-name | --profile | --env-file | --project-directory | --ansi | --progress | --parallel)
            args=("${args[@]:2}") ;;
          *) args=("${args[@]:1}") ;;
        esac
      done
      key="compose ${args[0]:-}"
      args=("${args[@]:1}")
      ;;
    volume | image | network | system | container | builder | buildx)
      key="$cmd ${args[0]:-}"
      args=("${args[@]:1}")
      ;;
    *) key=$cmd ;;
  esac
  if [[ -e $DOCKER_STATE/down ]]; then
    echo "$DOCKER_DOWN" >&2
    exit 1
  fi
  if [[ -f $DOCKER_STATE/fail-${key// /-} ]]; then
    cat "$DOCKER_STATE/fail-${key// /-}" >&2
    exit 1
  fi
  case $key in
    'compose ls') docker_stub_compose_ls "${args[@]}" ;;
    ps) docker_stub_ps "${args[@]}" ;;
    inspect) docker_stub_inspect "${args[@]}" ;;
    stats) docker_stub_stats "${args[@]}" ;;
    'system df') docker_stub_system_df "${args[@]}" ;;
    'volume ls') docker_stub_list volumes .Name "${args[@]}" ;;
    'network ls') docker_stub_list networks .Id "${args[@]}" ;;
    *) docker_stub_unplanned ;;
  esac
}

# Fail as a stub does for a call no test planned.
docker_stub_unplanned() {
  echo "stub docker: no answer planned for this call: docker $DOCKER_STUB_CALL" >&2
  exit 127
}

# Whether the arguments <args...> are exactly the options <options...> in any order.
docker_stub_options() {
  local -a given=() wanted=()
  local n=$1
  shift
  given=("${@:1:n}")
  wanted=("${@:n+1}")
  [[ $(printf '%s\n' "${given[@]}" | sort) == "$(printf '%s\n' "${wanted[@]}" | sort)" ]]
}

# compose ls [--all] --format json: each project of the containers, by name, its status counting
# its containers by state as Compose does ("exited(2), running(1)"); without --all, only the
# running containers count.
docker_stub_compose_ls() {
  local all=false arg
  for arg in "$@"; do
    case $arg in
      --all | -a) all=true ;;
      --format | json) ;;
      *) docker_stub_unplanned ;;
    esac
  done
  jq -c --argjson all "$all" '
    map(select($all or .State.Running))
    | map(select(.Config.Labels["com.docker.compose.project"]))
    | group_by(.Config.Labels["com.docker.compose.project"])
    | map({
        Name: .[0].Config.Labels["com.docker.compose.project"],
        Status: (group_by(.State.Status) | map("\(.[0].State.Status)(\(length))") | join(", ")),
        ConfigFiles: (map(.Config.Labels["com.docker.compose.project.config_files"]) | unique | join(","))
      })' "$DOCKER_STATE/containers.json"
}

# ps [--all] --quiet --no-trunc [--filter label=<key>[=<value>]]...: the ids, newest first as
# Docker lists them; without --all, the running containers only; then the vanished ones.
docker_stub_ps() {
  local all=false quiet=false filters='[]'
  while (($#)); do
    case $1 in
      --all | -a) all=true ;;
      --quiet | -q) quiet=true ;;
      --no-trunc) ;;
      --filter)
        [[ ${2:-} == label=* ]] || docker_stub_unplanned
        filters=$(jq -c --arg f "${2#label=}" '. + [$f]' <<<"$filters")
        shift
        ;;
      *) docker_stub_unplanned ;;
    esac
    shift
  done
  [[ $quiet == true ]] || docker_stub_unplanned
  jq -r --argjson all "$all" --argjson filters "$filters" '
    map(select($all or .State.Running) | . as $c
      | select(all($filters[]; (split("=") | .[0]) as $k | ($c.Config.Labels | has($k))
          and (if contains("=") then $c.Config.Labels[$k] == (.[($k | length) + 1:]) else true end))))
    | sort_by(.Created) | reverse | .[].Id' "$DOCKER_STATE/containers.json"
  # Containers removed since they were listed (docker_vanish).
  cat "$DOCKER_STATE/vanished" 2>/dev/null || true
}

# inspect --type container|volume|network <names or ids>...: the objects found, a JSON array;
# a container is found by its name or a prefix of its id, a volume by its name, a network by
# its name or a prefix of its id.
docker_stub_inspect() {
  [[ ${1:-} == --type && $# -ge 3 ]] || docker_stub_unplanned
  local type=$2 file
  shift 2
  case $type in
    container) file=containers ;;
    volume) file=volumes ;;
    network) file=networks ;;
    *) docker_stub_unplanned ;;
  esac
  local found
  found=$(jq -c --arg type "$type" '
    . as $all | [$ARGS.positional[] as $arg
      | ($all | map(select(
          if $type == "volume" then .Name == $arg
          elif $type == "container" then .Name == "/" + $arg or (.Id | startswith($arg))
          else .Name == $arg or (.Id | startswith($arg)) end))) as $hits
      | if $hits == [] then {missing: $arg} else $hits[0] end]' \
    "$DOCKER_STATE/$file.json" --args "$@")
  jq '[.[] | select(has("missing") | not) | del(.Size)]' <<<"$found"
  if jq -e 'any(.[]; has("missing"))' <<<"$found" >/dev/null; then
    jq -r --arg type "$type" '.[] | select(has("missing")) | .missing
      | "Error response from daemon: " + if $type == "container" then "No such container: \(.)"
        elif $type == "volume" then "get \(.): no such volume" else "network \(.) not found" end' <<<"$found" >&2
    exit 1
  fi
}

# stats --no-stream --format json <names or ids>...: one line each, as Docker prints them.
docker_stub_stats() {
  [[ ${1:-} == --no-stream && ${2:-} == --format && ${3:-} == json && $# -ge 4 ]] || docker_stub_unplanned
  shift 3
  local arg line
  for arg in "$@"; do
    line=$(jq -c --arg arg "$arg" 'map(select(.Name == $arg or (.ID as $id | $arg | startswith($id)))) | .[0] // empty' \
      "$DOCKER_STATE/stats.json")
    if [[ -z $line ]]; then
      echo "Error response from daemon: No such container: $arg" >&2
      exit 1
    fi
    printf '%s\n' "$line"
  done
}

# system df -v --format json: one object, each volume with its labels as one string and its
# links counted from the containers that mount it.
docker_stub_system_df() {
  docker_stub_options $# "$@" -v --format json || docker_stub_unplanned
  jq -c --slurpfile containers "$DOCKER_STATE/containers.json" --slurpfile volumes "$DOCKER_STATE/volumes.json" '
    {BuildCache: [], Containers: [], Images: .,
     Volumes: [$volumes[0][] | .Name as $name | {
       Availability: "N/A", Driver, Group: "N/A",
       Labels: (.Labels // {} | to_entries | map("\(.key)=\(.value)") | join(",")),
       Links: ([$containers[0][] | select(any(.Mounts[]; .Type == "volume" and .Name == $name))] | length | tostring),
       Mountpoint, Name, Scope, Size, Status: "N/A"}]}' "$DOCKER_STATE/images.json"
}

# volume ls --quiet, network ls --quiet --no-trunc: one <field> per object of <file>:
# docker_stub_list <file> <field> <options...>
docker_stub_list() {
  local file=$1 field=$2
  shift 2
  case $file in
    volumes) docker_stub_options $# "$@" --quiet || docker_stub_unplanned ;;
    networks) docker_stub_options $# "$@" --quiet --no-trunc || docker_stub_unplanned ;;
  esac
  jq -r ".[] | $field" "$DOCKER_STATE/$file.json"
}
