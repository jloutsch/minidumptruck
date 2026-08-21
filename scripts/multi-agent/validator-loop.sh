#!/usr/bin/env bash
# validator-loop.sh - one poll tick for the validator lane.
#
# Invoked periodically by launchd (see install-loops.sh, every 300s). Scans
# multi-agent/validator-notes for the oldest *.ready.md file; enforces the
# max-pass gate (pass >= 3 is blocked before claiming, with a human
# notification), then if the global lane is free, claims it and hands it
# to a Claude validator worker running from that issue's worktree. Idle
# ticks (empty inbox, busy lane, lost claim race, max-pass block) exit 0.
# Set WORKER_CMD to override the worker invocation (used by
# test-queue.sh); this also skips the worktree ensure/bootstrap steps so
# tests never touch real worktrees or run npm.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/queue.sh" || {
  printf 'validator-loop: failed to source queue.sh\n' >&2
  exit 1
}
# shellcheck source=./loop-lib.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/loop-lib.sh" || {
  printf 'validator-loop: failed to source loop-lib.sh\n' >&2
  exit 1
}

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ml_tick "validator" "validator-notes" 1 "validator-loop" "$REPO_ROOT"
exit $?
