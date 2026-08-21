#!/usr/bin/env bash
#
# Create a git worktree and verify the pre-push hook actually fires from it.
#
# Background: this repo's `.git/config` sets `core.hooksPath = scripts/git-hooks`
# (a relative path). git worktrees inherit that config from the main repo, so
# the path resolves against each worktree's cwd. Because scripts/git-hooks/ is
# TRACKED IN GIT, every worktree has it the moment `git worktree add` finishes
# — no install step, no Node toolchain, nothing to go stale.
#
# That is a deliberate change from the previous arrangement (issue #622), which
# pointed core.hooksPath at an untracked `.husky/_` directory. husky only
# creates that directory in the worktree where it last ran, so a fresh worktree
# resolved hooks to a path that did not exist and the pre-push hook silently did
# not fire. Tracking the hooks directory removes the failure mode rather than
# papering over it with a re-install step.
#
# Usage: forwards every argument to `git worktree add`.
#
#   ./scripts/new-worktree.sh .worktrees/foo -b feat/foo main
#   ./scripts/new-worktree.sh .worktrees/foo existing-branch
#   ./scripts/new-worktree.sh .worktrees/foo                 # reuse HEAD

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <path> [git-worktree-add args...]" >&2
  echo "  Example: $(basename "$0") .worktrees/622 -b fix/622 main" >&2
  exit 1
fi

WORKTREE_PATH="$1"

# Forward all args verbatim to git worktree add. Supports every form
# (reuse-branch, new-branch via -b, with or without explicit base).
git worktree add "$@"

cd "$WORKTREE_PATH"

HOOKS_DIR="$(git rev-parse --git-path hooks)"
PRE_PUSH="$HOOKS_DIR/pre-push"

# Verified, not assumed. A worktree whose hooks do not resolve is exactly the
# #622 failure mode, and it is silent by nature — the push simply succeeds when
# it should have been refused. Fail loudly here instead.
if [ ! -x "$PRE_PUSH" ]; then
  echo "ERROR: pre-push hook missing or non-executable at $PRE_PUSH" >&2
  echo "       Hooks resolved to: $HOOKS_DIR" >&2
  echo "       Expected core.hooksPath=scripts/git-hooks (tracked in git)." >&2
  echo "       Check: git config --get core.hooksPath" >&2
  exit 2
fi

echo ""
echo "Worktree ready: $WORKTREE_PATH"
echo "Hooks resolved to: $HOOKS_DIR"
echo "pre-push hook installed and executable."
