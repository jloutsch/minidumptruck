#!/usr/bin/env bash
# scribe-loop.sh - one poll tick for the scribe lane.
#
# Invoked periodically by launchd (see install-loops.sh, every 300s). A tick
# has two halves:
#
#   1. ml_process_approvals — advance any approved merges. This is independent
#      of the claim/worker lane (a merge consumes no worktree and spawns no
#      worker), so it runs unconditionally each tick: it re-verifies the PR and
#      its checks at current head, merges, then runs post-merge duties.
#
#      A merge is authorized one of exactly two ways. Either a HUMAN renamed a
#      .pending.md to .approved.md — the default for essentially everything — or
#      the PR falls inside the narrow docs-only auto-approve class, which the
#      loop recomputes itself from the PR's changed paths and size plus a clean
#      first-pass queue history (scripts/multi-agent/merge-policy.sh is the
#      enforced definition; docs/merge-policy.md explains it). No loop or worker
#      path writes .approved.md, and nothing a worker writes into the approval
#      file is an input to the class decision — so the loop still cannot talk
#      itself into a merge it was not authorized to make.
#
#   2. ml_tick — the standard claim/worker tick for the scribe-notes inbox:
#      claim the oldest scribe-notes/*.ready.md, run the scribe worker (which
#      pushes the branch via git-push-guard.sh, opens and monitors the PR, and
#      writes merge-approvals/<issue>-<slug>.pending.md — but NEVER merges),
#      then verify the pending file exists and no main-push was attempted.
#
# Set WORKER_CMD to override the worker invocation (used by test-queue.sh);
# this also skips the worktree ensure/bootstrap steps so tests never touch real
# worktrees or run npm.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/queue.sh" || {
  printf 'scribe-loop: failed to source queue.sh\n' >&2
  exit 1
}
# shellcheck source=./loop-lib.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/loop-lib.sh" || {
  printf 'scribe-loop: failed to source loop-lib.sh\n' >&2
  exit 1
}

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ml_process_approvals "$REPO_ROOT"
ml_tick "scribe" "scribe-notes" 0 "scribe-loop" "$REPO_ROOT"
exit $?
