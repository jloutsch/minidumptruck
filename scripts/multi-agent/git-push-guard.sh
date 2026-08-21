#!/usr/bin/env bash
# git-push-guard.sh - the scribe worker's ONLY sanctioned push path.
#
# Usage: git-push-guard.sh <issue> <slug> <git-push-args...>
#   e.g. git-push-guard.sh 835 phase3-middle-step -u origin auto/835-phase3-middle-step
#
# The scribe worker is denied direct `git push` (see loop-lib.sh
# _ml_run_worker), so every push it makes flows through here. This wraps
# ml_guarded_push, which refuses any push targeting main — by explicit ref
# spelling in any form (main / heads/main / refs/heads/main / HEAD:main /
# :main / +main / force) or by a bare push while HEAD is main — recording a
# per-task violation marker (the loop's postcondition fails the task on it) and
# notifying a human, WITHOUT contacting the remote. A non-main push is logged
# to state.log and executed, and this script exits with git's own status.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/queue.sh" || {
  printf 'git-push-guard: failed to source queue.sh\n' >&2
  exit 1
}
# shellcheck source=./loop-lib.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/loop-lib.sh" || {
  printf 'git-push-guard: failed to source loop-lib.sh\n' >&2
  exit 1
}

if [ "$#" -lt 2 ]; then
  printf 'git-push-guard: usage: git-push-guard.sh <issue> <slug> <git-push-args...>\n' >&2
  exit 2
fi

ml_guarded_push "$@"
exit $?
