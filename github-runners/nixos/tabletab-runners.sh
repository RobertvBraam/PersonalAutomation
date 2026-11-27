#!/usr/bin/env bash
set -euo pipefail

# Brings TableTab's runners up from the compose file on table-tab's master, so
# the runner image and the Playwright version follow that repository without a
# copy of either here. tabletab-runners.service (configuration.nix) runs this at
# boot and every hour, and provides REPOSITORY, RUNNER_COUNT,
# RUNNER_ACCESS_TOKEN and the tools on PATH.

export GH_TOKEN="$RUNNER_ACCESS_TOKEN"
checkout="$STATE_DIRECTORY/table-tab"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# `runner.sh up` recreates a runner whose image changed, which abandons the job
# it is running. The Actions runner starts a Runner.Worker process per job.
# TODO: a job that starts in the seconds between this check and `up` is still
# abandoned when the image changed in that same hour. Draining the runners
# first (stop accepting jobs, wait, then `up`) would close that window.
a_job_is_running() {
  local id
  for id in $(docker ps -q); do
    if docker top "$id" | grep -c Runner.Worker >/dev/null; then
      return 0
    fi
  done
  return 1
}

sync_checkout() {
  if [ -d "$checkout/.git" ]; then
    git -C "$checkout" fetch --quiet --depth 1 origin master || fail "could not fetch $REPOSITORY. Check that the token in $STATE_DIRECTORY/token.env is valid and can read the repository."
    git -C "$checkout" reset --quiet --hard FETCH_HEAD
  else
    git clone --quiet --depth 1 --branch master "https://github.com/$REPOSITORY" "$checkout" || fail "could not clone $REPOSITORY. Check that the token in $STATE_DIRECTORY/token.env is valid and can read the repository."
  fi
}

if a_job_is_running; then
  echo "A job is running here, so the runners are left alone until the next run."
  exit 0
fi

sync_checkout
bash "$checkout/scripts/runner.sh" up "$RUNNER_COUNT"
