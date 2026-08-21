#!/usr/bin/env bash
# queue.sh - poll-based inbox queue state machine for multi-agent handoffs.
# Sourced by loop/reaper scripts; not meant to be executed directly.
#
# State is carried entirely by filename suffix: .ready.md, .claimed.md,
# .done.md, .failed.md, .blocked.md. Frontmatter carries metadata only
# (issue, slug, stage, pass, retries, owner, updated).

# Derive MA_ROOT from this script's own location, not `git rev-parse` in
# the caller's CWD. Under launchd, CWD is `/` (or $HOME) and
# there is no git context at all, so the old default silently resolved to
# "/multi-agent" and every downstream check (`[ -e "$MA_ROOT" ]`) idled out
# with no error. queue.sh lives at scripts/multi-agent/queue.sh, so
# ../.. from here is the repo root. Works from any CWD, including an empty
# environment with no git installed.
: "${MA_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/multi-agent}"

# Timestamps split by audience:
#
#   _q_now_utc   - machine-parsed values. Frontmatter `updated` and any
#                  timestamp a script reads back (reaper staleness math parses
#                  it with `date -u -d`). MUST stay UTC with a `Z` suffix so
#                  the parse is unambiguous regardless of the reader's TZ.
#   _q_now_local - human-facing display only. state.log lines, the
#                  `## FAILED`/`## BLOCKED` body appendices. Uses the system
#                  local zone with a numeric offset so a founder reading the
#                  log sees wall-clock time, not UTC. No hardcoded timezone;
#                  never parsed back by any script.
#
# _q_now_utc
# Print the current UTC timestamp in the format used by frontmatter and any
# machine-parsed value.
_q_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _q_now_local
# Print the current system-local timestamp with a numeric offset, for
# human-facing display surfaces only. Never use for a value a script parses.
_q_now_local() {
  date +%Y-%m-%dT%H:%M:%S%z
}

# _q_state_of <file>
# Print the queue state implied by a handoff file's suffix.
_q_state_of() {
  local f="$1"
  case "$f" in
    *.ready.md) printf 'ready\n' ;;
    *.claimed.md) printf 'claimed\n' ;;
    *.done.md) printf 'done\n' ;;
    *.failed.md) printf 'failed\n' ;;
    *.blocked.md) printf 'blocked\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# _q_set_field <file> <key> <value>
# Replace the value of an existing frontmatter key, in place. Only touches
# lines between the first pair of "---" delimiters. Safe for values
# containing "/" or ":" since it never builds a sed/awk substitution regex
# out of the value. Value is passed via ENVIRON, not `awk -v`, since
# `-v` applies backslash-escape processing to its argument (latent today —
# no caller passes a value containing a backslash — but ENVIRON removes the
# hazard outright). Returns nonzero without modifying "$file" if awk fails
# or if "$file" has vanished by the time we're ready to install the result:
# a concurrent reaper/requeue can rename it out from under us in the
# window between the read and here, and blindly `mv`-ing the tmp file into
# that path would recreate an empty/stale file instead of failing loudly.
_q_set_field() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! val="$value" awk -v key="$key" '
    BEGIN { fm = 0 }
    /^---$/ { fm++; print; next }
    fm == 1 && $0 ~ "^" key ":" { print key ": " ENVIRON["val"]; next }
    { print }
  ' "$file" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ ! -e "$file" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$file"
}

# q_get <file> <key>
# Print a frontmatter value.
q_get() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { fm = 0 }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm == 1 && $0 ~ "^" key ":" {
      sub("^" key ":[ \t]*", "")
      print
      exit
    }
  ' "$file"
}

# _q_frontmatter_keys <file>
# Print each frontmatter key name found between the first pair of "---"
# delimiters, one per line.
_q_frontmatter_keys() {
  local file="$1"
  awk '
    BEGIN { fm = 0 }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm == 1 && /^[A-Za-z_][A-Za-z0-9_]*:/ {
      sub(/:.*/, "")
      print
    }
  ' "$file"
}

# _q_missing_frontmatter_keys <file>
# Print the required frontmatter keys absent from <file>'s frontmatter
# block, space-separated (empty string if none are missing). Required set:
# issue, slug, stage, pass, retries, owner, updated.
_q_missing_frontmatter_keys() {
  local file="$1"
  local required="issue slug stage pass retries owner updated"
  local present
  present=$(_q_frontmatter_keys "$file")
  local key missing=""
  for key in $required; do
    if ! printf '%s\n' "$present" | grep -qx "$key"; then
      missing="$missing $key"
    fi
  done
  printf '%s\n' "${missing# }"
}

# q_log <issue> <stage> <from> <to> <owner> <pass> [reason]
# Append one line to $MA_ROOT/state.log. Display surface: timestamped with the
# system-local zone (no script parses state.log). An optional <reason>
# annotates transitions that need disambiguating from an identical from->to
# pair (e.g. a quota-deferred claimed->ready vs an ordinary requeue).
q_log() {
  local issue="$1" stage="$2" from="$3" to="$4" owner="$5" pass="$6" reason="${7:-}"
  local now
  now=$(_q_now_local)
  mkdir -p "$MA_ROOT"
  if [ -n "$reason" ]; then
    printf '%s issue=%s stage=%s %s->%s owner=%s pass=%s reason=%s\n' \
      "$now" "$issue" "$stage" "$from" "$to" "$owner" "$pass" "$reason" >>"$MA_ROOT/state.log"
  else
    printf '%s issue=%s stage=%s %s->%s owner=%s pass=%s\n' \
      "$now" "$issue" "$stage" "$from" "$to" "$owner" "$pass" >>"$MA_ROOT/state.log"
  fi
}

# q_log_remote <issue> <action> [detail]
# Append one remote-operation audit line to state.log. Distinct from q_log's
# state transitions: a push / pr-open / merge is not a queue-state change, so
# it carries a `reason=<action>` key and no `from->to` pair (so the transition
# parsers that key on `->` skip these lines). This keeps state.log a complete
# audit trail of every remote action the scribe lane takes — the mechanical
# answer on the GitHub free plan, where no branch protection records remote
# writes server-side. Display surface only (system-local timestamp); no script
# parses it back.
q_log_remote() {
  local issue="$1" action="$2" detail="${3:-}"
  local now
  now=$(_q_now_local)
  mkdir -p "$MA_ROOT"
  printf '%s issue=%s stage=scribe remote reason=%s detail=%s\n' \
    "$now" "$issue" "$action" "$detail" >>"$MA_ROOT/state.log"
}

# _q_valid_issue_slug <issue> <slug>
# True (0) only if issue is all digits and slug contains only lowercase
# letters, digits, and hyphens (both non-empty). Issue and slug feed directly
# into worktree/branch names (.worktrees/$issue-$slug, auto/$issue-$slug); an
# unvalidated `issue` like "../../evil" escapes .worktrees/. This is the single
# source of truth for that rule: loop-lib's _ml_valid_issue_slug delegates here,
# and _q_brief_lint_applies uses it so the content lint never fires on a brief
# whose identity is malformed (the loop's safety guard owns that case instead).
_q_valid_issue_slug() {
  local issue="$1" slug="$2"
  case "$issue" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$slug" in
    '' | *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# _q_brief_lint_applies <file>
# Return 0 iff <file> is an original first-pass PM builder brief subject to the
# enqueue content lint: it lives in builder-tasks/, its frontmatter `stage` is
# `builder`, its `pass` is `1`, it carries NO `origin:` field, and its
# issue/slug are well-formed. Three classes are deliberately exempt:
#   - `pass` > 1 re-scope/fail-back briefs (any author). Terse pass-N re-scopes
#     without an `origin:` field exist in the historical corpus; gating them on
#     the four markers would block real work. The spec defects the template
#     guards against lived in pass-1 PM briefs, which is where the lint earns
#     its keep.
#   - briefs carrying `origin:` (e.g. `origin: scribe-post-review-fix`), a
#     worker- or scribe-authored fail-back. Both trace to an already-linted
#     parent brief, so re-linting their terser bodies would park legitimate work.
#   - briefs with a malformed issue/slug. Safety classification must never be
#     maskable by marker omission: a path-traversal `issue: ../../evil` brief
#     must reach the loop's invalid-issue/slug guard and be parked as .failed.md,
#     not intercepted first by this content lint and parked as .blocked.md. By
#     declining to lint it here, the lint runs strictly AFTER the safety guard in
#     the observable claim path.
# Validator/scribe ready files (other stages, other inboxes) never match either.
_q_brief_lint_applies() {
  local file="$1"
  case "$file" in
    */builder-tasks/*) ;;
    *) return 1 ;;
  esac
  [ "$(q_get "$file" stage)" = "builder" ] || return 1
  [ "$(q_get "$file" pass)" = "1" ] || return 1
  [ -z "$(q_get "$file" origin)" ] || return 1
  _q_valid_issue_slug "$(q_get "$file" issue)" "$(q_get "$file" slug)" || return 1
  return 0
}

# _q_missing_brief_markers <file>
# Print the required brief sections absent from <file>'s body, comma-separated
# (empty string if none are missing). Presence-only check — semantic quality of
# each section stays a PM/Validator discipline. The required set mirrors the
# enforced markers documented in docs/brief-template.md: the Premise
# verification line and the `## Gates`, `## Authorizations roster`, and
# `## Handoff` section headings.
_q_missing_brief_markers() {
  local file="$1"
  local missing=""
  grep -q 'Premise verification' "$file" || missing="${missing:+$missing, }Premise verification"
  grep -Eq '^## Gates' "$file" || missing="${missing:+$missing, }## Gates"
  grep -Eq '^## Authorizations roster' "$file" || missing="${missing:+$missing, }## Authorizations roster"
  grep -Eq '^## Handoff' "$file" || missing="${missing:+$missing, }## Handoff"
  printf '%s\n' "$missing"
}

# _q_name_integrity_applies <file>
# Return 0 iff <file> is subject to the name-integrity lint: a builder-tasks
# handoff whose issue/slug are well-formed. Unlike the marker lint
# (_q_brief_lint_applies), name-integrity has NO pass>1 / origin: exemptions —
# a queue file's NAME must always cohere with its own frontmatter identity,
# whatever authored it. The well-formed-issue/slug precondition preserves the
# same safety-guard ordering the marker lint relies on: a path-traversal
# `issue: ../../evil` brief declines the lint here so the loop's
# _ml_valid_issue_slug guard parks it as .failed.md rather than this lint
# pre-empting it as .blocked.md.
_q_name_integrity_applies() {
  local file="$1"
  case "$file" in
    */builder-tasks/*) ;;
    *) return 1 ;;
  esac
  _q_valid_issue_slug "$(q_get "$file" issue)" "$(q_get "$file" slug)" || return 1
  return 0
}

# _q_name_integrity_violation <file>
# Print a human-readable reason if <file>'s name disagrees with its own
# frontmatter identity, empty otherwise. Two checks:
#   (a) the filename base (basename minus the .<state>.md suffix) must equal
#       "<issue>-<slug>" from frontmatter. A file named for one task carrying
#       another task's frontmatter steers every issue-slug-derived path (the
#       worker's handoff, the loop's postcondition) at cross purposes.
#   (b) any handoff-file path stated inside the body's `## Handoff` section
#       must carry the same "<issue>-<slug>" base. This is the exact defect the
#       514-616 phantom chain exploited: a brief whose Handoff pointed a worker
#       at a different issue's handoff path. `#NNN` issue references in prose do
#       not match the handoff-file pattern, so they never trip this.
# Precondition: only meaningful when issue/slug are well-formed
# (_q_name_integrity_applies gates that).
_q_name_integrity_violation() {
  local file="$1"
  local issue slug expected state actual
  issue=$(q_get "$file" issue)
  slug=$(q_get "$file" slug)
  expected="${issue}-${slug}"

  state=$(_q_state_of "$file")
  actual=$(basename "$file")
  actual="${actual%."$state".md}"
  if [ "$actual" != "$expected" ]; then
    printf 'filename base "%s" does not match frontmatter issue-slug "%s"\n' "$actual" "$expected"
    return 0
  fi

  local handoff_bases base
  handoff_bases=$(awk '
    /^## Handoff/ { in_h = 1; next }
    in_h && /^## / { in_h = 0 }
    in_h { print }
  ' "$file" \
    | grep -oE '(builder-tasks|validator-notes|scribe-notes)/[0-9]+-[a-z0-9-]+\.[a-z]+\.md' \
    | sed -E 's#.*/([0-9]+-[a-z0-9-]+)\.[a-z]+\.md#\1#')
  for base in $handoff_bases; do
    if [ "$base" != "$expected" ]; then
      printf 'Handoff-section path base "%s" contradicts frontmatter issue-slug "%s"\n' "$base" "$expected"
      return 0
    fi
  done
  return 0
}

# _q_clear_pass_grant <issue> <slug> <pass>
# Remove the PM cycle-scoped pass-override grant for a resolved pass, if any.
# Called from the terminal queue transitions (q_done/q_fail/q_block) only for
# the validator leg — the pass's decision point, after which the pass is either
# advanced to scribe or failed back to a higher pass, so the grant is spent.
# The builder leg's terminal deliberately does NOT clear it: the grant must
# survive from the builder leg (which recorded it) to the validator leg of the
# same pass, whose builder-authored handoff cannot legally carry the
# pm_approved_pass field. A no-op when no grant exists.
_q_clear_pass_grant() {
  local issue="$1" slug="$2" pass="$3"
  [ -n "$pass" ] || return 0
  rm -f -- "$MA_ROOT/.pm-pass-grants/${issue}-${slug}-pass${pass}"
}

# q_claim <ready-file> <owner>
# Hardlink-claim a ready file. On success, stamps owner/updated, logs the
# transition, prints the claimed file's path, and returns 0. On a lost race,
# returns nonzero quietly (no stderr, no log line). If the claimed file's
# frontmatter is missing any required key (a human-authored ready file with
# a typo'd/omitted key, since `_q_set_field` silently no-ops on a key that
# isn't present), the file cannot be stamped or reaped sensibly: it is
# `q_block`ed instead, a human is notified, and this returns 2 (a code
# distinct from the lost-race 1; callers already treat any nonzero as
# no-work).
q_claim() {
  local ready_file="$1" owner="$2"
  local claimed_file="${ready_file%.ready.md}.claimed.md"

  if ! ln "$ready_file" "$claimed_file" 2>/dev/null; then
    return 1
  fi
  rm -f -- "$ready_file"

  local missing_keys
  missing_keys=$(_q_missing_frontmatter_keys "$claimed_file")
  if [ -n "$missing_keys" ]; then
    q_block "$claimed_file" "malformed frontmatter: missing key(s):$missing_keys"
    ma_notify "multi-agent: $(basename "$claimed_file") blocked - malformed frontmatter, missing key(s):$missing_keys"
    return 2
  fi

  # Name-integrity lint (runs for ALL builder handoffs with well-formed
  # issue/slug, with no pass>1 / origin: exemption): the filename and any
  # Handoff-section path must cohere with the file's own frontmatter identity.
  # Placed after the missing-frontmatter-keys check (which needs issue/slug to
  # exist) and before the marker lint (whose exemptions must not mask a name
  # mismatch). A violation takes the same park-and-notify path as the other
  # lints.
  if _q_name_integrity_applies "$claimed_file"; then
    local name_violation
    name_violation=$(_q_name_integrity_violation "$claimed_file")
    if [ -n "$name_violation" ]; then
      q_block "$claimed_file" "name-integrity: $name_violation"
      ma_notify "multi-agent: $(basename "$claimed_file") blocked - name-integrity: $name_violation"
      return 2
    fi
  fi

  # Content lint for original first-pass PM builder briefs (pass > 1 re-scopes
  # and origin-carrying fail-backs are exempt; see _q_brief_lint_applies). A
  # brief missing a required section cannot be worked sensibly by a headless
  # Builder, so it takes the same park-and-notify path as malformed frontmatter
  # rather than silently proceeding.
  if _q_brief_lint_applies "$claimed_file"; then
    local missing_markers
    missing_markers=$(_q_missing_brief_markers "$claimed_file")
    if [ -n "$missing_markers" ]; then
      q_block "$claimed_file" "brief lint: missing required section(s): $missing_markers"
      ma_notify "multi-agent: $(basename "$claimed_file") blocked - brief lint, missing section(s): $missing_markers"
      return 2
    fi
  fi

  local now
  now=$(_q_now_utc)
  _q_set_field "$claimed_file" "owner" "$owner" || return 1
  _q_set_field "$claimed_file" "updated" "$now" || return 1

  local issue stage pass
  issue=$(q_get "$claimed_file" issue)
  stage=$(q_get "$claimed_file" stage)
  pass=$(q_get "$claimed_file" pass)
  q_log "$issue" "$stage" "ready" "claimed" "$owner" "$pass"

  printf '%s\n' "$claimed_file"
  return 0
}

# q_done <claimed-file> [expected-owner]
# Stamp updated, rename to .done.md, log the transition. If expected-owner
# is given and doesn't match the file's current frontmatter `owner` (a
# worker that outlived the reaper's stale-claim window trying to complete a
# claim a successor now owns), return 1 without renaming or logging.
q_done() {
  local claimed_file="$1" expected_owner="${2:-}"
  if [ -n "$expected_owner" ]; then
    local actual_owner
    actual_owner=$(q_get "$claimed_file" owner)
    [ "$actual_owner" = "$expected_owner" ] || return 1
  fi

  local now
  now=$(_q_now_utc)
  # If the claimed file vanished from under us (reaper/requeue race),
  # _q_set_field fails instead of recreating it; propagate that failure
  # so we never mv a nonexistent/corrupt file into .done.md.
  _q_set_field "$claimed_file" "updated" "$now" || return 1

  local done_file="${claimed_file%.claimed.md}.done.md"
  mv -- "$claimed_file" "$done_file"

  local issue slug stage pass owner
  issue=$(q_get "$done_file" issue)
  slug=$(q_get "$done_file" slug)
  stage=$(q_get "$done_file" stage)
  pass=$(q_get "$done_file" pass)
  owner=$(q_get "$done_file" owner)
  q_log "$issue" "$stage" "claimed" "done" "$owner" "$pass"
  if [ "$stage" = "validator" ]; then
    _q_clear_pass_grant "$issue" "$slug" "$pass"
  fi
}

# q_fail <file> <reason> [expected-owner]
# Append a FAILED note to the body, stamp updated, rename to .failed.md,
# log the transition. If expected-owner is given and doesn't match the
# file's current frontmatter `owner`, return 1 without renaming or logging
# (see q_done for why: a stale worker completing a successor's claim).
q_fail() {
  local file="$1" reason="$2" expected_owner="${3:-}"
  if [ -n "$expected_owner" ]; then
    local actual_owner
    actual_owner=$(q_get "$file" owner)
    [ "$actual_owner" = "$expected_owner" ] || return 1
  fi

  local from_state now now_local
  from_state=$(_q_state_of "$file")
  if [ "$from_state" = "unknown" ]; then
    # An unrecognized suffix means "${file%."$from_state".md}" wouldn't
    # strip anything, producing a double-suffixed filename
    # (e.g. "foo.md.failed.md"). Fail loudly instead of writing that.
    printf 'q_fail: cannot determine state of %s (unrecognized suffix); refusing to rename\n' "$file" >&2
    return 1
  fi
  # `updated` is parsed by the reaper -> UTC. The body appendix is read by a
  # human -> system-local.
  now=$(_q_now_utc)
  now_local=$(_q_now_local)

  printf '\n## FAILED %s\n%s\n' "$now_local" "$reason" >>"$file"
  _q_set_field "$file" "updated" "$now" || return 1

  local failed_file="${file%."$from_state".md}.failed.md"
  mv -- "$file" "$failed_file"

  local issue slug stage pass owner
  issue=$(q_get "$failed_file" issue)
  slug=$(q_get "$failed_file" slug)
  stage=$(q_get "$failed_file" stage)
  pass=$(q_get "$failed_file" pass)
  owner=$(q_get "$failed_file" owner)
  q_log "$issue" "$stage" "$from_state" "failed" "$owner" "$pass"
  if [ "$stage" = "validator" ]; then
    _q_clear_pass_grant "$issue" "$slug" "$pass"
  fi
}

# q_requeue <claimed-file>
# Increment retries, clear owner, stamp updated, rename back to .ready.md,
# log the transition. The retries increment drives the reaper's dead-letter
# ceiling, so a requeue that is NOT the task's fault (quota exhaustion) must
# use q_requeue_noretry instead.
q_requeue() {
  _q_requeue_impl "$1" increment ""
}

# q_requeue_noretry <claimed-file> <reason>
# Requeue WITHOUT incrementing retries, logging the transition with <reason>.
# For deferrals that are environmental rather than the task's fault (quota
# exhaustion): the work was fine and must not accrue toward the reaper's
# dead-letter ceiling.
q_requeue_noretry() {
  _q_requeue_impl "$1" keep "$2"
}

# _q_requeue_impl <claimed-file> <increment|keep> <reason>
# Shared requeue body. Clears owner, stamps updated, renames back to
# .ready.md, logs the transition; increments retries only when <mode> is
# "increment".
_q_requeue_impl() {
  local claimed_file="$1" retry_mode="$2" reason="$3"
  local now retries new_retries
  now=$(_q_now_utc)
  retries=$(q_get "$claimed_file" retries)
  # Same non-numeric->0 coercion reaper.sh already applies before its
  # own `retries + 1`; without it a malformed retries value errors here
  # (survives under `set -u` since arithmetic errors aren't `set -e`
  # fatal) and writes an empty/garbage retries field.
  case "$retries" in
    '' | *[!0-9]*) retries=0 ;;
  esac
  if [ "$retry_mode" = increment ]; then
    new_retries=$((retries + 1))
  else
    new_retries=$retries
  fi

  _q_set_field "$claimed_file" "retries" "$new_retries" || return 1
  # A requeued claim is released — clear owner back to null so a
  # reaper (or another racer) never mistakes it for still-owned. Consistent
  # with reaper.sh's owner-empty/null skip.
  _q_set_field "$claimed_file" "owner" "null" || return 1
  _q_set_field "$claimed_file" "updated" "$now" || return 1

  local ready_file="${claimed_file%.claimed.md}.ready.md"
  mv -- "$claimed_file" "$ready_file"

  local issue stage pass owner
  issue=$(q_get "$ready_file" issue)
  stage=$(q_get "$ready_file" stage)
  pass=$(q_get "$ready_file" pass)
  owner=$(q_get "$ready_file" owner)
  q_log "$issue" "$stage" "claimed" "ready" "$owner" "$pass" "$reason"
}

# q_block <file> <reason>
# Append a BLOCKED note to the body, stamp updated, rename to .blocked.md,
# log the transition.
q_block() {
  local file="$1" reason="$2"
  local from_state now now_local
  from_state=$(_q_state_of "$file")
  if [ "$from_state" = "unknown" ]; then
    # See the identical guard in q_fail for why an unknown suffix must
    # refuse the rename instead of double-suffixing the filename.
    printf 'q_block: cannot determine state of %s (unrecognized suffix); refusing to rename\n' "$file" >&2
    return 1
  fi
  # `updated` is parsed by the reaper -> UTC. The body appendix is read by a
  # human -> system-local.
  now=$(_q_now_utc)
  now_local=$(_q_now_local)

  printf '\n## BLOCKED %s\n%s\n' "$now_local" "$reason" >>"$file"
  _q_set_field "$file" "updated" "$now" || return 1

  local blocked_file="${file%."$from_state".md}.blocked.md"
  mv -- "$file" "$blocked_file"

  local issue slug stage pass owner
  issue=$(q_get "$blocked_file" issue)
  slug=$(q_get "$blocked_file" slug)
  stage=$(q_get "$blocked_file" stage)
  pass=$(q_get "$blocked_file" pass)
  owner=$(q_get "$blocked_file" owner)
  q_log "$issue" "$stage" "$from_state" "blocked" "$owner" "$pass"
  if [ "$stage" = "validator" ]; then
    _q_clear_pass_grant "$issue" "$slug" "$pass"
  fi
}

# --- Quota-defer marker ---------------------------------------------------
#
# When a worker exits reporting session-limit (quota) exhaustion, the tick
# does NOT dead-letter the task — the work was fine, the environment ran out
# of budget. It requeues the claim (no retry increment) and drops a marker
# file, $MA_ROOT/.quota-deferred-until, holding a single epoch-seconds
# integer: the wall-clock time to resume. Every loop/reaper tick consults the
# marker first and skips while the deferral is active.
#
# Safety property (the marker must never wedge the loops permanently): the
# read below fails OPEN. An absent, expired, non-numeric, or implausibly
# far-future marker is treated as "not deferred" and removed, so the worst
# case is one extra quota-failed attempt that simply re-creates a fresh,
# correct marker.

# _q_quota_deferred_active
# Return 0 (caller should skip this tick) iff a marker exists whose epoch is
# still in the future and within the sane horizon. Otherwise return 1,
# removing an expired / malformed / out-of-horizon marker as a side effect.
_q_quota_deferred_active() {
  local marker="$MA_ROOT/.quota-deferred-until"
  [ -f "$marker" ] || return 1

  local until now horizon
  until=$(cat "$marker" 2>/dev/null)
  case "$until" in
    '' | *[!0-9]*)
      rm -f -- "$marker"
      return 1
      ;;
  esac

  now=$(date +%s)
  # A same-day reset plus grace can never legitimately be more than ~a day
  # out, so anything beyond the horizon is a corrupt value that must not be
  # allowed to pause the loops indefinitely. Overridable for tests.
  horizon=$((now + ${MA_QUOTA_MAX_DEFER_SEC:-93600}))
  if [ "$until" -le "$now" ] || [ "$until" -gt "$horizon" ]; then
    rm -f -- "$marker"
    return 1
  fi
  return 0
}

# _q_set_quota_defer <epoch-seconds>
# Write the quota-defer marker with the given resume epoch.
_q_set_quota_defer() {
  local until="$1"
  mkdir -p "$MA_ROOT"
  printf '%s\n' "$until" >"$MA_ROOT/.quota-deferred-until"
}

# ma_notify <message>
# User notification. Uses osascript by default; if MA_NOTIFY_CMD is set,
# runs that command with the message as $1 instead (lets tests stub this).
ma_notify() {
  local message="$1"
  if [ -n "${MA_NOTIFY_CMD:-}" ]; then
    "$MA_NOTIFY_CMD" "$message"
  else
    # argv form: $message reaches osascript as a positional arg to the
    # script, never interpolated into AppleScript source, so frontmatter
    # values (issue slugs, block reasons) can't inject AppleScript.
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "multi-agent"' -e 'end run' "$message"
  fi
}
