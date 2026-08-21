#!/usr/bin/env bash
# reaper.sh - crash-recovery sweep for the multi-agent queue.
# Scans builder-tasks, validator-notes, and scribe-notes inboxes for stale
# *.claimed.md files (the owning worker died mid-task). A stale claim is
# requeued; once it has been requeued MAX_RETRIES times, the next stale
# reap dead-letters it via q_fail and notifies a human via ma_notify.
# Idempotent. Safe against fresh claims via the owner-empty/null skip in
# _r_reap_claim below plus _q_set_field's vanished-target guard in
# queue.sh (a file that disappears mid-sweep is skipped silently) — this
# closes ordinary concurrent operation, not every millisecond-wide
# interleave; a handful of accepted low-probability residual races remain
# documented in the project's process notes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$SCRIPT_DIR/queue.sh" || {
  printf 'reaper: failed to source queue.sh\n' >&2
  exit 1
}

: "${MA_REAP_BUILDER_MIN:=90}"
: "${MA_REAP_VALIDATOR_MIN:=90}"
: "${MA_REAP_SCRIBE_MIN:=30}"

MAX_RETRIES=3

if [ ! -e "$MA_ROOT" ]; then
  exit 0
fi
if [ ! -r "$MA_ROOT" ]; then
  printf 'reaper: cannot read MA_ROOT: %s\n' "$MA_ROOT" >&2
  exit 1
fi

# Honor the quota-defer marker: while a session-limit deferral is active the
# whole system is paused, including crash recovery. The read fails open (an
# expired/malformed marker is cleared by the helper), so this can never wedge
# the reaper — an expired marker self-clears on the next tick.
if _q_quota_deferred_active; then
  exit 0
fi

# _r_timeout_min_for <inbox-name>
# Print the staleness threshold, in minutes, for an inbox directory name.
_r_timeout_min_for() {
  case "$1" in
    builder-tasks) printf '%s\n' "$MA_REAP_BUILDER_MIN" ;;
    validator-notes) printf '%s\n' "$MA_REAP_VALIDATOR_MIN" ;;
    scribe-notes) printf '%s\n' "$MA_REAP_SCRIBE_MIN" ;;
    *) printf '%s\n' "$MA_REAP_BUILDER_MIN" ;;
  esac
}

# _r_epoch <iso8601-utc>
# Print epoch seconds for a %Y-%m-%dT%H:%M:%SZ timestamp. Returns nonzero
# and prints nothing if the timestamp is empty or unparseable.
_r_epoch() {
  local ts="$1"
  [ -n "$ts" ] || return 1
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null && return 0
  # GNU date fallback (not the target platform, kept best-effort).
  date -u -d "$ts" +%s 2>/dev/null && return 0
  return 1
}

# _r_is_stale <claimed-file> <timeout-min>
# True (0) if the claim's frontmatter "updated" is more than timeout-min
# minutes old, or if "updated" is missing/unparseable.
_r_is_stale() {
  local file="$1" timeout_min="$2"
  local updated updated_epoch now_epoch age_sec timeout_sec
  updated=$(q_get "$file" updated)
  updated_epoch=$(_r_epoch "$updated") || return 0
  now_epoch=$(date -u +%s)
  age_sec=$((now_epoch - updated_epoch))
  timeout_sec=$((timeout_min * 60))
  [ "$age_sec" -gt "$timeout_sec" ]
}

# _r_downstream_dir <inbox-name>
# The inbox a completed <inbox-name> worker writes its handoff INTO, or empty
# if this stage has no simple next inbox (scribe's downstream is a
# merge-approvals .pending file, a different pattern, so it is not checked here).
_r_downstream_dir() {
  case "$1" in
    builder-tasks)   printf 'validator-notes\n' ;;
    validator-notes) printf 'scribe-notes\n' ;;
    *)               printf '\n' ;;
  esac
}

# _r_handoff_present <downstream-dir-name> <issue> <slug>
# True if ANY state-suffixed handoff for issue-slug already exists in the
# downstream inbox (.ready/.claimed/.done/... — any suffix means the upstream
# worker already handed off). Globs only this one issue-slug prefix, so it can
# never see another task's files.
_r_handoff_present() {
  local dir="$MA_ROOT/$1" issue="$2" slug="$3" f
  for f in "$dir/${issue}-${slug}."*.md; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# _r_reap_claim <claimed-file> <inbox-name> <timeout-min>
# Requeue a stale claim, or dead-letter it once it has already been
# requeued MAX_RETRIES times. Claims with an empty/null owner are skipped
# unless they're stale by more than 2x timeout-min — see the
# liveness-escape-hatch comment below.
_r_reap_claim() {
  local file="$1" inbox_name="$2" timeout_min="$3"
  [ -f "$file" ] || return 0

  local owner
  owner=$(q_get "$file" owner)
  if [ -z "$owner" ] || [ "$owner" = "null" ]; then
    # Liveness escape hatch: skipping empty/null-owner claims alone would
    # be the minimum guard, but it is not sufficient. A genuinely
    # mid-stamp claim (the window between q_claim's `ln` and its owner
    # stamp in queue.sh) only stays owner:null for milliseconds. Skipping
    # it unconditionally would be correct for that window alone, but a
    # worker that crashed inside that exact window would leave a claim
    # that can never become "owned-and-stale" again — a permanent,
    # lane-blocking claim invisible to the rest of this reaper. Requiring
    # staleness beyond 2x the stage timeout before treating an unowned
    # claim as reapable gives real mid-stamp windows an enormous safety
    # margin while still recovering a genuinely abandoned one eventually.
    _r_is_stale "$file" "$((timeout_min * 2))" || return 0
  fi

  # #918: a worker killed AFTER writing its downstream handoff but BEFORE its
  # own queue transition (classic: machine sleep in that window) leaves this
  # stale claim while the handoff is already live in the next inbox. Requeueing
  # it — or dead-lettering it — would mint a DUPLICATE brief alongside that
  # handoff, which the dual-handoff postcondition then fails. Detect the live
  # downstream handoff and supersede this stale claim instead: rename it to a
  # non-claimable .superseded.md (inert to every scanner) so no later tick
  # reclaims it, and leave the real handoff to proceed.
  local ds_dir issue slug
  ds_dir=$(_r_downstream_dir "$inbox_name")
  issue=$(q_get "$file" issue)
  slug=$(q_get "$file" slug)
  if [ -n "$ds_dir" ] && [ -n "$slug" ] && _r_handoff_present "$ds_dir" "$issue" "$slug"; then
    local pass superseded
    pass=$(q_get "$file" pass)
    superseded="${file%.claimed.md}.superseded.md"
    mv "$file" "$superseded"
    q_log "$issue" "$inbox_name" claimed superseded "$owner" "${pass:-?}" \
      "reaper: downstream handoff already present — not requeued (#918)"
    ma_notify "multi-agent: issue $issue stale $inbox_name claim superseded by reaper — downstream handoff already exists"
    return 0
  fi

  local retries
  retries=$(q_get "$file" retries)
  case "$retries" in
    '' | *[!0-9]*) retries=0 ;;
  esac

  if [ "$retries" -ge "$MAX_RETRIES" ]; then
    q_fail "$file" "reaper: $inbox_name claim stale after $retries retries"
    ma_notify "multi-agent: issue $issue dead-lettered by reaper ($inbox_name)"
  else
    q_requeue "$file"
  fi
}

# _r_reap_inbox <inbox-dir> <inbox-name>
_r_reap_inbox() {
  local inbox_dir="$1" inbox_name="$2"
  [ -d "$inbox_dir" ] || return 0

  local timeout_min
  timeout_min=$(_r_timeout_min_for "$inbox_name")

  local file
  for file in "$inbox_dir"/*.claimed.md; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue
    if _r_is_stale "$file" "$timeout_min"; then
      _r_reap_claim "$file" "$inbox_name" "$timeout_min"
    fi
  done
  # Explicit: the sweep's status must never depend on what the last
  # per-file staleness check happened to yield.
  return 0
}

reap_all() {
  _r_reap_inbox "$MA_ROOT/builder-tasks" builder-tasks
  _r_reap_inbox "$MA_ROOT/validator-notes" validator-notes
  _r_reap_inbox "$MA_ROOT/scribe-notes" scribe-notes
}

reap_all
exit 0
