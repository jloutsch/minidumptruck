#!/usr/bin/env bash
# builder-loop.sh - one poll tick for the builder lane.
#
# Invoked periodically by launchd (see install-loops.sh, every 300s). Scans
# multi-agent/builder-tasks for the oldest *.ready.md file; if the global
# lane is free, claims it and hands it to a Claude builder worker running
# from that issue's worktree. Idle ticks (empty inbox, busy lane, lost
# claim race) exit 0 and do nothing. Set WORKER_CMD to override the worker
# invocation (used by test-queue.sh); this also skips the worktree
# ensure/bootstrap steps so tests never touch real worktrees or run npm.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/queue.sh" || {
  printf 'builder-loop: failed to source queue.sh\n' >&2
  exit 1
}
# shellcheck source=./loop-lib.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/loop-lib.sh" || {
  printf 'builder-loop: failed to source loop-lib.sh\n' >&2
  exit 1
}

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# enforce-max-pass=1: the builder gate participates in the max-pass ceiling so
# a PM's pm_approved_pass sanction on a builder brief is recorded as a
# cycle-scoped grant here, then honored on the validator leg whose
# builder-authored handoff cannot legally carry that field. Without the
# builder gate the sanction could never cross legs.
ml_tick "builder" "builder-tasks" 1 "builder-loop" "$REPO_ROOT"
exit $?
