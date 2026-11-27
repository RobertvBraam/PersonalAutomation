#!/usr/bin/env bash
set -euo pipefail

# Runs GitHub Actions jobs for the repositories listed in configuration.nix.
# Each runner is an unprivileged user with a Docker daemon of its own, and
# takes one job at a time in a fresh container on that daemon.
#
#   slot      one runner: register it with GitHub for one job and run it
#   check     every hour: start the runners that failed and report that this
#             machine is alive
#   maintain  every night: let the running jobs finish, remove everything jobs
#             left behind and reboot into the newest system
#   report    after a unit failed: send its last lines to SigNoz
#
# The units in configuration.nix run this and provide the variables and the
# tools on PATH. Nothing from a repository runs outside a runner container, the
# long-lived token never enters one, and no mode stops a runner that is running
# a job.

export GH_TOKEN="${RUNNER_ACCESS_TOKEN:-}"
declare -A refusals

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Calls GitHub and sets `reply` to the answer, trying three times: one failed
# call would otherwise take a runner down until the next hourly check.
github() {
  local attempt
  for attempt in 1 2 3; do
    if reply="$(gh api "$@" 2>&1)"; then
      return 0
    fi
    sleep $((attempt * 5))
  done
  return 1
}

# Points the docker client at the daemon of a runner's user.
use_daemon_of() {
  local uid
  uid="$(id -u "$1")" || fail "the user $1 does not exist."
  socket="/run/user/$uid/docker.sock"
  export DOCKER_HOST="unix://$socket"
}

# Removes every container of the daemon the docker client points at.
remove_containers() {
  local containers
  mapfile -t containers < <(docker ps --all --quiet)
  [ "${#containers[@]}" -eq 0 ] || docker rm --force "${containers[@]}" >/dev/null
}

wait_for_daemon() {
  local deadline=$((SECONDS + 120))
  until docker info >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the Docker daemon of $RUNNER_USER did not answer within two minutes. Look at it with: systemctl --user --machine=$RUNNER_USER@.host status docker"
    sleep 2
  done
}

# Removes the registration a run that died left under this runner's name.
# After a finished job GitHub removes it by itself.
forget_registration() {
  github "repos/$REPOSITORY/actions/runners?name=$RUNNER_NAME" --jq ".runners[] | select(.name == \"$RUNNER_NAME\") | .id" || fail "could not list the runners of $REPOSITORY: $reply. Check that the runner token is valid and has Administration: Read and write on that repository."
  [ -n "$reply" ] || return 0
  github -X DELETE "repos/$REPOSITORY/actions/runners/$reply" || fail "could not remove the old registration of $RUNNER_NAME: $reply"
}

# Registers this runner for one job. The answer is the only credential the
# container gets: it lets this one runner take one job, and nothing else.
register() {
  local label names labels=()
  IFS=, read -ra names <<<"$RUNNER_LABELS"
  for label in "${names[@]}"; do
    labels+=(-f "labels[]=$label")
  done
  github -X POST "repos/$REPOSITORY/actions/runners/generate-jitconfig" -f "name=$RUNNER_NAME" -F runner_group_id=1 -f "work_folder=$1" "${labels[@]}" --jq '[.runner.id, .encoded_jit_config] | @tsv' || fail "GitHub did not register $RUNNER_NAME for $REPOSITORY: $reply. Check that the runner token is valid and has Administration: Read and write on that repository."
  read -r runner_id JITCONFIG <<<"$reply"
  export JITCONFIG
}

# The container ends with its job, and systemd then starts this again. What the
# job before left is removed first: its containers, since everything on this
# daemon is this runner's, and its workspace, which sits on a volume next to
# the caches that are meant to stay.
run_one_job() {
  local volume mounts=() work="/_work/$RUNNER_NAME"
  use_daemon_of "$RUNNER_USER"
  wait_for_daemon
  remove_containers
  forget_registration
  register "$work"
  echo "$runner_id $REPOSITORY $RUNNER_USER" >"$RUNTIME_DIRECTORY/$RUNNER_NAME"
  for volume in $RUNNER_VOLUMES; do
    mounts+=(--volume "$volume")
  done
  unset GH_TOKEN RUNNER_ACCESS_TOKEN
  # shellcheck disable=SC2016
  exec docker run --rm --name "$RUNNER_NAME" --network host --volume "$socket:/var/run/docker.sock" "${mounts[@]}" --env JITCONFIG --env RUNNER_ALLOW_RUNASROOT=1 --env "WORK=$work" --entrypoint /bin/sh "$RUNNER_IMAGE" -c 'rm -rf "$WORK" && exec /actions-runner/run.sh --jitconfig "$JITCONFIG"'
}

# Sends one span to SigNoz. table-tab's alert rules read these spans
# (infra/signoz-config/signoz-rules.tf): one fires on a failure, one when no
# span arrived for two hours.
send_span() {
  local now trace span
  now="$(date +%s%N)"
  trace="$(od --address-radix=n --read-bytes=16 --format=x1 /dev/urandom | tr -d ' \n')"
  span="$(od --address-radix=n --read-bytes=8 --format=x1 /dev/urandom | tr -d ' \n')"
  jq --null-input --arg unit "$1" --arg result "$2" --arg message "$3" --arg host "$HOSTNAME" --arg now "$now" --arg trace "$trace" --arg span "$span" '
    def text($key; $value): {key: $key, value: {stringValue: $value}};
    {resourceSpans: [{
      resource: {attributes: [text("service.name"; "github-runner-server")]},
      scopeSpans: [{
        scope: {name: "github-runner-server"},
        spans: [{
          traceId: $trace, spanId: $span, name: "runner_server.run", kind: 1, flags: 257,
          startTimeUnixNano: $now, endTimeUnixNano: $now,
          status: {code: (if $result == "failed" then 2 else 1 end)},
          attributes: [
            text("runner_server.unit"; $unit),
            text("runner_server.result"; $result),
            text("runner_server.host"; $host),
            text("runner_server.message"; $message)
          ]
        }]
      }]
    }]}' | curl --fail --silent --show-error --retry 3 --retry-delay 5 --max-time 20 --header 'Content-Type: application/json' --data @- "$OTLP_ENDPOINT/v1/traces" >/dev/null || fail "could not send the span of $1 to $OTLP_ENDPOINT."
}

report_failure() {
  send_span "$1" failed "$(journalctl --unit "$1.service" --lines 15 --output cat --no-pager 2>&1 | tail --bytes 2000)"
}

# A runner that failed stays down, so its failure is reported once and not
# every few seconds. This gives it another try every hour.
# TODO: so a failed runner is away for up to an hour. Starting it again at
# once, with a growing pause, would bring it back sooner at the price of a
# span per attempt.
hourly_check() {
  local unit total=0 running=0 restarted=0
  exec 9>"$RUNTIME_DIRECTORY/lock"
  if ! flock --nonblock 9; then
    send_span runner-server-check succeeded "The nightly maintenance is running."
    return
  fi
  for unit in $RUNNER_UNITS; do
    total=$((total + 1))
    if systemctl is-failed --quiet "$unit"; then
      systemctl reset-failed "$unit"
      systemctl start --no-block "$unit"
      restarted=$((restarted + 1))
    elif systemctl is-active --quiet "$unit"; then
      running=$((running + 1))
    fi
  done
  send_span runner-server-check succeeded "$running of $total runners up, $restarted started again after a failure."
}

# Stops one runner once GitHub confirms that it is idle: deleting a runner's
# registration is refused while a job is assigned to it. Returns 1 while the
# runner is busy or between two registrations.
# TODO: GitHub does not document that refusal as a guarantee. The look for a
# running job afterwards catches a job that had started, not one assigned in
# the same second; a runner that can be told to finish its job and stop would
# need neither.
take_down() {
  local name="${1%.service}" id repo user
  read -r id repo user <"$RUNTIME_DIRECTORY/$name" 2>/dev/null || return 1
  if ! reply="$(gh api -X DELETE "repos/$repo/actions/runners/$id" 2>&1)"; then
    if [ "${refusals[$name]:-}" != "$reply" ]; then
      echo "$name stays up, GitHub did not remove its registration: $reply"
      refusals[$name]="$reply"
    fi
    return 1
  fi
  use_daemon_of "$user"
  if docker top "$name" 2>/dev/null | grep --quiet Runner.Worker; then
    echo "$name stays up: GitHub removed its registration, but a job is running in it."
    return 1
  fi
  systemctl stop "$1"
}

# Takes every runner down without stopping a job, waiting at most the given
# number of minutes for the busy ones.
drain() {
  local deadline=$((SECONDS + $1 * 60)) unit busy
  while true; do
    busy=0
    for unit in $RUNNER_UNITS; do
      case "$(systemctl is-active "$unit" || true)" in
        active) take_down "$unit" || busy=$((busy + 1)) ;;
        activating) systemctl stop "$unit" ;;
      esac
    done
    [ "$busy" -gt 0 ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 20
  done
}

# Removes every container, image and volume from every runner's daemon.
wipe() {
  local user
  for user in $RUNNER_USERS; do
    use_daemon_of "$user"
    remove_containers
    docker system prune --all --volumes --force >/dev/null
    docker volume prune --all --force >/dev/null
  done
}

nightly_maintenance() {
  exec 9>"$RUNTIME_DIRECTORY/lock"
  flock 9
  if ! drain "$DRAIN_PATIENCE_MINUTES"; then
    # shellcheck disable=SC2086
    systemctl start --no-block $RUNNER_UNITS
    fail "a job was still running after $DRAIN_PATIENCE_MINUTES minutes, so tonight's cleanup and reboot are skipped and the runners that were stopped are started again."
  fi
  wipe
  echo "Runners stopped and every container, image and volume removed. The machine reboots when this run ends."
}

case "${1:-}" in
  slot) run_one_job ;;
  check) hourly_check ;;
  maintain) nightly_maintenance ;;
  report) report_failure "${2:?report needs the name of the unit that failed}" ;;
  *) fail "usage: runner-server.sh {slot|check|maintain|report <unit>}" ;;
esac
