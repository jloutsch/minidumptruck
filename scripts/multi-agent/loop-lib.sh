#!/usr/bin/env bash
# loop-lib.sh - shared poll-tick logic for builder-loop.sh and
# validator-loop.sh. Sourced only; not meant to be executed directly.
#
# Both loops share one shape: check the global lane, find the oldest ready
# file in their own inbox, (validator only) enforce the max-pass gate,
# claim, ensure/bootstrap the issue's worktree, invoke a worker, and record
# the outcome. ml_tick() implements that shape once; builder-loop.sh and
# validator-loop.sh each just supply their persona/inbox/gate parameters.

# The merge half of the scribe tick consults the auto-approve policy, so pull it
# in here rather than asking every caller to. Resolved from this file's own
# location (not the caller's cwd, which is `/` under launchd).
# shellcheck source=./merge-policy.sh
# shellcheck disable=SC1091 # path is resolved at runtime relative to this script
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-policy.sh" || {
  printf 'loop-lib: failed to source merge-policy.sh\n' >&2
  return 1
}

# _ml_lane_busy <ma-root>
# True (0) if any *.claimed.md exists in any of the three inboxes.
_ml_lane_busy() {
  local root="$1"
  local dir
  for dir in "$root/builder-tasks" "$root/validator-notes" "$root/scribe-notes"; do
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.claimed.md; do
      [ -e "$f" ] && return 0
    done
  done
  return 1
}

# _ml_all_claimed <ma-root>
# Print the full path of every *.claimed.md file across all three inboxes,
# one per line.
_ml_all_claimed() {
  local root="$1"
  local dir f
  for dir in "$root/builder-tasks" "$root/validator-notes" "$root/scribe-notes"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.claimed.md; do
      [ -e "$f" ] || continue
      printf '%s\n' "$f"
    done
  done
}

# _ml_count_claimed <ma-root>
# Print the total number of *.claimed.md files across all three inboxes.
_ml_count_claimed() {
  local root="$1"
  local count
  count=$(_ml_all_claimed "$root" | wc -l | tr -d ' ')
  printf '%s\n' "$count"
}

# _ml_enforce_single_claim <claimed-file>
# Post-claim TOCTOU guard for the global-lane rule. Two launchd jobs
# (builder-loop and validator-loop) each poll independently: both can pass
# `_ml_lane_busy` before either has claimed anything, then each claim a
# different ready file, putting two issues in flight at once. This re-scans
# all three inboxes right after our own claim succeeds; if the total count
# of *.claimed.md files is more than 1, some other lane won that race.
#
# Deterministic tiebreak: a plain "requeue ours" here is symmetric —
# if both racers ran this same check, both would see count>1 and both would
# requeue, so neither makes progress and both inflate `retries` for
# legitimate work (a livelock). Instead every racer applies the same total
# order to the same file set: keep the claim only if its own full path
# sorts lexically smallest among all current *.claimed.md paths; every
# other racer requeues its own. Exactly one survives per race,
# deterministically, with no coordination beyond the shared directory
# listing. Note `q_requeue` increments retries for the loser — acceptable
# here, since dead-lettering additionally requires the reaper's staleness
# check (a claim aged past its timeout), not just a single requeue from
# this race.
_ml_enforce_single_claim() {
  local claimed_file="$1"
  local claimed_count
  claimed_count=$(_ml_count_claimed "$MA_ROOT")
  if [ "$claimed_count" -gt 1 ]; then
    local smallest
    smallest=$(_ml_all_claimed "$MA_ROOT" | LC_ALL=C sort | head -n 1)
    if [ "$claimed_file" != "$smallest" ]; then
      q_requeue "$claimed_file"
      return 1
    fi
  fi
  return 0
}

# _ml_oldest_ready <inbox-dir>
# Print the oldest *.ready.md in the inbox (by mtime), or nothing if none.
# Uses `ls -t` (newest-first) reversed, relying on the documented assumption
# that queue filenames (<issue>-<slug>.<state>.md) never contain spaces or
# newlines.
_ml_oldest_ready() {
  local inbox_dir="$1"
  [ -d "$inbox_dir" ] || return 0
  local files
  files=$(ls -t "$inbox_dir"/*.ready.md 2>/dev/null)
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | tail -n 1
}

# _ml_hooks_installed <worktree-dir>
# True (0) if the worktree's resolved hooks dir has an executable pre-push
# hook (see scripts/new-worktree.sh for why this can be missing on a
# worktree that predates the wrapper).
_ml_hooks_installed() {
  local wt_dir="$1"
  (
    cd "$wt_dir" || exit 1
    hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null) || exit 1
    [ -x "$hooks_dir/pre-push" ]
  )
}

# _ml_valid_issue_slug <issue> <slug>
# True (0) only if issue is all digits and slug contains only lowercase
# letters, digits, and hyphens. Both feed directly into worktree/branch
# names (.worktrees/$issue-$slug, auto/$issue-$slug); an unvalidated `issue`
# like "../../evil" escapes .worktrees/. The slug check goes beyond the minimum
# guard (validating `issue` alone closes the traversal) because slug feeds
# the same branch name from the same frontmatter source — same call sites,
# same risk class, same guard technique.
#
# The rule is defined once in queue.sh (_q_valid_issue_slug) and delegated to
# here so the loop's safety guard and queue.sh's brief-lint exemption can never
# drift apart: if this guard rejects a brief, the lint must also have declined
# to touch it, so an invalid-issue/slug brief is always parked as .failed.md by
# this guard rather than pre-empted as .blocked.md by the content lint.
_ml_valid_issue_slug() {
  _q_valid_issue_slug "$1" "$2"
}

# _ml_worktree_path <repo-root> <issue> <slug>
# The single source of truth for a task's worktree path. Keyed by BOTH issue
# and slug (.worktrees/<issue>-<slug>), not issue alone: two tasks on the same
# issue but different slugs are distinct pieces of work with distinct branches
# (auto/<issue>-<slug>), and must not share one tree. The prior issue-only key
# meant a merge close-out for one slug removed the sibling slug's in-flight
# worktree. Worker setup AND close-out removal both derive the path here
# so they can never disagree. issue/slug are validated ([0-9]+ / [a-z0-9-]+)
# before any call site reaches this, so the composed path is filesystem-safe.
_ml_worktree_path() {
  local repo_root="$1" issue="$2" slug="$3"
  printf '%s\n' "$repo_root/.worktrees/$issue-$slug"
}

# _ml_refresh_worktree_base <worktree-dir> <issue> <slug>
# Bring a REUSED worktree's base up to origin/main when that is provably safe,
# and surface the drift when it is not (#1055).
#
# The create path below cuts from origin/main (#946/#925), but that only ever
# applied to a task's FIRST pass: the reuse path never fetched and never
# re-pointed, so every later pass ran against whatever origin/main was when the
# task started. #1052 pass 2 died on exactly this — its premise depended on a PR
# that had merged in between, and the roster forbade touching the file that
# proved it.
#
# Reuse is not simply wrong: it is what preserves a prior pass's committed work
# (#839 pass 2 resumed from its pass-1 commit and re-cutting would have destroyed
# it). So this distinguishes a worktree carrying WORK from one carrying only
# STALENESS, and only ever advances the latter.
#
# Safe to advance requires BOTH:
#   - no commits of its own (`origin/main..HEAD` is empty), and
#   - a clean tree — an uncommitted edit is work too, and `merge --ff-only`
#     would happily carry a dirty tree onto a new base, changing what the worker
#     is looking at underneath it.
# Anything else is left exactly as-is and reported. We never rebase: a conflict
# mid-tick would leave a half-rebased worktree, which is a worse failure than
# the staleness it fixes (that is option 2 in #1055, deliberately not taken).
_ml_refresh_worktree_base() {
  local wt_dir="$1" issue="$2" slug="$3"
  local behind own dirty

  behind=$(git -C "$wt_dir" rev-list --count HEAD..origin/main 2>/dev/null) || return 0
  [ "${behind:-0}" -gt 0 ] || return 0

  own=$(git -C "$wt_dir" rev-list --count origin/main..HEAD 2>/dev/null) || return 0
  dirty=$(git -C "$wt_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  if [ "${own:-0}" -eq 0 ] && [ "${dirty:-0}" -eq 0 ]; then
    if git -C "$wt_dir" merge --ff-only origin/main >/dev/null 2>&1; then
      printf 'loop: %s-%s worktree base advanced %s commit(s) to origin/main\n' \
        "$issue" "$slug" "$behind" >&2
    else
      ma_notify "multi-agent: $issue-$slug worktree is $behind behind origin/main and fast-forward failed — base is stale"
    fi
    return 0
  fi

  # Carries work. Report and leave alone — the brief author and the worker both
  # need to know the base is old, because a premise written against current
  # origin/main may be unsatisfiable here.
  ma_notify "multi-agent: $issue-$slug worktree is $behind behind origin/main (own commits=$own, dirty=$dirty) — base NOT advanced, work preserved"
  printf 'loop: %s-%s worktree base is %s behind origin/main; own=%s dirty=%s; not advanced\n' \
    "$issue" "$slug" "$behind" "$own" "$dirty" >&2
}

# _ml_ensure_worktree <repo-root> <issue> <slug>
# Create the task's worktree via scripts/new-worktree.sh if absent;
# otherwise reuse it — refreshing its base where safe (#1055) and warning if
# the pre-push hook does not resolve. Prints the worktree's absolute path.
_ml_ensure_worktree() {
  local repo_root="$1" issue="$2" slug="$3"
  local wt_dir
  wt_dir=$(_ml_worktree_path "$repo_root" "$issue" "$slug")

  if [ ! -d "$wt_dir" ]; then
    # Cut the worktree from origin/main, not local main (#946/#925). Nothing
    # fast-forwards local main — Scribe merges land on GitHub via `gh pr merge`
    # — so local main drifts behind origin/main by however many PRs merged since
    # the last pull, and a worker cutting from it builds on a stale base and
    # cannot see recently-merged deps. The loop (not the sandboxed worker) does
    # the fetch here, so the worker's no-fetch fence (see _ml_run_worker) is
    # untouched and the base is correct at cut time. Fetch is best-effort: on
    # failure we still branch from the last-known origin/main, which is never
    # staler than local main.
    (
      cd "$repo_root" || exit 1
      git fetch --quiet origin main 2>/dev/null || true
      ./scripts/new-worktree.sh ".worktrees/$issue-$slug" -b "auto/$issue-$slug" origin/main
    ) 1>&2
  else
    # Reuse. Fetch first so origin/main is current — the create path above does
    # its own fetch, and without one here the comparison below would measure
    # drift against a ref that is itself stale. Best-effort, exactly as above:
    # on failure we compare against the last-known origin/main, which is never
    # staler than not comparing at all.
    ( cd "$repo_root" && git fetch --quiet origin main 2>/dev/null ) || true
    _ml_refresh_worktree_base "$wt_dir" "$issue" "$slug"

    # core.hooksPath points at scripts/git-hooks, which is tracked in git, so a
    # worktree cannot be missing its hooks the way it could under husky (#622).
    # Still checked rather than assumed: a hooks dir that fails to resolve is
    # silent by nature — the push just succeeds when it should have been
    # refused — so surface it loudly instead of re-installing anything.
    if ! _ml_hooks_installed "$wt_dir"; then
      echo "WARNING: pre-push hook not resolvable in $wt_dir" >&2
      echo "         Expected core.hooksPath=scripts/git-hooks (tracked)." >&2
      echo "         Pushes from this worktree are NOT guarded by the hook." >&2
    fi
  fi

  printf '%s\n' "$wt_dir"
}

# _ml_bootstrap_worktree <worktree-dir>
# Bootstrap a fresh/reused worktree. This is a Swift Package Manager repo: the
# manifest lives at App/Package.swift and `swift build` resolves the pinned
# dependencies into the worktree's own .build/ on first invocation. There is no
# install step, no code generation, and no database.
#
# Best-effort by design. The personas make each worker run its own bootstrap
# as rule 1 and gate on the result, so a failure here must not abort the loop
# before the worker has a chance to report it properly — a worker that STOPs
# with findings is far more useful than a loop that dies with a shell error.
_ml_bootstrap_worktree() {
  local wt_dir="$1"
  ( cd "$wt_dir/App" && swift build ) 1>&2 || true
}

# _ml_run_worker <persona> <claimed-file> <repo-root> <worktree-dir> <issue> <slug>
# Invoke the worker (WORKER_CMD override if set, else the real Claude
# persona invocation from the worktree), capturing stdout+stderr to a log
# file under $MA_ROOT/logs. Prints the log file path; returns the worker's
# exit status.
_ml_run_worker() {
  local persona="$1" claimed_file="$2" repo_root="$3" worktree_dir="$4" issue="$5" slug="$6"
  local log_dir="$MA_ROOT/logs"
  mkdir -p "$log_dir"

  # Export the loop's (correct, parent) MA_ROOT into the worker's environment.
  # The worker runs with cwd set to the worktree and may source
  # git-push-guard.sh (hence queue.sh) by a RELATIVE path. queue.sh derives
  # MA_ROOT from its own BASH_SOURCE via `: "${MA_ROOT:=...}"`; sourced relative
  # from the worktree cwd that resolves to <worktree>/multi-agent, so the guard
  # would write its push-violation marker and remote-audit lines there — where
  # neither the scribe postcondition (_ml_check_postcondition) nor the parent
  # state.log ever looks, silently defeating both the main-push gate and the
  # audit trail. Exporting MA_ROOT makes queue.sh's default-assignment keep the
  # parent value in the worker, so the guard writes where the loop reads. This
  # is deliberately symmetric with the absolute-path discipline the personas
  # already use for their handoff writes.
  export MA_ROOT

  local ts log_file status
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  log_file="$log_dir/${issue}-${slug}-${persona}-${ts}.log"

  status=0
  if [ -n "${WORKER_CMD:-}" ]; then
    "$WORKER_CMD" "$claimed_file" "$repo_root" >"$log_file" 2>&1 || status=$?
  else
    local prompt
    prompt="$(cat "$repo_root/docs/personas/${persona}.md")

CLAIMED FILE: ${claimed_file}
REPO ROOT: ${repo_root}"
    # The persona's no-remote rule is policy prose only — nothing else enforces
    # it. --disallowedTools makes it a real gate instead of a convention a
    # worker prompt could ignore or misinterpret. Scribe is the sole persona
    # authorized for remote ops, but is still mechanically fenced: it may open
    # and monitor PRs (gh) and push, but only via git-push-guard.sh — direct
    # `git push` is denied, so every push is forced through the main-guard —
    # and `gh pr merge` is denied outright, because a merge is the loop's job,
    # gated on a human-renamed approval file, never the worker's.
    local disallowed
    if [ "$persona" = "scribe" ]; then
      disallowed='Bash(git push:*),Bash(gh pr merge:*),Bash(git pull:*),Bash(git fetch:*),Bash(git reset:*),Bash(git rebase:*)'
    else
      disallowed='Bash(git push:*),Bash(git remote:*),Bash(git fetch:*),Bash(git pull:*),Bash(gh:*)'
    fi
    ( cd "$worktree_dir" && claude -p "$prompt" --allowedTools "Read,Edit,Write,Bash,Grep,Glob" --disallowedTools "$disallowed" ) >"$log_file" 2>&1 || status=$?
  fi

  printf '%s\n' "$log_file"
  return "$status"
}

# _ml_postcondition_reason <persona> <issue> <slug> <claimed-pass>
# The postcondition rules themselves, independent of how a violation is typed:
# verify the worker actually produced its expected downstream handoff. A worker
# can exit 0 without having written any handoff (or having written one with
# incomplete frontmatter); without this gate that silently becomes a `done` with
# no artifact — the exact first-live-run defect this closes. Prints a
# human-readable reason; prints nothing and returns 0 when the postcondition
# holds. Personas with no defined postcondition pass through. Callers go through
# _ml_check_postcondition, which adds the fail-back/hard-failure typing.
#
# Violations carry one of two return codes, because not every violation may be
# softened into a fail-back by the worker appending findings:
#   1  typeable — the worker missed its handoff. If it also explained itself,
#      that is a deliberate hand-back and _ml_check_postcondition types it 2.
#   3  NOT typeable — the violation is a breach of a safety rule, and what the
#      worker wrote in its own file cannot change how the loop records it.
#      _ml_check_postcondition maps 3 to a hard failure without consulting the
#      findings. Two rules are in this class:
#        - the scribe main-push guard breach, whose safety-first ordering is
#          stated in its branch below: a refused push to main fails the task
#          even if the worker also produced its pending file. Findings must not
#          get a vote either, or a guard breach is recorded — in the state, the
#          log line, the notification, and any downstream router — as a routine
#          "needs re-scope" hand-back.
#        - the validator BOTH-handoffs contract violation, which leaves an
#          ambiguous routing state rather than a halt. A worker that emitted an
#          invalid state and then explained itself has still emitted an invalid
#          state; that is the fabricated-success class, not the halt class, so
#          it stays .failed (the loud terminal state) by construction.
_ml_postcondition_reason() {
  local persona="$1" issue="$2" slug="$3" claimed_pass="$4"
  local missing

  case "$persona" in
    builder)
      # Builder must hand off exactly one validator ready file.
      local expected="$MA_ROOT/validator-notes/${issue}-${slug}.ready.md"
      if [ ! -e "$expected" ]; then
        printf 'builder exited 0 but did not write the expected validator handoff (%s missing)' "$expected"
        return 1
      fi
      missing=$(_q_missing_frontmatter_keys "$expected")
      if [ -n "$missing" ]; then
        printf 'builder handoff %s has malformed frontmatter, missing key(s):%s' "$expected" "$missing"
        return 1
      fi
      ;;
    validator)
      # Validator must hand off EXACTLY ONE of: a scribe ready file (clear)
      # or a fresh builder brief with pass incremented (fail-back). Both or
      # neither is a failure.
      local scribe="$MA_ROOT/scribe-notes/${issue}-${slug}.ready.md"
      local failback="$MA_ROOT/builder-tasks/${issue}-${slug}.ready.md"
      local have_scribe=0 have_failback=0
      [ -e "$scribe" ] && have_scribe=1
      [ -e "$failback" ] && have_failback=1

      if [ "$have_scribe" -eq 1 ] && [ "$have_failback" -eq 1 ]; then
        printf 'validator exited 0 but wrote BOTH a scribe handoff (%s) and a fail-back builder brief (%s); exactly one is required' "$scribe" "$failback"
        return 3
      fi
      if [ "$have_scribe" -eq 0 ] && [ "$have_failback" -eq 0 ]; then
        printf 'validator exited 0 but wrote NEITHER a scribe handoff (%s) nor a fail-back builder brief (%s); exactly one is required' "$scribe" "$failback"
        return 1
      fi

      local target
      if [ "$have_scribe" -eq 1 ]; then
        target="$scribe"
      else
        target="$failback"
      fi
      missing=$(_q_missing_frontmatter_keys "$target")
      if [ -n "$missing" ]; then
        printf 'validator handoff %s has malformed frontmatter, missing key(s):%s' "$target" "$missing"
        return 1
      fi

      # On a fail-back the new builder brief must advance the pass counter,
      # so a rejected pass can never re-enter the loop at the same pass and
      # loop forever below the max-pass ceiling.
      if [ "$have_failback" -eq 1 ]; then
        case "$claimed_pass" in
          '' | *[!0-9]*) claimed_pass=0 ;;
        esac
        local new_pass expected_pass
        new_pass=$(q_get "$failback" pass)
        case "$new_pass" in
          '' | *[!0-9]*)
            printf 'validator fail-back brief %s has a non-numeric pass (%s); expected claimed pass + 1' "$failback" "$new_pass"
            return 1
            ;;
        esac
        expected_pass=$((claimed_pass + 1))
        if [ "$new_pass" -ne "$expected_pass" ]; then
          printf 'validator fail-back brief %s has pass=%s; expected %s (claimed pass %s + 1)' "$failback" "$new_pass" "$expected_pass" "$claimed_pass"
          return 1
        fi
      fi
      ;;
    scribe)
      # Two gates, safety-first order:
      #  1. A main-push attempt (recorded by ml_guarded_push during this run;
      #     the marker for this issue+slug is cleared in ml_tick right before
      #     the worker) fails the task even if a pending file was also written.
      #     Return 3, not 1: this ordering must hold against the worker's own
      #     findings too (see the return-code note above the function).
      #  2. The worker must have written the merge-approval pending file, and it
      #     must name the PR — the loop's later merge tick reads `pr` from it.
      local violation="$MA_ROOT/.push-violations/${issue}-${slug}.violation"
      if [ -e "$violation" ]; then
        printf 'scribe attempted a push to main — REFUSED by the push guard (%s present)' "$violation"
        return 3
      fi
      local pending="$MA_ROOT/merge-approvals/${issue}-${slug}.pending.md"
      if [ ! -e "$pending" ]; then
        printf 'scribe exited 0 but did not write the expected merge-approval pending file (%s missing)' "$pending"
        return 1
      fi
      local pr
      pr=$(q_get "$pending" pr)
      if [ -z "$pr" ]; then
        printf 'scribe pending file %s does not record a PR number (pr: key missing/empty)' "$pending"
        return 1
      fi
      ;;
  esac
  return 0
}

# _ml_check_postcondition <persona> <issue> <slug> <claimed-pass> [claimed-file]
# The postcondition gate ml_tick calls. Runs the rules
# (_ml_postcondition_reason), prints their reason verbatim, and TYPES the
# outcome through three distinct exit codes:
#   0  postcondition holds — the claim may be recorded done.
#   2  fail-back: the handoff is missing/invalid AND the claimed file carries a
#      worker-appended STOP/findings section, i.e. the worker deliberately
#      halted and handed back with its reasoning. A halt awaiting a re-scope,
#      not a malfunction — the caller routes it to .blocked.
#   1  hard failure: the handoff is missing/invalid and there are no findings
#      either. This is a worker that fabricated success, and it must keep
#      dead-lettering to .failed exactly as before.
# Code 2 requires <claimed-file>; without it (the postcondition rules tested in
# isolation) every violation types as 1, the safe direction — a STOP whose
# heading the scan misses degrades to today's .failed, never to a silent pass.
# Applies to all three personas: a scribe that halts on a red PR is as much a
# fail-back as a builder that halts on a stale premise.
#
# Not every violation is the worker's to soften. A rule that returns 3
# (see _ml_postcondition_reason: the scribe main-push guard breach and the
# validator BOTH-handoffs contract violation) is mapped straight to 1 WITHOUT
# reading the claimed file, so appending findings cannot downgrade a safety
# breach to a routine hand-back. Only 3 and 1 exist on the rules side; this
# function still speaks the documented 0/1/2 to its callers.
_ml_check_postcondition() {
  local persona="$1" issue="$2" slug="$3" claimed_pass="$4" claimed_file="${5:-}"
  local reason rc=0
  reason=$(_ml_postcondition_reason "$persona" "$issue" "$slug" "$claimed_pass") || rc=$?
  [ -n "$reason" ] && printf '%s' "$reason"
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 3 ] && return 1
  if [ -n "$claimed_file" ] && _ml_body_has_stop_section "$claimed_file"; then
    return 2
  fi
  return 1
}

# _ml_neutralize_stray_handoffs <issue> <slug>
# Neutralize a validator's two downstream handoffs by renaming each present
# one from `.ready.md` to a non-claimable `.superseded.md` suffix. Called only
# on the both-handoffs contract violation: a validator that wrote BOTH a
# scribe ready file and a fail-back builder brief has produced an ambiguous,
# invalid state, so the claim is failed AND neither stray handoff may be
# claimed by a later tick. `.superseded.md` was chosen over an archive/ move
# because it keeps the residue in place (easy for a human to find next to the
# task's other files) and is inert to every scanner here: _ml_oldest_ready
# globs only *.ready.md and _ml_lane_busy only *.claimed.md.
#
# Blast-radius guard: this touches ONLY this issue+slug's two known handoff
# paths. It never scans a directory or globs, so a contract violation on one
# task can never disturb any other task's handoffs.
_ml_neutralize_stray_handoffs() {
  local issue="$1" slug="$2"
  local f
  for f in "$MA_ROOT/scribe-notes/${issue}-${slug}.ready.md" \
           "$MA_ROOT/builder-tasks/${issue}-${slug}.ready.md"; do
    [ -e "$f" ] || continue
    mv -- "$f" "${f%.ready.md}.superseded.md"
  done
}

# _ml_classify_env_failure <worker-output-tail>
# Classify a nonzero worker exit against the environment-signature table,
# printing the class and returning 0 on a match, or printing nothing and
# returning 1 for a genuine task failure (which must dead-letter). These are
# environmental faults where the task itself was fine and the environment was
# unavailable, so all three defer rather than count a retry:
#   quota   - session budget exhausted ('hit your session limit'). The reset
#             clock is parseable, so the caller resolves a precise resume time.
#   auth    - the worker CLI is not authenticated ('Not logged in',
#             'Please run /login'). No parseable reset -> a fixed default defer.
#   network - a transport fault reaching the API ('API Error',
#             'Connection closed mid-response'). Also a fixed default defer.
# Order is most-specific-first so a quota message that also mentions a generic
# API phrase still classifies as quota.
_ml_classify_env_failure() {
  local text="$1"
  if printf '%s\n' "$text" | grep -qi 'hit your session limit'; then
    printf 'quota\n'
    return 0
  fi
  if printf '%s\n' "$text" | grep -qiE 'not logged in|please run /login'; then
    printf 'auth\n'
    return 0
  fi
  if printf '%s\n' "$text" | grep -qiE 'api error|connection closed mid-response'; then
    printf 'network\n'
    return 0
  fi
  return 1
}

# _ml_quota_reset_epoch <worker-output-tail>
# Resolve the epoch-seconds at which quota-deferred work should resume, from a
# session-limit message. Parses a "resets H:MM(am|pm)" clock time as today in
# the system-local zone (timezone names in the message are deliberately
# ignored — retry-time optimization is out of scope). Falls back to now + 30
# min if the time is absent, unparseable, or already past today. Always adds a
# 2-minute grace margin so the loops never wake at the exact reset second and
# immediately re-exhaust.
_ml_quota_reset_epoch() {
  local text="$1"
  local now reset_epoch timestr today parsed
  now=$(date +%s)

  timestr=$(printf '%s\n' "$text" \
    | grep -oiE 'resets[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' \
    | head -n 1 \
    | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' \
    | head -n 1)

  if [ -n "$timestr" ]; then
    # Strip internal spaces and uppercase the meridiem for strptime's %p.
    timestr=$(printf '%s' "$timestr" | tr -d '[:space:]' | tr 'apmAPM' 'APMAPM')
    today=$(date +%Y-%m-%d)
    parsed=$(date -j -f '%Y-%m-%d %I:%M%p' "$today $timestr" +%s 2>/dev/null)
  fi

  if [ -n "${parsed:-}" ] && [ "$parsed" -gt "$now" ]; then
    reset_epoch=$parsed
  else
    reset_epoch=$((now + 1800))
  fi

  printf '%s\n' "$((reset_epoch + 120))"
}

# --- Scribe remote-ops: main-push guard -----------------------------------
#
# On the GitHub free plan the repo has NO branch protection, so nothing on the
# server side stops a push to main. The protection is therefore MECHANICAL in
# these scripts: the scribe worker may push only through git-push-guard.sh
# (which calls ml_guarded_push), and the loop refuses to record success if a
# main-push was attempted. Two layers, both keyed on the same pure resolver so
# a ref spelling can't slip past one and not the other.

# _ml_token_is_main <ref-token>
# True (0) if a single ref token denotes the main branch, after stripping a
# leading '+' (force marker on a refspec side) and any refs/heads/ or heads/
# prefix. This is the atom every spelling check reduces to, so "main",
# "heads/main", "refs/heads/main", and "+refs/heads/main" all collapse to the
# same answer while "mainline" / "auto/9-main-thing" do not.
_ml_token_is_main() {
  local t="$1"
  t="${t#+}"
  t="${t#refs/heads/}"
  t="${t#heads/}"
  [ "$t" = "main" ]
}

# _ml_ref_targets_main <git-push-args...>
# PURE (no git state): true (0) if the given `git push` argument vector names
# main as either side of any refspec, in any spelling. Splits each positional
# on ':' (so "HEAD:main", "foo:refs/heads/main", ":main", "main:main" are all
# caught) and reduces both sides through _ml_token_is_main. Flags (anything
# starting with '-', including --force / -f / --delete / --set-upstream) are
# skipped for the ref test — a force or delete flag does not change WHICH ref
# is targeted, only how. The remote name (a bare positional like "origin")
# reduces to not-main and is harmless to test. Keeping this free of git state
# is deliberate: it is the exact surface the Validator is asked to attack, and
# a pure function is exhaustively unit-testable against every spelling.
_ml_ref_targets_main() {
  local arg left right
  for arg in "$@"; do
    case "$arg" in
      --) continue ;;
      -*) continue ;;
    esac
    case "$arg" in
      *:*) left="${arg%%:*}"; right="${arg#*:}" ;;
      *)   left="$arg"; right="$arg" ;;
    esac
    if _ml_token_is_main "$left" || _ml_token_is_main "$right"; then
      return 0
    fi
  done
  return 1
}

# _ml_push_carries_refspec <git-push-args...>
# True (0) if the push names an explicit target: a --delete/-d, or a second
# positional (the first positional is the remote; a second is a refspec). Used
# to decide whether the bare-push HEAD check applies: `git push origin` with no
# refspec pushes the CURRENT branch, so if HEAD is main it would advance remote
# main without ever spelling it — but `git push origin --delete <branch>` (the
# loop's post-merge branch cleanup, run from a repo-root checkout that sits on
# main) must NOT trip that HEAD check.
_ml_push_carries_refspec() {
  local arg seen_positional=0
  for arg in "$@"; do
    case "$arg" in
      --delete | -d) return 0 ;;
      --) continue ;;
      -*) continue ;;
    esac
    if [ "$seen_positional" -eq 1 ]; then
      return 0
    fi
    seen_positional=1
  done
  return 1
}

# _ml_record_push_violation <issue> <slug> <detail> <kind>
# Record a refused main-push: a per-task marker the scribe postcondition reads,
# a state.log audit line, and a LOUD human notification. The marker path is
# issue+slug scoped so one task's violation can never implicate another's.
_ml_record_push_violation() {
  local issue="$1" slug="$2" detail="$3" kind="$4"
  mkdir -p "$MA_ROOT/.push-violations"
  printf 'refused push to main (%s): %s\n' "$kind" "$detail" \
    >"$MA_ROOT/.push-violations/${issue}-${slug}.violation"
  q_log_remote "$issue" push "REFUSED-main ($kind): $detail"
  ma_notify "multi-agent: BLOCKED — push to main REFUSED for issue $issue ($kind): $detail"
}

# ml_guarded_push <issue> <slug> <git-push-args...>
# The scribe worker's ONLY push path (git-push-guard.sh wraps this). Refuses
# any push that targets main — by explicit ref spelling (_ml_ref_targets_main)
# or by a bare push while HEAD is main — recording a violation and returning
# nonzero WITHOUT touching the remote. Otherwise logs the push and runs it,
# propagating git's exit code so the worker sees the real result.
ml_guarded_push() {
  local issue="$1" slug="$2"
  shift 2
  if _ml_ref_targets_main "$@"; then
    _ml_record_push_violation "$issue" "$slug" "args=[$*]" "explicit-main-ref"
    return 1
  fi
  if ! _ml_push_carries_refspec "$@"; then
    local cur
    cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')
    if [ "$cur" = "main" ]; then
      _ml_record_push_violation "$issue" "$slug" "args=[$*] HEAD=main" "bare-push-from-main"
      return 1
    fi
  fi
  q_log_remote "$issue" push "args=[$*]"
  git push "$@"
}

# --- Scribe remote-ops: merge of approved PRs ------------------------------
#
# The scribe worker NEVER merges. It pushes, opens the PR, monitors checks, and
# writes multi-agent/merge-approvals/<issue>-<slug>.pending.md. From there a
# merge is authorized exactly one of two ways, and no others:
#
#   1. A HUMAN reviews and renames .pending.md -> .approved.md. This is the
#      default and covers essentially every PR. No loop or worker path ever
#      writes .approved.md — grep the tree: the suffix appears only on the read
#      side here.
#
#   2. The loop finds the PR inside the docs-only auto-approve class and renames
#      .pending.md -> .automerged.md itself (_ml_policy_pass). This is a real
#      loop-authorized merge, so the authority is deliberately hemmed in: the
#      class is narrow (docs prose only, control surfaces carved out, small),
#      and — the part that makes it safe — the eligibility inputs are RECOMPUTED
#      from the live PR and state.log at process time. No claim a worker wrote
#      into the approval file is an input, so a worker cannot mint its own
#      auto-approval by claiming to be docs-only; the file only names WHICH PR is
#      judged, and the identity gates below pin that to auto/<issue>-<slug>.
#      merge-policy.sh holds the definition and the reasoning;
#      docs/merge-policy.md is its human-readable statement.
#
# Both paths converge on _ml_process_one_approval and clear the SAME gates: the
# PR is the one named in the file, its live head still matches, and its checks
# are green at current head.

# _ml_process_one_approval <approval-file> <repo-root>
# Merge one approved PR, then run post-merge duties. Every early return leaves
# the approval file intact (so a transient failure retries next tick) and
# notifies a human; only a completed merge renames it to .merged.md.
#
# Two suffixes reach this function, and they differ ONLY in who authorized the
# merge — the gates below are identical for both:
#   .approved.md   a human renamed a .pending.md. The default path.
#   .automerged.md the loop certified the PR against the docs-only auto-approve
#                  class (see merge-policy.sh). Reached only via _ml_policy_pass,
#                  which recomputes eligibility from GitHub + state.log.
# Authorization decides WHO approves, never WHETHER the checks matter: identity,
# live-head, and green-checks-at-current-head all still run.
_ml_process_one_approval() {
  local file="$1" repo_root="$2"
  local issue slug pr branch expected_branch stem mode
  case "$file" in
    *.automerged.md)
      stem="${file%.automerged.md}"
      mode=auto-merge-policy
      ;;
    *)
      stem="${file%.approved.md}"
      mode=human-approval
      ;;
  esac
  issue=$(q_get "$file" issue)
  slug=$(q_get "$file" slug)
  pr=$(q_get "$file" pr)
  branch=$(q_get "$file" branch)
  expected_branch="auto/${issue}-${slug}"

  # Identity gate 1 (from the file): a PR number must be present and the file's
  # own branch field must match the task's canonical auto branch. A hand-edit
  # pointing the approval at a different branch is refused here.
  if [ -z "$pr" ] || [ "$branch" != "$expected_branch" ]; then
    q_log_remote "$issue" merge "SKIPPED-no-pr-or-branch-mismatch pr='$pr' branch='$branch' expected='$expected_branch'"
    ma_notify "multi-agent: approval $(basename "$file") has no PR or a branch mismatch (pr='$pr' branch='$branch' expected='$expected_branch') — NOT merged"
    return 0
  fi

  # Every gh call runs in a `( cd "$repo_root" && ... )` subshell: gh resolves
  # the target repo from the current directory's git remotes, and under launchd
  # the tick shell's cwd is `/` (the plists set no WorkingDirectory), where gh
  # has no repo context and every call fails silently. This matches the worker
  # path, which already cd's into the repo before its own git/gh operations. The
  # subshell keeps the cd local so the caller's cwd is never mutated.

  # Identity gate 2 (from GitHub): the live PR's head branch must still be the
  # expected one, so a recycled/renumbered PR can't be merged under this issue.
  # Distinguish a gh failure (empty because the call errored — network, auth, or
  # a bad cwd) from a genuine head mismatch: only the latter means "wrong PR".
  local live_head gh_status
  live_head=$(cd "$repo_root" && gh pr view "$pr" --json headRefName --jq '.headRefName' 2>/dev/null)
  gh_status=$?
  if [ "$gh_status" -ne 0 ]; then
    q_log_remote "$issue" merge "SKIPPED-gh-unavailable pr=$pr"
    ma_notify "multi-agent: PR #$pr head lookup failed (gh unavailable/errored, exit $gh_status) — NOT merged (approval left intact)"
    return 0
  fi
  if [ "$live_head" != "$expected_branch" ]; then
    q_log_remote "$issue" merge "SKIPPED-live-head-mismatch pr=$pr live='$live_head' expected='$expected_branch'"
    ma_notify "multi-agent: PR #$pr head '$live_head' != expected '$expected_branch' — NOT merged (approval left intact)"
    return 0
  fi

  # Identity gate 3 (commit-scoped): the live head SHA must still be the one
  # recorded in the approval file when it was written. Gates 1 and 2 are
  # branch-scoped — they prove the approval points at the right PR on the right
  # branch, and nothing about WHICH COMMIT is on it. Without this gate any push
  # to an approved branch between the human's rename and this tick merges under
  # an approval nobody granted for that code: the reviewer approves commit A,
  # a worker (or a person) pushes B, and B merges wearing A's approval.
  #
  # Fail-closed on a missing field. Every Scribe-written pending file carries
  # head_sha (docs/personas/scribe.md), so an approval without one is either
  # hand-made or from a pre-gate version, and neither should merge silently.
  local recorded_sha live_sha sha_status
  recorded_sha=$(q_get "$file" head_sha)
  if [ -z "$recorded_sha" ]; then
    q_log_remote "$issue" merge "SKIPPED-no-head-sha pr=$pr"
    ma_notify "multi-agent: approval $(basename "$file") records no head_sha — NOT merged (cannot prove the approved commit)"
    return 0
  fi
  live_sha=$(cd "$repo_root" && gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  sha_status=$?
  # Same gh-failure-vs-genuine-mismatch split as gate 2: an errored call must
  # not read as "the commit changed", or a network blip would look like tampering
  # and vice versa.
  if [ "$sha_status" -ne 0 ] || [ -z "$live_sha" ]; then
    q_log_remote "$issue" merge "SKIPPED-gh-unavailable-sha pr=$pr"
    ma_notify "multi-agent: PR #$pr head SHA lookup failed (gh unavailable/errored, exit $sha_status) — NOT merged (approval left intact)"
    return 0
  fi
  if [ "$live_sha" != "$recorded_sha" ]; then
    q_log_remote "$issue" merge "SKIPPED-head-sha-moved pr=$pr live='$live_sha' approved='$recorded_sha'"
    ma_notify "multi-agent: PR #$pr moved from the approved commit ${recorded_sha} to ${live_sha} — NOT merged. Re-review and re-approve."
    return 0
  fi

  # Freshness gate: checks must be green at the CURRENT head, not at the head
  # that was green when the pending file was written. `gh pr checks` exits
  # nonzero if any check is failing or still pending.
  if ! ( cd "$repo_root" && gh pr checks "$pr" >/dev/null 2>&1 ); then
    q_log_remote "$issue" merge "SKIPPED-checks-not-green pr=$pr"
    ma_notify "multi-agent: PR #$pr checks not green at current head — NOT merged (approval left intact)"
    return 0
  fi

  q_log_remote "$issue" merge "pr=$pr branch=$expected_branch via=$mode"
  if ! ( cd "$repo_root" && gh pr merge "$pr" --squash >/dev/null 2>&1 ); then
    q_log_remote "$issue" merge "SKIPPED-merge-command-failed pr=$pr"
    ma_notify "multi-agent: PR #$pr merge command failed — approval left intact"
    return 0
  fi

  # Post-merge duties (best-effort; a merge already happened, so none of these
  # may un-merge — failures are logged/notified, never fatal).
  local audit_body
  if [ "$mode" = "auto-merge-policy" ]; then
    audit_body="Auto-merged via scribe-loop under the docs-only auto-approve class ($(basename "$file")). Audit: no human approved this merge — eligibility was recomputed by the loop from the PR's own changed paths and size plus a clean first-pass queue history, per docs/merge-policy.md. The usual merge gates (PR identity, live head, green checks at current head) all ran. Review is after the fact: if this PR should not have been in the class, the class is what needs fixing."
  else
    audit_body="Merged via scribe-loop after human approval ($(basename "$file")). Audit: Validator-quoted findings are in the commit messages; approval gate satisfied by a human-renamed .approved.md."
  fi
  ( cd "$repo_root" && gh pr comment "$pr" --body "$audit_body" >/dev/null 2>&1 ) || true

  # Explicit remote branch delete — guarded against main by construction
  # (expected_branch is auto/<digits>-<slug>, never main) and by the resolver.
  if _ml_ref_targets_main "$expected_branch"; then
    ma_notify "multi-agent: refusing to delete branch resolving to main ('$expected_branch')"
  else
    git -C "$repo_root" push origin --delete "$expected_branch" >/dev/null 2>&1 || true
    q_log_remote "$issue" push "delete branch=$expected_branch"
  fi

  # Worktree removal (the task's build environment is no longer needed).
  # Keyed by issue-slug via the shared helper so this removes ONLY this task's
  # tree, never a sibling slug's on the same issue.
  git -C "$repo_root" worktree remove "$(_ml_worktree_path "$repo_root" "$issue" "$slug")" >/dev/null 2>&1 || true

  # The scribe-note is already .done.md from the worker path (it was completed
  # when the pending file was written); nothing to transition here.

  # Approval file -> .merged.md (terminal). Clean up any reminder marker.
  rm -f -- "${stem}.pending.md.reminded"
  mv -- "$file" "${stem}.merged.md"
  q_log_remote "$issue" merge "MERGED pr=$pr via=$mode"
  if [ "$mode" = "auto-merge-policy" ]; then
    ma_notify "multi-agent: auto-merged under docs policy: PR #$pr — branch '$expected_branch' deleted (issue $issue). No human approved this; see docs/merge-policy.md."
  else
    ma_notify "multi-agent: PR #$pr merged and branch '$expected_branch' deleted (issue $issue)"
  fi
  return 0
}

# _ml_policy_pass <pending-or-automerged-file> <repo-root>
# The auto-approve half of the merge tick. Recomputes the docs-only class for
# one approval file — at process time, from GitHub and state.log, reading
# NOTHING the file itself claims (see merge-policy.sh's cannot-mint note) — and
# merges it through the same gates as a human approval if it is in-class.
#
# Ineligible .pending.md: return quietly. The file stays pending and today's
# human gate is untouched, which is why an out-of-class PR sees no behavior
# change at all — not even a notification.
#
# Ineligible .automerged.md: a PR certified in-class on an earlier tick that no
# longer is (its head moved and now touches a control surface, say). Hand it
# BACK to the human gate rather than merge on a stale certificate; this is why
# eligibility is re-evaluated on every tick and not cached in the file.
_ml_policy_pass() {
  local file="$1" repo_root="$2"
  local issue slug pr reason status=0

  issue=$(q_get "$file" issue)
  slug=$(q_get "$file" slug)
  pr=$(q_get "$file" pr)

  reason=$(mp_eligible "$pr" "${issue}-${slug}" "$repo_root") || status=$?

  if [ "$status" -ne 0 ]; then
    case "$file" in
      *.automerged.md)
        mv -- "$file" "${file%.automerged.md}.pending.md" || return 0
        q_log_remote "$issue" auto-merge-policy "REVOKED pr=$pr detail=$reason"
        ma_notify "multi-agent: PR #$pr no longer satisfies the docs auto-approve policy ($reason) — returned to the human approval gate"
        ;;
    esac
    return 0
  fi

  local stem automerged
  stem="${file%.pending.md}"
  stem="${stem%.automerged.md}"
  automerged="${stem}.automerged.md"
  if [ "$file" != "$automerged" ]; then
    mv -- "$file" "$automerged" || return 0
  fi
  q_log_remote "$issue" auto-merge-policy "pr=$pr detail=$reason"
  _ml_process_one_approval "$automerged" "$repo_root"
}

# _ml_remind_pending <approval-file>
# Low-frequency reminder that a merge approval is still waiting on a human.
# First sighting only records a timestamp marker (no notification, so a file
# that appears and is handled within one interval never spams); subsequent
# sightings notify at most once per MA_APPROVAL_REMIND_SEC.
#
# On each interval-elapsed sighting of a *.pending.md file, the reminder ALSO
# re-opens that file in TextMate via _ml_open_file_for_review — the one channel
# proven to reach a founder from a launchd-spawned loop. macOS silently drops the
# osascript banner ma_notify emits when there is no TCC session, so a background
# reminder surfaced nothing; that is how one pending approval sat unseen for two
# days. This mirrors the create-time open on the scribe success tick, and the
# .reminded marker (written just above) is the same once-per-interval throttle,
# so the editor is re-raised at most once per MA_APPROVAL_REMIND_SEC and the
# reminder cadence is unchanged. The re-open is deliberately scoped to .pending.md
# only: _ml_remind_pending also runs over *.rejected.md files, which a human has
# already actioned, so those keep the banner alone and are never re-opened.
# The merge-approval file carries no `stage` field, so the audit stage is the
# constant "scribe" (the lane that produces every approval file, matching
# _ml_open_pending_for_review); `pass` is read from the file and is empty for
# these files. _ml_open_file_for_review is itself fully swallowed, so a failed or
# GUI-less open can never fail the reminder.
_ml_remind_pending() {
  local file="$1"
  local marker="${file}.reminded"
  local now interval last
  now=$(date +%s)
  interval="${MA_APPROVAL_REMIND_SEC:-21600}"
  if [ -f "$marker" ]; then
    last=$(cat "$marker" 2>/dev/null)
    case "$last" in
      '' | *[!0-9]*) last=0 ;;
    esac
    if [ "$((now - last))" -ge "$interval" ]; then
      ma_notify "multi-agent: merge approval still awaiting human action: $(basename "$file")"
      printf '%s\n' "$now" >"$marker"
      case "$file" in
        *.pending.md)
          local issue pass
          issue=$(q_get "$file" issue)
          pass=$(q_get "$file" pass)
          _ml_open_file_for_review "$file" "$issue" scribe "$pass"
          ;;
      esac
    fi
  else
    printf '%s\n' "$now" >"$marker"
  fi
}

# ml_process_approvals <repo-root>
# The merge half of a scribe-loop tick, independent of the claim/worker lane (a
# merge consumes no worktree and spawns no worker). Acts on human-produced
# .approved.md files, then emits low-frequency reminders for anything still
# awaiting a human. Honors the quota-defer marker like every other tick path.
ml_process_approvals() {
  local repo_root="$1"
  local approvals_dir="$MA_ROOT/merge-approvals"
  [ -d "$approvals_dir" ] || return 0
  if _q_quota_deferred_active; then
    return 0
  fi

  local f
  for f in "$approvals_dir"/*.approved.md; do
    [ -e "$f" ] || continue
    _ml_process_one_approval "$f" "$repo_root"
  done

  # Auto-approve pass: anything still pending is re-tested against the docs-only
  # class, and anything certified on an earlier tick is re-tested before it
  # merges. Ineligible pendings fall through to the reminder loop below exactly
  # as they do today.
  for f in "$approvals_dir"/*.pending.md "$approvals_dir"/*.automerged.md; do
    [ -e "$f" ] || continue
    _ml_policy_pass "$f" "$repo_root"
  done

  for f in "$approvals_dir"/*.pending.md "$approvals_dir"/*.rejected.md; do
    [ -e "$f" ] || continue
    _ml_remind_pending "$f"
  done
  return 0
}

# _ml_open_pending_for_review <issue> <slug> <pass>
# Best-effort open of the just-written merge-approval pending file in TextMate,
# the founder's review editor. Approvals are session-less — there is no live PM
# chat surfacing the file — so the loop opens the editor at the moment the
# pending file is created. Called ONLY from ml_tick's scribe postcondition-success
# branch, which the loop reaches exactly once per scribe claim (a scribe note is
# claimed once, then transitions to .done.md), so the window opens a single time
# at create time and never on the low-frequency reminder re-scans in
# ml_process_approvals. A launch failure (no GUI session, TextMate absent) must
# never fail the task, so the open is fully swallowed; the audit line records the
# outcome either way. `open` is macOS-only, which is fine: the loops run solely
# as launchd LaunchAgents. Tests PATH-shim `open` to assert the invocations.
#
# The audit line carries `open`'s verbatim exit code (`rc=<N>`), which is what
# makes an attempted open distinguishable from a succeeded one: a swallowed
# failure and a successful launch that simply never surfaced a window used to
# produce byte-identical audit lines. On a successful launch the window is then
# raised by a SECOND, bare `open -a TextMate` (no file argument — pure app
# activation), whose own exit code is audited as `raise_rc=<M>`. The raise is a
# separate step because `open <file>` alone does not reliably front an
# already-running TextMate, so a pending file could be opened into a background
# window the founder never sees.
#
# The raise deliberately goes through LaunchServices rather than an
# `osascript ... activate` Apple event: sending an Apple event requires
# Automation (TCC) permission, which a launchd-spawned shell cannot hold and
# cannot prompt for, so that activation silently no-op'd in exactly the
# environment the loops actually run in. `open` needs no such permission.
# The raise is skipped when the launch failed — there is nothing to raise, and
# `raise_rc=skipped` records that no attempt was made — and, like the launch, is
# fully swallowed, so neither branch can fail the task.
_ml_open_pending_for_review() {
  local issue="$1" slug="$2" pass="$3"
  local pending="$MA_ROOT/merge-approvals/${issue}-${slug}.pending.md"
  [ -e "$pending" ] || return 0
  local rc=0 raise_rc=skipped
  open -a TextMate "$pending" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    open -a TextMate >/dev/null 2>&1; raise_rc=$?
  fi
  q_log "$issue" scribe pending pending null "$pass" "pending-opened-textmate rc=$rc raise_rc=$raise_rc"
  return 0
}

# _ml_open_in_textmate <file>
# The raw open+raise used by every founder-awareness open (the #884 pattern).
# Opens <file> in TextMate through LaunchServices (`open -a`), then — only if
# that launch succeeded — fronts the window with a SECOND, bare `open -a TextMate`
# (no file argument), because `open <file>` alone does not reliably front an
# already-running TextMate. Prints "rc=<N> raise_rc=<M|skipped>" so the caller can
# fold both verbatim exit codes into its own audit line. Deliberately does NOT use
# `osascript ... activate` for the raise: an Apple event needs Automation (TCC)
# permission a launchd-spawned shell cannot hold or prompt for, so it silently
# no-op'd in exactly the environment the loops run in (see the long note on
# _ml_open_pending_for_review). Fully swallowed — a missing GUI session or absent
# TextMate leaves the codes nonzero but this still returns 0, so it can never fail
# the caller's task. Tests PATH-shim `open` to assert the invocations.
_ml_open_in_textmate() {
  local file="$1"
  local rc=0 raise_rc=skipped
  open -a TextMate "$file" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    open -a TextMate >/dev/null 2>&1; raise_rc=$?
  fi
  printf 'rc=%s raise_rc=%s\n' "$rc" "$raise_rc"
  return 0
}

# _ml_open_file_for_review <file> <issue> <stage> <pass>
# Founder-awareness open for a terminal loop transition that produced a file to
# read — a builder/validator ->failed or ->blocked. Opens the just-renamed
# handoff file in TextMate, the ONE channel proven to reach the founder from a
# launchd-spawned loop: macOS silently drops osascript UI (ma_notify's banner)
# launched without a TCC session, so a background failure surfaced nothing. This
# is an ADDITION alongside ma_notify, never a replacement — the banner still fires
# and costs nothing on the interactive runs where it works. Records the verbatim
# open/raise exit codes to state.log so an attempted open is distinguishable from
# a succeeded one. No-ops (no launch, no audit line) when <file> is absent, and is
# otherwise fully swallowed, so it can never fail the task.
_ml_open_file_for_review() {
  local file="$1" issue="$2" stage="$3" pass="$4"
  [ -e "$file" ] || return 0
  local codes
  codes=$(_ml_open_in_textmate "$file")
  q_log "$issue" "$stage" notify notify null "$pass" "opened-textmate $codes file=$(basename "$file")"
  return 0
}

# _ml_notify_file <message> <issue> <stage> <pass>
# Founder-awareness open for an event with NO natural file to open — an
# environmental deferral (quota / auth / network), where the task was fine and no
# handoff file was produced. Appends a timestamped one-line entry to
# multi-agent/NOTIFICATIONS.md (a gitignored runtime log) and opens THAT file in
# TextMate, the same launchd-reachable channel as _ml_open_file_for_review. The
# open is rate-limited: after an open, further events inside
# MA_NOTIFY_OPEN_THROTTLE_SEC (default 1800 = 30 min) are appended SILENTLY, so a
# deferral storm records every event but never spawns one window per event.
# Mirrors _ml_remind_pending's marker throttle — a NOTIFICATIONS.md.opened marker
# holds the epoch of the last open. Fully swallowed; every entry is still recorded
# even when the open is throttled or fails.
_ml_notify_file() {
  local message="$1" issue="$2" stage="$3" pass="$4"
  local nfile="$MA_ROOT/NOTIFICATIONS.md"
  local marker="${nfile}.opened"
  local interval now last within=0
  interval="${MA_NOTIFY_OPEN_THROTTLE_SEC:-1800}"
  now=$(date +%s)
  mkdir -p "$MA_ROOT"
  printf '%s %s\n' "$(_q_now_local)" "$message" >>"$nfile"

  if [ -f "$marker" ]; then
    last=$(cat "$marker" 2>/dev/null)
    case "$last" in
      '' | *[!0-9]*) last=0 ;;
    esac
    if [ "$((now - last))" -lt "$interval" ]; then
      within=1
    fi
  fi
  if [ "$within" -eq 1 ]; then
    q_log "$issue" "$stage" notify notify null "$pass" "notifications-appended-throttled"
    return 0
  fi

  local codes
  codes=$(_ml_open_in_textmate "$nfile")
  printf '%s\n' "$now" >"$marker"
  q_log "$issue" "$stage" notify notify null "$pass" "notifications-opened-textmate $codes"
  return 0
}

# _ml_grant_pass_override <issue> <slug> <pass>
# Record a cycle-scoped grant sanctioning <pass> past the max-pass ceiling for
# this task: multi-agent/.pm-pass-grants/<issue>-<slug>-pass<N>. This is the
# ONLY writer of a grant in the entire tree (grep confirms it) — it is called
# from exactly one place, the max-pass gate below, and ONLY on the branch where
# the file's own PM-authored pm_approved_pass field matches its pass. The grant
# then lets the OTHER leg of the same pass proceed: a builder brief the PM
# stamped records the grant here, and the validator handoff the builder writes
# — which must NOT carry pm_approved_pass (a worker may never write that field)
# — is honored via the grant instead. This is what closes the per-leg
# stamping gap. The anti-runaway property holds because no worker/loop path other
# than this gate ever mints a grant.
_ml_grant_pass_override() {
  local issue="$1" slug="$2" pass="$3"
  mkdir -p "$MA_ROOT/.pm-pass-grants"
  : >"$MA_ROOT/.pm-pass-grants/${issue}-${slug}-pass${pass}"
}

# _ml_body_has_stop_section <claimed-file>
# Return 0 iff the body carries a STOP-shaped section — a `## ` heading whose
# text (case-insensitively) contains FINDING, STOP, HALTED, BLOCKED, or PREMISE.
# That heading set covers the variants workers have actually written when they
# STOP: "## FINDINGS", "## STOP", "## Premise stale", "## Blocked".
#
# This is the DISCRIMINATOR that splits a postcondition miss in two: a worker
# that appended such a section handed back deliberately (a typed fail-back ->
# .blocked), while one that produced neither a handoff nor findings failed
# silently (-> .failed, the fabricated-success case the postcondition exists to
# catch). Directionality matters: a miss here must fall back to .failed, never
# pass as done, so the scan is deliberately permissive on shape and the caller
# treats "no match" as the pre-existing hard-failure path.
#
# Scope: the file body only — the frontmatter block is skipped so a value there
# can never be read as a heading. Where the brief carries the conventional
# `## Handoff` section (required of every first-pass PM brief), the scan starts
# after it, which is what makes the section "worker-appended": the brief's own
# headings all precede Handoff, so a fail-back brief that itself contains e.g.
# "## Findings" cannot masquerade as a worker STOP. Terser files with no
# `## Handoff` (pass>1 re-scopes, validator/scribe handoffs) are scanned whole,
# so their STOPs are still typed rather than falling through to .failed.
#
# Only h2 (`## `) is scanned. A worker writing `### Findings` is missed and
# degrades to .failed — the safe direction, and what the pre-change `/^## /`
# scan already did. The persona docs mandate no heading level, so this is a
# known, deliberate narrowness rather than an oversight.
#
# The queue's OWN transition footers are excluded before the keyword test.
# q_block appends `## BLOCKED <timestamp>` and q_fail appends
# `## FAILED <timestamp>` at EOF — after any `## Handoff`, so they would
# otherwise read as worker-appended sections, and BLOCKED is in the keyword set.
# A requeued `.blocked.md` (the documented max-pass recovery: PM stamps
# pm_approved_pass and renames back to `.ready.md`) would then carry that footer
# forever and match on every later pass, disabling the discriminator for that
# task. The footers always put a digit immediately after the keyword; a worker
# heading ("## Blocked: missing credentials") never does, so the shape test
# separates them without dropping BLOCKED from the worker keyword set.
_ml_body_has_stop_section() {
  local file="$1"
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/ { fm = 0; body = 1; next }
    fm { next }
    { body = 1 }
    body && /^## Handoff/ { after_handoff = 1; seen_handoff = 1; next }
    body && /^## (BLOCKED|FAILED) [0-9]/ { next }
    body && /^##[[:space:]]/ {
      if (toupper($0) ~ /FINDING|STOP|HALTED|BLOCKED|PREMISE/) {
        if (after_handoff) { found = 1 } else { pre_handoff = 1 }
      }
    }
    END { exit((found || (pre_handoff && !seen_handoff)) ? 0 : 1) }
  ' "$file"
}

# _ml_block_owned <file> <reason> <expected-owner>
# q_block with the stale-owner guard q_fail already applies: if <file>'s current
# frontmatter `owner` is not <expected-owner>, return 1 without blocking or
# logging. ml_tick needs that guard on the block path for the same reason it
# needs it on the fail path — a worker that outlived the reaper's stale-claim
# window must not transition a claim a successor now owns, and a claimed file
# already requeued out from under us must not be resurrected by q_block's
# append-then-rename (q_get on an absent file yields an empty owner, so the
# mismatch catches that case too). q_block itself takes no expected-owner
# parameter and queue.sh is out of scope here, so the guard lives at the call
# site.
_ml_block_owned() {
  local file="$1" reason="$2" expected_owner="$3"
  if [ -n "$expected_owner" ]; then
    local actual_owner
    actual_owner=$(q_get "$file" owner)
    [ "$actual_owner" = "$expected_owner" ] || return 1
  fi
  q_block "$file" "$reason"
}

# ml_tick <persona> <inbox-name> <enforce-max-pass:0|1> <owner-prefix> <repo-root>
# Run exactly one poll tick. Returns 0 on quota-deferred (marker active) /
# idle / lane-busy / lost-race /
# lost-TOCTOU-race (another lane claimed first; see _ml_enforce_single_claim)
# / malformed-frontmatter block (q_claim returned 2; the file is parked as
# .blocked.md) / invalid issue-or-slug (see _ml_valid_issue_slug; the file
# is q_failed before any worktree/branch path is touched) / handled worker
# failure (q_fail recorded it) / worker STOP-with-findings (q_block recorded
# it as a typed fail-back); nonzero only if a queue transition that
# should have recorded the outcome itself failed.
ml_tick() {
  local persona="$1" inbox_name="$2" enforce_max_pass="$3" owner_prefix="$4" repo_root="$5"

  # Skip the whole tick (no scan, no claim) while a quota deferral is active.
  # Fail-open marker semantics live in queue.sh's _q_quota_deferred_active.
  if _q_quota_deferred_active; then
    return 0
  fi

  if _ml_lane_busy "$MA_ROOT"; then
    return 0
  fi

  local inbox_dir="$MA_ROOT/$inbox_name"
  local ready_file
  ready_file=$(_ml_oldest_ready "$inbox_dir")
  [ -n "$ready_file" ] || return 0

  if [ "$enforce_max_pass" = "1" ]; then
    local pass_val
    pass_val=$(q_get "$ready_file" pass)
    case "$pass_val" in
      '' | *[!0-9]*) pass_val=0 ;;
    esac
    if [ "$pass_val" -ge 3 ]; then
      local issue slug pm_approved honored
      issue=$(q_get "$ready_file" issue)
      slug=$(q_get "$ready_file" slug)
      # A PM sanctions a pass past the ceiling with a `pm_approved_pass: N`
      # frontmatter field equal to the file's own `pass`. Two honor paths:
      #   1. This file carries a matching field -> honor AND record a
      #      cycle-scoped grant (via _ml_grant_pass_override) so the OTHER leg
      #      of the same pass is honored too. This is the only grant-writing
      #      path in the tree.
      #   2. A grant for this exact (issue-slug, pass) already exists — recorded
      #      by this pass's earlier leg. The builder-authored handoff feeding
      #      the validator leg cannot legally carry pm_approved_pass (workers
      #      must never write it), so the grant is how the sanction crosses legs
      #      No field required on THIS file.
      # Absent field AND absent grant -> block exactly as before. The
      # anti-runaway property holds because no code path other than the grant
      # writer above (fed only by a human-authored field) sanctions a pass, so
      # the loop cannot authorize its own escalation. A mismatched field
      # (including a stale one from a lower pass) is not honored and does not
      # mint a grant, so a fresh sanction is required for each pass.
      pm_approved=$(q_get "$ready_file" pm_approved_pass)
      honored=0
      if [ -n "$pm_approved" ] && [ "$pm_approved" = "$pass_val" ]; then
        _ml_grant_pass_override "$issue" "$slug" "$pass_val"
        honored=1
      elif [ -e "$MA_ROOT/.pm-pass-grants/${issue}-${slug}-pass${pass_val}" ]; then
        honored=1
      fi
      if [ "$honored" -eq 1 ]; then
        local stage
        stage=$(q_get "$ready_file" stage)
        q_log "$issue" "$stage" "ready" "ready" "null" "$pass_val" "pm-override"
      else
        q_block "$ready_file" "max-pass reached (pass=$pass_val, limit 3); blocked by ${persona}-loop before claim" || return 1
        ma_notify "multi-agent: issue $issue blocked at max-pass ($pass_val) by ${persona}-loop"
        _ml_open_file_for_review "${ready_file%.ready.md}.blocked.md" "$issue" "$persona" "$pass_val"
        return 0
      fi
    fi
  fi

  local owner="${owner_prefix}-$$"
  local claimed_file
  claimed_file=$(q_claim "$ready_file" "$owner") || return 0

  _ml_enforce_single_claim "$claimed_file" || return 0

  local issue slug claimed_pass worktree_dir
  issue=$(q_get "$claimed_file" issue)
  slug=$(q_get "$claimed_file" slug)
  claimed_pass=$(q_get "$claimed_file" pass)

  # Validate before either fork below touches a worktree/branch path,
  # so the guard is uniform across the WORKER_CMD test path and the live
  # path (and is exercised by tests without needing a real worker).
  if ! _ml_valid_issue_slug "$issue" "$slug"; then
    q_fail "$claimed_file" "invalid issue/slug in frontmatter (issue must be digits, slug must be [a-z0-9-]): issue='$issue' slug='$slug'" "$owner" || return 1
    _ml_open_file_for_review "${claimed_file%.claimed.md}.failed.md" "$issue" "$persona" "$claimed_pass"
    return 0
  fi

  worktree_dir=$(_ml_worktree_path "$repo_root" "$issue" "$slug")

  if [ -z "${WORKER_CMD:-}" ]; then
    worktree_dir=$(_ml_ensure_worktree "$repo_root" "$issue" "$slug")
    _ml_bootstrap_worktree "$worktree_dir"
  fi

  # Clear any stale push-violation marker for this task before the worker runs,
  # so a marker present at postcondition time can only have come from THIS run
  # (ml_guarded_push writes it when a scribe worker attempts a main-push).
  if [ "$persona" = "scribe" ]; then
    rm -f -- "$MA_ROOT/.push-violations/${issue}-${slug}.violation"
  fi

  local log_file status
  log_file=$(_ml_run_worker "$persona" "$claimed_file" "$repo_root" "$worktree_dir" "$issue" "$slug")
  status=$?

  if [ "$status" -eq 0 ]; then
    # A clean exit is necessary but not sufficient: the worker must also
    # have produced its expected downstream handoff. A missing or malformed
    # handoff never records a `done` that has no artifact behind it; it routes
    # to a terminal state chosen by _ml_check_postcondition's typing — .blocked
    # for a deliberate hand-back (rc 2), .failed for a silent miss (rc 1).
    local pc_reason pc_rc=0
    pc_reason=$(_ml_check_postcondition "$persona" "$issue" "$slug" "$claimed_pass" "$claimed_file") || pc_rc=$?
    if [ "$pc_rc" -ne 0 ]; then
      # A validator that wrote BOTH downstream handoffs violates the contract:
      # the postcondition already failed the claim, but the two live .ready.md
      # strays a later tick could still claim must be neutralized as part of
      # routing to .failed.md. Fire only when both are present (exactly the
      # violated-contract case) so single-handoff failure paths are unchanged.
      if [ "$persona" = "validator" ] \
        && [ -e "$MA_ROOT/scribe-notes/${issue}-${slug}.ready.md" ] \
        && [ -e "$MA_ROOT/builder-tasks/${issue}-${slug}.ready.md" ]; then
        _ml_neutralize_stray_handoffs "$issue" "$slug"
      fi
      # A worker that appended findings and handed back did its job: it hit a
      # broken premise or a blocker outside its brief and STOPped, which is the
      # contract, not a malfunction. Record that as the typed fail-back it is —
      # .blocked, the queue's existing "needs a human/PM decision" terminal
      # state — with the findings preserved in the body. Whether it also managed
      # to exit nonzero is not the signal; a worker asked to both write findings
      # and exit nonzero has failed the exit-code half fifteen times, so the
      # findings are what the loop reads.
      #
      # A miss with NO findings stays .failed, unchanged. That is the whole
      # safety property: a worker that fabricates success (exits 0, writes no
      # handoff, explains nothing) is still dead-lettered as a failure.
      if [ "$pc_rc" -eq 2 ]; then
        _ml_block_owned "$claimed_file" \
          "worker STOPped with findings (fail-back — needs re-scope): $pc_reason" "$owner" || return 1
        ma_notify "multi-agent: issue $issue ${persona} STOPped with findings (fail-back) - $pc_reason"
        _ml_open_file_for_review "${claimed_file%.claimed.md}.blocked.md" "$issue" "$persona" "$claimed_pass"
        return 0
      fi
      q_fail "$claimed_file" "postcondition failed after worker exit 0: $pc_reason" "$owner" || return 1
      ma_notify "multi-agent: issue $issue ${persona} postcondition failed - $pc_reason"
      _ml_open_file_for_review "${claimed_file%.claimed.md}.failed.md" "$issue" "$persona" "$claimed_pass"
      return 0
    fi
    q_done "$claimed_file" "$owner" || return 1
    # Scribe success: the postcondition just confirmed a freshly written
    # merge-approval pending file. Open it in the founder's review editor now,
    # at create time — approvals are session-less, so nothing else surfaces the
    # file for a human to act on. This branch runs on the single tick that
    # created the pending (the scribe note is claimed once), never on the
    # reminder re-scans in ml_process_approvals, so the window opens exactly once.
    if [ "$persona" = "scribe" ]; then
      _ml_open_pending_for_review "$issue" "$slug" "$claimed_pass"
    fi
  else
    local tail_lines
    tail_lines=$(tail -n 20 "$log_file" 2>/dev/null)
    # An environmental fault is a defer, not a failure: the task was fine, the
    # environment was unavailable (distinct from a worker that failed on its own
    # merits). The signature table classifies quota / auth / network; all three
    # requeue WITHOUT counting a retry and set the shared defer marker so every
    # subsequent tick skips until it expires, and do not dead-letter. Only quota
    # has a parseable reset clock; auth/network use a fixed 30-minute default.
    local env_class
    if env_class=$(_ml_classify_env_failure "$tail_lines"); then
      # Environmental deferrals have no handoff file to open, so they route the
      # founder-awareness signal through NOTIFICATIONS.md (throttled), in addition
      # to the ma_notify banner. The launchd-critical path is the file open, not
      # the banner osascript silently drops for background jobs.
      local defer_epoch human defer_msg
      case "$env_class" in
        quota)
          defer_epoch=$(_ml_quota_reset_epoch "$tail_lines")
          q_requeue_noretry "$claimed_file" "quota-deferred" || return 1
          _q_set_quota_defer "$defer_epoch"
          human=$(date -r "$defer_epoch" '+%Y-%m-%d %I:%M%p' 2>/dev/null || printf 'epoch %s' "$defer_epoch")
          defer_msg="multi-agent: quota exhausted — loops deferred until $human"
          ;;
        auth)
          defer_epoch=$(( $(date +%s) + 1800 ))
          q_requeue_noretry "$claimed_file" "auth-deferred" || return 1
          _q_set_quota_defer "$defer_epoch"
          defer_msg="multi-agent: worker not authenticated (run /login) — loops deferred 30 min"
          ;;
        network)
          defer_epoch=$(( $(date +%s) + 1800 ))
          q_requeue_noretry "$claimed_file" "network-deferred" || return 1
          _q_set_quota_defer "$defer_epoch"
          defer_msg="multi-agent: network fault reaching the API — loops deferred 30 min"
          ;;
      esac
      ma_notify "$defer_msg"
      _ml_notify_file "$defer_msg" "$issue" "$persona" "$claimed_pass"
      return 0
    fi
    q_fail "$claimed_file" "worker exited $status; last 20 log lines:
$tail_lines" "$owner" || return 1
    # A genuine worker failure was previously silent — no banner, no file — which
    # is the exact gap the founder hit (failures with zero visible signal). Give
    # it both channels: the ma_notify banner (works on interactive runs) and the
    # launchd-proven TextMate open of the .failed.md.
    ma_notify "multi-agent: issue $issue ${persona} worker failed (exit $status)"
    _ml_open_file_for_review "${claimed_file%.claimed.md}.failed.md" "$issue" "$persona" "$claimed_pass"
  fi

  return 0
}
