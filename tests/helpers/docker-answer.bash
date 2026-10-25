# The stub docker's answers, sourced by tests/helpers/stub for every docker call once
# docker_stub (tests/helpers/docker.bash, which documents the calls) has installed it: each call
# is answered from the machine's state in $DOCKER_STATE as Docker would answer it.
# shellcheck shell=bash

# The message Docker gives when its daemon does not answer.
DOCKER_DOWN='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'

# The jq definitions the answers share: whether a labels object has every one of the label
# filters <filters> ("<key>" or "<key>=<value>"), as Docker's --filter label= matches.
DOCKER_STUB_JQ='def has_labels($filters): . as $labels | all($filters[];
  (split("=") | .[0]) as $k | ($labels | has($k))
  and (if contains("=") then $labels[$k] == .[($k | length) + 1:] else true end)); '

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
  # The project and file of a compose call (-p, -f).
  COMPOSE_P='' COMPOSE_F=''
  case $cmd in
    compose)
      # Compose's global options, before its subcommand.
      while [[ ${args[0]:-} == -* ]]; do
        case ${args[0]} in
          -p | --project-name) COMPOSE_P=${args[1]:-}; args=("${args[@]:2}") ;;
          -f | --file) COMPOSE_F=${args[1]:-}; args=("${args[@]:2}") ;;
          --profile | --env-file | --project-directory | --ansi | --progress | --parallel)
            args=("${args[@]:2}") ;;
          *) args=("${args[@]:1}") ;;
        esac
      done
      key="compose ${args[0]:-}"
      args=("${args[@]:1}")
      docker_stub_compose_env
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
    'compose config') docker_stub_compose_config "${args[@]}" ;;
    'compose up') docker_stub_compose_up "${args[@]}" ;;
    'compose port') docker_stub_compose_port "${args[@]}" ;;
    'compose logs') docker_stub_compose_logs "${args[@]}" ;;
    'compose stop') docker_stub_compose_stop "${args[@]}" ;;
    'compose down') docker_stub_compose_down "${args[@]}" ;;
    'volume rm') docker_stub_volume_rm "${args[@]}" ;;
    'image rm') docker_stub_image_rm "${args[@]}" ;;
    'network rm') docker_stub_network_rm "${args[@]}" ;;
    info) docker_stub_info "${args[@]}" ;;
    events) docker_stub_events "${args[@]}" ;;
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
  jq -r --argjson all "$all" --argjson filters "$filters" "$DOCKER_STUB_JQ"'
    map(select(($all or .State.Running) and (.Config.Labels // {} | has_labels($filters))))
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
# links counted from the containers that mount it. system df --format json: one line per type,
# Docker's totals, its sizes as Docker writes them ("1.31GB"), active meaning used by a container
# (an image, a volume) or running (a container), reclaimable the size of what is not active.
docker_stub_system_df() {
  if docker_stub_options $# "$@" --format json; then
    jq -c --slurpfile containers "$DOCKER_STATE/containers.json" --slurpfile volumes "$DOCKER_STATE/volumes.json" '
      def bytes: capture("^(?<n>[0-9.]+)(?<u>[kMGT]?B)$") // {n: "0", u: "B"}
        | (.n | tonumber) * {B: 1, kB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12}[.u];
      def human: if . >= 1e9 then "\(. / 1e6 | round / 1e3)GB" elif . >= 1e6 then "\(. / 1e3 | round / 1e3)MB"
        elif . >= 1e3 then "\(round / 1e3)kB" else "\(round)B" end;
      def totals($type; $items):
        ($items | map(.size) | add // 0) as $size | ($items | map(select(.active | not) | .size) | add // 0) as $free
        | {Active: ($items | map(select(.active)) | length | tostring),
           Reclaimable: "\($free | human) (\(if $size == 0 then 0 else $free * 100 / $size | floor end)%)",
           Size: ($size | human), TotalCount: ($items | length | tostring), Type: $type};
      $containers[0] as $cs
      | totals("Images"; map(.ID as $id | {size: (.Size | bytes), active: any($cs[]; .Image == $id)})),
        totals("Containers"; $cs | map({size: 0, active: .State.Running})),
        totals("Local Volumes"; $volumes[0] | map(.Name as $n | {size: (.Size // "0B" | bytes),
          active: any($cs[]; any(.Mounts[]?; .Type == "volume" and .Name == $n))})),
        totals("Build Cache"; [])' "$DOCKER_STATE/images.json"
    return
  fi
  docker_stub_options $# "$@" -v --format json || docker_stub_unplanned
  jq -c --slurpfile containers "$DOCKER_STATE/containers.json" --slurpfile volumes "$DOCKER_STATE/volumes.json" '
    {BuildCache: [], Containers: [], Images: .,
     Volumes: [$volumes[0][] | .Name as $name | {
       Availability: "N/A", Driver, Group: "N/A",
       Labels: (.Labels // {} | to_entries | map("\(.key)=\(.value)") | join(",")),
       Links: ([$containers[0][] | select(any(.Mounts[]; .Type == "volume" and .Name == $name))] | length | tostring),
       Mountpoint, Name, Scope, Size, Status: "N/A"}]}' "$DOCKER_STATE/images.json"
}

# volume ls --quiet, network ls --quiet --no-trunc, each with any --filter label=<key>[=<value>]:
# one <field> per object of <file>: docker_stub_list <file> <field> <options...>
docker_stub_list() {
  local file=$1 field=$2 filters='[]'
  shift 2
  local -a options=()
  while (($#)); do
    if [[ $1 == --filter ]]; then
      [[ ${2:-} == label=* ]] || docker_stub_unplanned
      filters=$(jq -c --arg f "${2#label=}" '. + [$f]' <<<"$filters")
      shift 2
      continue
    fi
    options+=("$1")
    shift
  done
  case $file in
    volumes) docker_stub_options ${#options[@]} "${options[@]}" --quiet || docker_stub_unplanned ;;
    networks) docker_stub_options ${#options[@]} "${options[@]}" --quiet --no-trunc || docker_stub_unplanned ;;
  esac
  jq -r --argjson filters "$filters" "$DOCKER_STUB_JQ map(select(.Labels // {} | has_labels(\$filters))) | .[] | $field" \
    "$DOCKER_STATE/$file.json"
}

# info --format json: the daemon's information, $DOCKER_STATE/info.json.
docker_stub_info() {
  docker_stub_options $# "$@" --format json || docker_stub_unplanned
  jq -c . "$DOCKER_STATE/info.json"
}

# events --since <epoch> --until <epoch> --filter event=<action> --format json: the events of
# $DOCKER_STATE/events.json (docker_event) with that action in that time, one line each, oldest
# first, as Docker gives them.
docker_stub_events() {
  local since='' until='' action=''
  while (($#)); do
    case $1 in
      --since) since=$2; shift ;;
      --until) until=$2; shift ;;
      --filter) [[ $2 == event=* ]] || docker_stub_unplanned; action=${2#event=}; shift ;;
      --format) [[ $2 == json ]] || docker_stub_unplanned; shift ;;
      *) docker_stub_unplanned ;;
    esac
    shift
  done
  # Docker reads a time or a duration; the stub, as the tests plan, only seconds since the epoch.
  [[ $since =~ ^[0-9]+$ && $until =~ ^[0-9]+$ && -n $action ]] || docker_stub_unplanned
  jq -c --argjson since "$since" --argjson until "$until" --arg action "$action" \
    'sort_by(.time)[] | select(.Action == $action and .time >= $since and .time <= $until)' "$DOCKER_STATE/events.json"
}

# The calls below model the fixture project's stack (tests/fixtures/stack/docker-compose.yml):
# one service, web, mounting the named volume data at /data and an anonymous one at /cache, on
# the network default, each labelled from the TEAM_* variables the call sees, as Compose 5.6.1
# makes them.

# The project of a compose call: -p, else COMPOSE_PROJECT_NAME, else the directory of the -f file.
docker_stub_project() {
  if [[ -n $COMPOSE_P ]]; then
    echo "$COMPOSE_P"
  elif [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    echo "$COMPOSE_PROJECT_NAME"
  else
    local dir=${COMPOSE_F%/*}
    echo "${dir##*/}"
  fi
}

# Log the compose call with the stack identity and the team labels it sees, one JSON object per
# line in $DOCKER_STATE/compose-env.jsonl (docker_compose_env).
docker_stub_compose_env() {
  jq -cn --arg call "$DOCKER_STUB_CALL" --arg project "$(docker_stub_project)" '
    {call: $call, project: $project, COMPOSE_PROJECT_NAME: ($ENV.COMPOSE_PROJECT_NAME // null),
     TH_PORTS: ($ENV.TH_PORTS // null), TH_WEB_PORT: ($ENV.TH_WEB_PORT // null),
     labels: {owner: $ENV.TEAM_OWNER, task: $ENV.TEAM_TASK, kind: $ENV.TEAM_KIND,
       worktree: $ENV.TEAM_WORKTREE, expires: $ENV.TEAM_EXPIRES}}' >>"$DOCKER_STATE/compose-env.jsonl"
}

# The team labels the call's TEAM_* variables give, each empty when unset, as a labels object.
docker_stub_team_labels() {
  jq -cn '{owner: "TEAM_OWNER", task: "TEAM_TASK", kind: "TEAM_KIND", worktree: "TEAM_WORKTREE", expires: "TEAM_EXPIRES"}
    | with_entries(.key |= "io.github.chanjdaniel.team." + . | .value |= ($ENV[.] // ""))'
}

# Replace the state file <file> with jq's <filter> of it: docker_stub_update <file> <filter> [jq options...]
docker_stub_update() {
  local file=$DOCKER_STATE/$1.json filter=$2
  shift 2
  jq "$@" "$DOCKER_STUB_JQ $filter" "$file" >"$file.new"
  mv "$file.new" "$file"
}

# A new 64-hex id.
docker_stub_id() {
  sha256sum <<<"$RANDOM-$RANDOM-$(date +%s%N)-$BASHPID" | cut -d ' ' -f 1
}

# compose config --format json: the fixture's config as Compose renders it.
docker_stub_compose_config() {
  docker_stub_options $# "$@" --format json || docker_stub_unplanned
  jq -n --arg project "$(docker_stub_project)" --arg port "${TH_WEB_PORT:-}" --argjson labels "$(docker_stub_team_labels)" '
    {name: $project,
     networks: {default: {name: "\($project)_default", ipam: {}, labels: $labels}},
     services: {web: {restart: "no", command: ["httpd", "-f", "-v", "-p", "80", "-h", "/data"], entrypoint: null,
       image: "busybox:1.36", labels: $labels, mem_limit: "67108864", networks: {default: null},
       volumes: [{type: "volume", source: "data", target: "/data", volume: {}}, {type: "volume", target: "/cache", volume: {}}],
       ports: [{mode: "ingress", host_ip: "127.0.0.1", target: 80, published: $port, protocol: "tcp"}]}},
     volumes: {data: {name: "\($project)_data", labels: $labels}},
     "x-team-labels": $labels}'
}

# compose up -d --wait: the project's network and named volume made when missing (an existing
# one keeps its labels, as Docker's do); its web container made, started when stopped, or
# recreated with its anonymous volume when its labels changed; started with its port, TH_WEB_PORT
# or, empty, one Docker picks.
docker_stub_compose_up() {
  docker_stub_options $# "$@" -d --wait || docker_stub_unplanned
  local project labels now hash port id anonymous
  project=$(docker_stub_project)
  labels=$(docker_stub_team_labels)
  now=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  hash=$(sha256sum <<<"$labels" | cut -d ' ' -f 1)
  docker_stub_update networks '
    if any(.[]; .Name == "\($p)_default") then . else . + [{Name: "\($p)_default", Id: $id, Created: $now,
      Scope: "local", Driver: "bridge", Labels: ({"com.docker.compose.network": "default",
      "com.docker.compose.project": $p, "com.docker.compose.version": "5.6.1"} + $labels)}] end' \
    --arg p "$project" --arg id "$(docker_stub_id)" --arg now "$now" --argjson labels "$labels"
  docker_stub_update volumes '
    if any(.[]; .Name == "\($p)_data") then . else . + [{Name: "\($p)_data", CreatedAt: $now, Driver: "local",
      Mountpoint: "/var/lib/docker/volumes/\($p)_data/_data", Scope: "local", Size: "0B",
      Labels: ({"com.docker.compose.project": $p, "com.docker.compose.version": "5.6.1",
      "com.docker.compose.volume": "data"} + $labels)}] end' \
    --arg p "$project" --arg now "$now" --argjson labels "$labels"
  # The anonymous volume: the existing container's, else a new one.
  anonymous=$(jq -r --arg name "/$project-web-1" \
    '.[] | select(.Name == $name) | .Mounts[] | select(.Destination == "/cache") | .Name' "$DOCKER_STATE/containers.json")
  if [[ -z $anonymous ]]; then
    anonymous=$(docker_stub_id)
    docker_stub_update volumes '. + [{Name: $name, CreatedAt: $now, Driver: "local", Scope: "local", Size: "0B",
      Mountpoint: "/var/lib/docker/volumes/\($name)/_data", Labels: {"com.docker.volume.anonymous": ""}}]' \
      --arg name "$anonymous" --arg now "$now"
  fi
  port=${TH_WEB_PORT:-}
  [[ -n $port ]] || port=$((32768 + $(jq length "$DOCKER_STATE/containers.json")))
  id=$(docker_stub_id)
  docker_stub_update containers '
    (map(select(.Name == "/\($p)-web-1")) | first) as $old
    | if $old != null and $old.Config.Labels["com.docker.compose.config-hash"] == $hash then
        map(if .Name == "/\($p)-web-1" and (.State.Running | not) then
          .State += {Status: "running", Running: true, StartedAt: $now} else . end)
      else map(select(.Name != "/\($p)-web-1")) + [{Name: "/\($p)-web-1", Id: $id, Created: $now,
        State: {Status: "running", Running: true, OOMKilled: false, ExitCode: 0, StartedAt: $now,
          FinishedAt: "0001-01-01T00:00:00Z"},
        Image: "sha256:\("b" * 64)",
        Config: {Labels: ({"com.docker.compose.config-hash": $hash, "com.docker.compose.container-number": "1",
          "com.docker.compose.oneoff": "False", "com.docker.compose.project": $p,
          "com.docker.compose.project.config_files": $file, "com.docker.compose.project.working_dir": ($file | sub("/[^/]*$"; "")),
          "com.docker.compose.service": "web", "com.docker.compose.version": "5.6.1"} + $labels)},
        Mounts: [{Type: "volume", Name: "\($p)_data", Source: "/var/lib/docker/volumes/\($p)_data/_data",
            Destination: "/data", Driver: "local"},
          {Type: "volume", Name: $anonymous, Source: "/var/lib/docker/volumes/\($anonymous)/_data",
            Destination: "/cache", Driver: "local"}],
        NetworkSettings: {Ports: {"80/tcp": [{HostIp: "127.0.0.1", HostPort: $port}]}, Networks: {"\($p)_default": {}}}}] end' \
    --arg p "$project" --arg id "$id" --arg now "$now" --arg hash "$hash" --arg port "$port" \
    --arg file "$COMPOSE_F" --arg anonymous "$anonymous" --argjson labels "$labels"
  docker_stub_running_stats
}

# The stats of the running containers: each keeps its line, and a new one uses 1.2 MiB.
docker_stub_running_stats() {
  jq --slurpfile containers "$DOCKER_STATE/containers.json" '
    . as $stats | [$containers[0][] | select(.State.Running) | .Id as $id | (.Name | ltrimstr("/")) as $name
      | (first($stats[] | select(.ID as $short | $id | startswith($short)))
         // {BlockIO: "0B / 0B", CPUPerc: "0.00%", Container: $id[:12], ID: $id[:12], MemPerc: "1.88%",
             MemUsage: "1.2MiB / 64MiB", Name: $name, NetIO: "0B / 0B", PIDs: "1"})]' \
    "$DOCKER_STATE/stats.json" >"$DOCKER_STATE/stats.json.new"
  mv "$DOCKER_STATE/stats.json.new" "$DOCKER_STATE/stats.json"
}

# compose port <service> <port>: the running service's published address, as Compose prints it.
docker_stub_compose_port() {
  [[ $# -eq 2 ]] || docker_stub_unplanned
  local project published
  project=$(docker_stub_project)
  published=$(jq -r --arg p "$project" --arg s "$1" --arg port "$2/tcp" '
    .[] | select(.Config.Labels["com.docker.compose.project"] == $p and .Config.Labels["com.docker.compose.service"] == $s
      and .State.Running) | .NetworkSettings.Ports[$port][0] | "\(.HostIp):\(.HostPort)"' "$DOCKER_STATE/containers.json")
  if [[ -z $published ]]; then
    echo "service \"$1\" is not running" >&2
    exit 1
  fi
  echo "$published"
}

# compose -p <project> logs --no-color --timestamps <service>: $DOCKER_STATE/logs/<project>-<service>.log
# when a test wrote one, else one line; a service with no container is refused as Compose does.
docker_stub_compose_logs() {
  if [[ $# -ne 3 ]] || ! docker_stub_options 2 "$1" "$2" --no-color --timestamps; then docker_stub_unplanned; fi
  local project service=$3
  project=$(docker_stub_project)
  if ! jq -e --arg p "$project" --arg s "$service" \
    'any(.[]; .Config.Labels["com.docker.compose.project"] == $p and .Config.Labels["com.docker.compose.service"] == $s)' \
    "$DOCKER_STATE/containers.json" >/dev/null; then
    echo "no such service: $service" >&2
    exit 1
  fi
  if [[ -f $DOCKER_STATE/logs/$project-$service.log ]]; then
    cat "$DOCKER_STATE/logs/$project-$service.log"
  else
    echo "$service-1  | 2026-10-24T09:00:00.000000000Z $project's $service started"
  fi
}

# compose -p <project> stop: every container of the project stopped.
docker_stub_compose_stop() {
  (($# == 0)) || docker_stub_unplanned
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  docker_stub_update containers 'map(if .Config.Labels["com.docker.compose.project"] == $p and .State.Running
    then .State += {Status: "exited", Running: false, ExitCode: 137, FinishedAt: $now} else . end)' \
    --arg p "$(docker_stub_project)" --arg now "$now"
  docker_stub_running_stats
}

# compose -p <project> down -v --remove-orphans: the project's containers, its named volumes,
# the anonymous volumes its containers mount and its networks removed; docker_leak leaves some.
docker_stub_compose_down() {
  docker_stub_options $# "$@" -v --remove-orphans || docker_stub_unplanned
  local project leak_anonymous=false leak_network=false leak_container=false
  project=$(docker_stub_project)
  [[ ! -e $DOCKER_STATE/leak-anonymous ]] || leak_anonymous=true
  [[ ! -e $DOCKER_STATE/leak-network ]] || leak_network=true
  [[ ! -e $DOCKER_STATE/leak-container ]] || leak_container=true
  local anonymous
  anonymous=$(jq -c --arg p "$project" '[.[] | select(.Config.Labels["com.docker.compose.project"] == $p)
    | .Mounts[] | select(.Type == "volume" and (.Name | test("^[0-9a-f]{64}$"))) | .Name]' "$DOCKER_STATE/containers.json")
  [[ $leak_container == true ]] ||
    docker_stub_update containers 'map(select(.Config.Labels["com.docker.compose.project"] != $p))' --arg p "$project"
  docker_stub_update volumes 'map(select(.Labels["com.docker.compose.project"] != $p
      and ($leak or (.Name as $name | $anonymous | index($name) | not))))' \
    --arg p "$project" --argjson anonymous "$anonymous" --argjson leak "$leak_anonymous"
  [[ $leak_network == true ]] ||
    docker_stub_update networks 'map(select(.Labels["com.docker.compose.project"] != $p))' --arg p "$project"
  docker_stub_running_stats
}

# Whether docker_refuse made the removal of <name> fail; its message on stderr when so.
docker_stub_refused() {
  local message
  message=$(jq -r --arg n "$1" 'select(.name == $n) | .message' "$DOCKER_STATE/refuse.jsonl" 2>/dev/null | head -n 1)
  [[ -n $message ]] || return 1
  echo "$message" >&2
}

# volume rm <names>...: each removed; one missing or mounted by a container is refused as
# Docker refuses it, after the others are removed.
docker_stub_volume_rm() {
  (($#)) || docker_stub_unplanned
  local name status=0
  for name in "$@"; do
    if docker_stub_refused "$name"; then
      status=1
    elif ! jq -e --arg n "$name" 'any(.[]; .Name == $n)' "$DOCKER_STATE/volumes.json" >/dev/null; then
      echo "Error response from daemon: get $name: no such volume" >&2
      status=1
    elif jq -e --arg n "$name" 'any(.[]; any(.Mounts[]?; .Type == "volume" and .Name == $n))' \
      "$DOCKER_STATE/containers.json" >/dev/null; then
      echo "Error response from daemon: remove $name: volume is in use" >&2
      status=1
    else
      docker_stub_update volumes 'map(select(.Name != $n))' --arg n "$name"
      echo "$name"
    fi
  done
  exit "$status"
}

# image rm <repository:tag or id>...: a tag untagged, its image gone with its last tag; an id
# removes the image; one missing, or whose image a container (in any state) uses, is refused as
# Docker refuses it, after the others are removed.
docker_stub_image_rm() {
  (($#)) || docker_stub_unplanned
  local ref id status=0
  for ref in "$@"; do
    id=$(jq -r --arg r "$ref" 'first(.[] | select(.ID == $r or "\(.Repository):\(.Tag)" == $r) | .ID) // empty' \
      "$DOCKER_STATE/images.json")
    if docker_stub_refused "$ref"; then
      status=1
    elif [[ -z $id ]]; then
      echo "Error response from daemon: No such image: $ref" >&2
      status=1
    elif jq -e --arg id "$id" 'any(.[]; .Image == $id)' "$DOCKER_STATE/containers.json" >/dev/null; then
      echo "Error response from daemon: conflict: unable to remove repository reference \"$ref\" (must force) - container is using its referenced image ${id#sha256:}" >&2
      status=1
    else
      docker_stub_update images 'map(select(.ID != $r and "\(.Repository):\(.Tag)" != $r))' --arg r "$ref"
      echo "Untagged: $ref"
    fi
  done
  exit "$status"
}

# network rm <names or ids>...: each removed; one missing, or that a running container is on, is
# refused as Docker refuses it (a stopped container's network is removed, as Docker does), after
# the others are removed.
docker_stub_network_rm() {
  (($#)) || docker_stub_unplanned
  local ref name status=0
  for ref in "$@"; do
    name=$(jq -r --arg r "$ref" 'first(.[] | select(.Name == $r or (.Id | startswith($r))) | .Name) // empty' \
      "$DOCKER_STATE/networks.json")
    if docker_stub_refused "$ref"; then
      status=1
    elif [[ -z $name ]]; then
      echo "Error response from daemon: network $ref not found" >&2
      status=1
    elif jq -e --arg n "$name" 'any(.[]; .State.Running and (.NetworkSettings.Networks // {} | has($n)))' \
      "$DOCKER_STATE/containers.json" >/dev/null; then
      echo "Error response from daemon: error while removing network: network $name has active endpoints" >&2
      status=1
    else
      docker_stub_update networks 'map(select(.Name != $n))' --arg n "$name"
      echo "$ref"
    fi
  done
  exit "$status"
}

# df -Pk <path>: one file system holding <path>, whose free space is the first line of
# $DOCKER_STATE/disk-free (in 1024-byte blocks), each call taking the next line while there is
# one (machine_disk_free); sourced by the stub df that docker_stub installs.
docker_stub_df() {
  if [[ $# -ne 2 || $1 != -Pk ]]; then
    echo "stub df: no answer planned for this call: df $*" >&2
    exit 127
  fi
  local file=$DOCKER_STATE/disk-free free
  free=$(head -n 1 "$file")
  if (($(wc -l <"$file") > 1)); then sed -i 1d "$file"; fi
  echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
  echo "/dev/stub        999999999 100000000 $free 10% /"
}
