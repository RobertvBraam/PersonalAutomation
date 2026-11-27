#!/usr/bin/env bash
set -euo pipefail

# Keeps TableTab's runners on this machine from the compose file on table-tab's
# master, so the runner image and the Playwright version follow that repository
# without a copy of either here.
#
#   sync      at boot and every hour: follow table-tab's master
#   maintain  every night: let the running jobs finish, wipe everything jobs
#             left behind and reboot into the newest system
#
# The two units in configuration.nix run this and provide REPOSITORY,
# RUNNER_COUNT, DRAIN_PATIENCE_MINUTES, RUNNER_ACCESS_TOKEN and the tools on
# PATH. Neither mode stops a runner that is running a job.

export GH_TOKEN="$RUNNER_ACCESS_TOKEN"
checkout="$STATE_DIRECTORY/table-tab"
applied="$STATE_DIRECTORY/applied"
out_of_rotation="$STATE_DIRECTORY/out-of-rotation"
runners_api="repos/$REPOSITORY/actions/runners"
exec 9>"$STATE_DIRECTORY/lock"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Sets `field` to one field of a runner as GitHub has it. Returns 1 when GitHub
# no longer knows the runner, which is what recreating its container does.
read_runner() {
  if field="$(gh api "$runners_api/$1" --jq "$2" 2>&1)"; then
    return 0
  fi
  [[ "$field" == *"HTTP 404"* ]] || fail "could not read runner $1 of $REPOSITORY from GitHub: $field"
  return 1
}

# Prints the id GitHub knows a container's runner by, and nothing for a
# container that is not a registered runner (the browser beside them).
runner_id_of() {
  docker exec "$1" cat /actions-runner/.runner 2>/dev/null | grep -o '"agentId": *[0-9]*' | grep -o '[0-9]*$' || true
}

# A runner without its custom labels gets no new job, while the job it is
# running carries on. What is taken away is written down first, so a run that
# dies half way is put right by the next one.
take_out_of_rotation() {
  local container id
  for container in $(docker ps -q); do
    id="$(runner_id_of "$container")"
    [ -n "$id" ] || continue
    read_runner "$id" '[.labels[] | select(.type == "custom") | .name] | join(",")' || continue
    [ -n "$field" ] || continue
    echo "$id $field" >>"$out_of_rotation"
    gh api -X DELETE "$runners_api/$id/labels" >/dev/null || fail "could not take runner $id out of rotation."
  done
}

put_back_in_rotation() {
  [ -f "$out_of_rotation" ] || return 0
  local id labels label names arguments
  while read -r id labels <&3; do
    read_runner "$id" .id || continue
    IFS=, read -ra names <<<"$labels"
    arguments=()
    for label in "${names[@]}"; do
      arguments+=(-f "labels[]=$label")
    done
    gh api -X POST "$runners_api/$id/labels" "${arguments[@]}" >/dev/null || fail "could not put runner $id back in rotation with the labels $labels."
  done 3<"$out_of_rotation"
  rm -f "$out_of_rotation"
}

# The Actions runner starts a Runner.Worker process per job, and GitHub marks a
# runner busy from the moment it assigns one, before that process exists.
a_job_is_running() {
  local container id _
  for container in $(docker ps -q); do
    if docker top "$container" | grep -c Runner.Worker >/dev/null; then
      return 0
    fi
  done
  [ -f "$out_of_rotation" ] || return 1
  while read -r id _ <&3; do
    read_runner "$id" .busy || continue
    [ "$field" = false ] || return 0
  done 3<"$out_of_rotation"
  return 1
}

# Waits for the running jobs, at most the given number of minutes.
# TODO: the 15 seconds are a guess at how long GitHub needs to show a job it
# assigned just before the labels went. Nothing documents that delay; a runner
# that can be told to finish its job and stop would need no guess.
wait_until_idle() {
  local deadline=$((SECONDS + $1 * 60))
  sleep 15
  while a_job_is_running; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 30
  done
}

sync_checkout() {
  if [ -d "$checkout/.git" ]; then
    git -C "$checkout" fetch --quiet --depth 1 origin master || fail "could not fetch $REPOSITORY. Check that the runner token is valid and can read the repository."
    git -C "$checkout" reset --quiet --hard FETCH_HEAD
  else
    git clone --quiet --depth 1 --branch master "https://github.com/$REPOSITORY" "$checkout" || fail "could not clone $REPOSITORY. Check that the runner token is valid and can read the repository."
  fi
}

# Everything `runner.sh up` builds the containers from.
# TODO: the three paths repeat what table-tab's scripts/runner.sh reads. If it
# starts reading another file, a change to that file is applied when no job is
# seen running, without taking the runners out of rotation first, so a job that
# starts in those seconds is abandoned. A `runner.sh` command that prints a
# hash of its own inputs would remove the copy.
fingerprint() {
  git -C "$checkout" rev-parse HEAD:.github/runner HEAD:scripts/runner.sh HEAD:tests/e2e/pnpm-lock.yaml || return 1
  sha256sum <<<"$RUNNER_ACCESS_TOKEN $RUNNER_COUNT"
}

# `runner.sh up` sets the RUNNER_LABEL repository variable when it is missing,
# which is wanted here: a laptop's `runner:down` clears it when it sees this
# machine's runners out of rotation. `down` must never clear it for this
# machine: jobs should wait out a restart, not fall to GitHub-hosted runners.
stop_runners() {
  RUNNER_AUTO_LABEL=false bash "$checkout/scripts/runner.sh" down
}

follow_master() {
  if ! flock --nonblock 9; then
    echo "The nightly maintenance is running, so this run does nothing."
    exit 0
  fi
  put_back_in_rotation
  sync_checkout

  local wanted
  wanted="$(fingerprint)" || fail "could not read the runner setup from the checkout. table-tab may have moved a file this script watches (fingerprint, above)."

  if [ "$wanted" = "$(cat "$applied" 2>/dev/null)" ]; then
    if a_job_is_running; then
      echo "A job is running here, so the runners are left alone until the next run."
      exit 0
    fi
    bash "$checkout/scripts/runner.sh" up "$RUNNER_COUNT"
    return
  fi

  trap put_back_in_rotation EXIT
  take_out_of_rotation
  if ! wait_until_idle 0; then
    echo "table-tab's runner setup changed, but a job is running here. The change waits for the next run."
    exit 0
  fi
  stop_runners
  bash "$checkout/scripts/runner.sh" up "$RUNNER_COUNT"
  echo "$wanted" >"$applied"
}

nightly_maintenance() {
  flock 9
  put_back_in_rotation
  trap put_back_in_rotation EXIT
  take_out_of_rotation
  wait_until_idle "$DRAIN_PATIENCE_MINUTES" || fail "a job was still running after $DRAIN_PATIENCE_MINUTES minutes, so tonight's cleanup and reboot are skipped and the runners go back in rotation."

  if [ -d "$checkout/.git" ]; then
    stop_runners
  fi
  docker system prune --all --volumes --force >/dev/null
  docker volume prune --all --force >/dev/null
  rm -rf "$checkout" "$applied"
  echo "Runners stopped and every image, volume and checkout removed. The machine reboots when this run ends."
}

case "${1:-}" in
  sync) follow_master ;;
  maintain) nightly_maintenance ;;
  *) fail "usage: tabletab-runners.sh {sync|maintain}" ;;
esac
