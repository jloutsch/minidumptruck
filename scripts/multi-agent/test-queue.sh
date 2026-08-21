#!/usr/bin/env bash
# Test suite for queue.sh: race, requeue, dead-letter, frontmatter round-trip,
# and state.log transitions. Runs entirely inside a mktemp sandbox; never
# touches the repo's real multi-agent/ directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
# shellcheck disable=SC1091 # path is resolved at runtime; correctness verified by this suite passing
source "$SCRIPT_DIR/queue.sh"
# shellcheck source=./loop-lib.sh
# shellcheck disable=SC1091 # path is resolved at runtime; correctness verified by this suite passing
source "$SCRIPT_DIR/loop-lib.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ma-queue-test.XXXXXX")"
cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

export MA_ROOT="$TMP_ROOT"
mkdir -p "$MA_ROOT/builder-tasks" "$MA_ROOT/validator-notes" "$MA_ROOT/scribe-notes"

NOTIFY_LOG="$TMP_ROOT/notify.log"
export NOTIFY_LOG
ma_notify_stub() {
  printf '%s\n' "$1" >>"$NOTIFY_LOG"
}
export MA_NOTIFY_CMD=ma_notify_stub
# reaper.sh runs as a child bash process (not sourced), so the stub must be
# exported as a function for it to be visible there too.
export -f ma_notify_stub

# Founder-awareness opens (loop-lib _ml_open_file_for_review / _ml_notify_file /
# _ml_open_pending_for_review) shell out to `open -a TextMate`. Every failed /
# blocked / deferral / scribe-success tick now attempts one, and many tests drive
# those ticks without caring about the open. A fake `open` (plus an `osascript`
# tripwire — the raise must NEVER go through the TCC-blocked Apple-event path)
# sits ahead of the real PATH for the WHOLE run, so no test can launch a real GUI
# app. Tests that assert on the open reset $OPEN_STUB_LOG and re-write the stub
# with specific exit codes via _write_open_stub; every other test simply never
# opens TextMate. Both the default here and _write_open_stub write the same file.
OPEN_STUB_DIR="$TMP_ROOT/open-stub-bin"
OPEN_STUB_LOG="$TMP_ROOT/open-invocations.log"
OSASCRIPT_STUB_LOG="$TMP_ROOT/osascript-invocations.log"
export OPEN_STUB_LOG OSASCRIPT_STUB_LOG
mkdir -p "$OPEN_STUB_DIR"
cat >"$OPEN_STUB_DIR/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$OPEN_STUB_LOG"
exit 0
EOF
chmod +x "$OPEN_STUB_DIR/open"
cat >"$OPEN_STUB_DIR/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$OSASCRIPT_STUB_LOG"
exit 0
EOF
chmod +x "$OPEN_STUB_DIR/osascript"
export PATH="$OPEN_STUB_DIR:$PATH"

REAPER="$SCRIPT_DIR/reaper.sh"

# The launchd label prefix install-loops.sh/uninstall-loops.sh use when
# --label-prefix is not given. Asserted below rather than hardcoded at each use
# site: export-kit.sh rewrites this single anchored line together with the
# matching lines in the two installers, so a ported suite asserts the PORTED
# default and the three files cannot drift apart. Keep it a plain literal
# assignment on one line.
MA_DEFAULT_LABEL_PREFIX="com.minidumptruck"

pass() {
  printf 'PASS: %s\n' "$1"
}
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Shared lint-compliant brief body. queue.sh's enqueue lint requires four
# markers in every original pass:1 builder brief — the Premise verification
# line and the ## Gates / ## Authorizations roster / ## Handoff headings. Every
# claim-reaching pass:1 builder fixture below uses this one body so a normal
# claim still exercises its real path instead of tripping the lint. The lint is
# presence-only; each test layers its own frontmatter/state.log/outcome
# assertions on top and none asserts on this body text.
COMPLIANT_BRIEF_BODY='Task body.

**Premise verification (PM, 2026-07-05):** fixture premise line.

## Gates
Fixture gate.

## Authorizations roster
- AUTHORIZED: the fixture change.

## Handoff
Fixture handoff.'

# Filename base matches the frontmatter issue-slug (634-totp-backup-codes) so
# these fixtures satisfy the name-integrity lint the way a real queue file does.
READY_FILE="$MA_ROOT/builder-tasks/634-totp-backup-codes.ready.md"
CLAIMED_FILE="$MA_ROOT/builder-tasks/634-totp-backup-codes.claimed.md"
FAILED_FILE="$MA_ROOT/builder-tasks/634-totp-backup-codes.failed.md"

test_race() {
  cat >"$READY_FILE" <<EOF
---
issue: 634
slug: totp-backup-codes
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF

  local n=10
  local i
  for i in $(seq 1 "$n"); do
    (
      if claimed_path=$(q_claim "$READY_FILE" "claimer-$i"); then
        printf 'OK claimer-%s %s\n' "$i" "$claimed_path" >"$TMP_ROOT/result-$i"
      else
        printf 'LOST\n' >"$TMP_ROOT/result-$i"
      fi
    ) &
  done
  wait

  local ok_count=0
  local winner=""
  for i in $(seq 1 "$n"); do
    if grep -q '^OK' "$TMP_ROOT/result-$i"; then
      ok_count=$((ok_count + 1))
      winner=$(awk '{print $2}' "$TMP_ROOT/result-$i")
    fi
  done

  [ "$ok_count" -eq 1 ] || fail "race: expected exactly 1 winner, got $ok_count"
  [ -f "$CLAIMED_FILE" ] || fail "race: claimed file missing"
  [ ! -f "$READY_FILE" ] || fail "race: ready file still present"

  local stamped_owner
  stamped_owner=$(q_get "$CLAIMED_FILE" owner)
  [ "$stamped_owner" = "$winner" ] || fail "race: stamped owner '$stamped_owner' != winner '$winner'"

  pass "race: exactly one of $n parallel claimers won ($stamped_owner)"
}

test_requeue() {
  q_requeue "$CLAIMED_FILE"
  [ -f "$READY_FILE" ] || fail "requeue: ready file not restored"
  [ ! -f "$CLAIMED_FILE" ] || fail "requeue: claimed file still present"

  local retries
  retries=$(q_get "$READY_FILE" retries)
  [ "$retries" = "1" ] || fail "requeue: expected retries=1, got '$retries'"

  local claimed_path
  claimed_path=$(q_claim "$READY_FILE" "claimer-requeue") || fail "requeue: could not re-claim after requeue"
  [ "$claimed_path" = "$CLAIMED_FILE" ] || fail "requeue: unexpected claimed path '$claimed_path'"

  pass "requeue: retries=1 after requeue, re-claimed successfully"
}

test_fail() {
  q_fail "$CLAIMED_FILE" "simulated failure reason"
  [ -f "$FAILED_FILE" ] || fail "dead-letter: failed file missing"
  grep -q "simulated failure reason" "$FAILED_FILE" || fail "dead-letter: reason text missing from body"

  local other_states
  other_states=$(find "$MA_ROOT/builder-tasks" -maxdepth 1 -name '634-totp-backup-codes.*.md' ! -name '634-totp-backup-codes.failed.md' | wc -l | tr -d ' ')
  [ "$other_states" -eq 0 ] || fail "dead-letter: other state file(s) remain"

  pass "dead-letter: failed file created with reason, no other state file remains"
}

test_roundtrip() {
  local issue slug stage pass_val retries owner updated
  issue=$(q_get "$FAILED_FILE" issue)
  slug=$(q_get "$FAILED_FILE" slug)
  stage=$(q_get "$FAILED_FILE" stage)
  pass_val=$(q_get "$FAILED_FILE" pass)
  retries=$(q_get "$FAILED_FILE" retries)
  owner=$(q_get "$FAILED_FILE" owner)
  updated=$(q_get "$FAILED_FILE" updated)

  [ "$issue" = "634" ] || fail "roundtrip: issue changed, got '$issue'"
  [ "$slug" = "totp-backup-codes" ] || fail "roundtrip: slug changed, got '$slug'"
  [ "$stage" = "builder" ] || fail "roundtrip: stage changed, got '$stage'"
  [ "$pass_val" = "1" ] || fail "roundtrip: pass changed, got '$pass_val'"
  [ "$retries" = "1" ] || fail "roundtrip: expected retries=1, got '$retries'"
  [ "$owner" = "claimer-requeue" ] || fail "roundtrip: expected owner=claimer-requeue, got '$owner'"
  [ "$updated" != "2026-07-05T14:03:00Z" ] || fail "roundtrip: updated timestamp was never refreshed"

  pass "roundtrip: issue/slug/stage/pass stable; retries/owner/updated reflect transitions"
}

test_state_log() {
  local log="$MA_ROOT/state.log"
  [ -f "$log" ] || fail "state.log: file missing"

  local line_count
  line_count=$(wc -l <"$log" | tr -d ' ')
  [ "$line_count" -eq 4 ] || fail "state.log: expected 4 lines, got $line_count"

  local expected=("ready->claimed" "claimed->ready" "ready->claimed" "claimed->failed")
  local i=0
  local logline transition
  while IFS= read -r logline; do
    transition=$(printf '%s\n' "$logline" | awk '{for (j=1;j<=NF;j++) if ($j ~ /->/) print $j}')
    [ "$transition" = "${expected[$i]}" ] || fail "state.log line $((i + 1)): expected '${expected[$i]}', got '$transition'"
    i=$((i + 1))
  done <"$log"

  pass "state.log: 4 transitions logged in order (${expected[*]})"
}

TOCTOU_CLAIMED_A="$MA_ROOT/builder-tasks/300-toctou-a.claimed.md"
TOCTOU_CLAIMED_B="$MA_ROOT/validator-notes/301-toctou-b.claimed.md"
TOCTOU_READY_B="$MA_ROOT/validator-notes/301-toctou-b.ready.md"

test_enforce_single_claim() {
  cat >"$TOCTOU_CLAIMED_A" <<'EOF'
---
issue: 900
slug: toctou-a
stage: builder
pass: 1
retries: 0
owner: claimer-a
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  cat >"$TOCTOU_CLAIMED_B" <<'EOF'
---
issue: 901
slug: toctou-b
stage: validator
pass: 1
retries: 0
owner: claimer-b
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  # V4: the re-scan is now a deterministic tiebreak (lexically-smallest
  # path wins), not an unconditional "requeue ours". $TOCTOU_CLAIMED_A
  # (builder-tasks) sorts smaller than $TOCTOU_CLAIMED_B (validator-notes),
  # so "ours" here is B -- the one that must back off.
  local status=0
  _ml_enforce_single_claim "$TOCTOU_CLAIMED_B" || status=$?
  [ "$status" -ne 0 ] || fail "toctou: expected nonzero when 2 claims are in flight across inboxes"

  [ -f "$TOCTOU_READY_B" ] || fail "toctou: our own claim was not requeued to ready"
  [ ! -f "$TOCTOU_CLAIMED_B" ] || fail "toctou: our own claimed file still present"
  [ -f "$TOCTOU_CLAIMED_A" ] || fail "toctou: the other lane's claim was touched"

  local retries
  retries=$(q_get "$TOCTOU_READY_B" retries)
  [ "$retries" = "1" ] || fail "toctou: expected retries=1 after requeue, got '$retries'"

  rm -f -- "$TOCTOU_READY_B" "$TOCTOU_CLAIMED_A"

  pass "toctou: post-claim re-scan requeues our claim when another lane's claim is also in flight, leaves the other alone"
}

REAP_CLAIMED_REQUEUE="$MA_ROOT/builder-tasks/100-reaper-requeue.claimed.md"
REAP_READY_REQUEUE="$MA_ROOT/builder-tasks/100-reaper-requeue.ready.md"

test_reaper_requeue() {
  cat >"$REAP_CLAIMED_REQUEUE" <<'EOF'
---
issue: 700
slug: reaper-requeue
stage: builder
pass: 1
retries: 0
owner: claimer-100
updated: 2000-01-01T00:00:00Z
---
Task body.
EOF

  bash "$REAPER" || fail "reaper requeue: invocation exited nonzero"

  [ -f "$REAP_READY_REQUEUE" ] || fail "reaper requeue: expected ready file, none found"
  [ ! -f "$REAP_CLAIMED_REQUEUE" ] || fail "reaper requeue: claimed file still present"

  local retries
  retries=$(q_get "$REAP_READY_REQUEUE" retries)
  [ "$retries" = "1" ] || fail "reaper requeue: expected retries=1, got '$retries'"

  pass "reaper: stale claim (retries=0) requeued with retries incremented to 1"
}

REAP_CLAIMED_DEADLETTER="$MA_ROOT/validator-notes/101-reaper-deadletter.claimed.md"
REAP_FAILED_DEADLETTER="$MA_ROOT/validator-notes/101-reaper-deadletter.failed.md"

test_reaper_deadletter() {
  cat >"$REAP_CLAIMED_DEADLETTER" <<'EOF'
---
issue: 701
slug: reaper-deadletter
stage: validator
pass: 2
retries: 3
owner: claimer-101
updated: 2000-01-01T00:00:00Z
---
Task body.
EOF

  : >"$NOTIFY_LOG"

  bash "$REAPER" || fail "reaper deadletter: invocation exited nonzero"

  [ -f "$REAP_FAILED_DEADLETTER" ] || fail "reaper deadletter: expected failed file, none found"
  [ ! -f "$REAP_CLAIMED_DEADLETTER" ] || fail "reaper deadletter: claimed file still present"
  grep -q "reaper" "$REAP_FAILED_DEADLETTER" || fail "reaper deadletter: reason does not mention the reaper"
  grep -q "701" "$NOTIFY_LOG" || fail "reaper deadletter: notification missing issue number"
  grep -qi "dead-letter" "$NOTIFY_LOG" || fail "reaper deadletter: notification missing dead-letter wording"

  pass "reaper: retries>=3 claim dead-lettered with reason and human notification"
}

# #918: a builder killed AFTER writing its validator handoff but BEFORE its own
# queue transition leaves a stale claim while the handoff is already live. The
# reaper must supersede the claim (not requeue/dead-letter it), or a duplicate
# brief is minted alongside the handoff -> dual-handoff postcondition failure.
REAP_CLAIMED_SUPERSEDE="$MA_ROOT/builder-tasks/702-reaper-supersede.claimed.md"
REAP_SUPERSEDED_SUPERSEDE="$MA_ROOT/builder-tasks/702-reaper-supersede.superseded.md"
REAP_READY_SUPERSEDE="$MA_ROOT/builder-tasks/702-reaper-supersede.ready.md"
REAP_DS_HANDOFF_SUPERSEDE="$MA_ROOT/validator-notes/702-reaper-supersede.ready.md"

test_reaper_supersede_dual_handoff() {
  cat >"$REAP_CLAIMED_SUPERSEDE" <<'EOF'
---
issue: 702
slug: reaper-supersede
stage: builder
pass: 1
retries: 0
owner: claimer-702
updated: 2000-01-01T00:00:00Z
---
Task body.
EOF
  # The worker wrote its downstream validator handoff before it was killed.
  cat >"$REAP_DS_HANDOFF_SUPERSEDE" <<'EOF'
---
issue: 702
slug: reaper-supersede
stage: validator
pass: 1
retries: 0
owner: null
updated: 2000-01-01T00:00:00Z
---
Validator handoff body.
EOF

  : >"$NOTIFY_LOG"
  bash "$REAPER" || fail "reaper supersede: invocation exited nonzero"

  [ -f "$REAP_SUPERSEDED_SUPERSEDE" ] || fail "reaper supersede: expected .superseded.md, none found"
  [ ! -f "$REAP_CLAIMED_SUPERSEDE" ] || fail "reaper supersede: claimed file still present"
  [ ! -f "$REAP_READY_SUPERSEDE" ] || fail "reaper supersede: claim was requeued to .ready (dual-handoff) instead of superseded"
  [ -f "$REAP_DS_HANDOFF_SUPERSEDE" ] || fail "reaper supersede: downstream handoff was disturbed"
  grep -q "702" "$NOTIFY_LOG" || fail "reaper supersede: notification missing issue number"
  grep -qi "supersede" "$NOTIFY_LOG" || fail "reaper supersede: notification missing supersede wording"

  pass "reaper: stale builder claim with an existing downstream handoff is superseded, not requeued (#918)"
}

REAP_CLAIMED_FRESH="$MA_ROOT/builder-tasks/102-reaper-fresh.claimed.md"

test_reaper_fresh() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat >"$REAP_CLAIMED_FRESH" <<EOF
---
issue: 702
slug: reaper-fresh
stage: builder
pass: 1
retries: 0
owner: claimer-102
updated: $now
---
Task body.
EOF

  local before_log_lines after_log_lines
  before_log_lines=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')

  bash "$REAPER" || fail "reaper fresh: invocation exited nonzero"

  [ -f "$REAP_CLAIMED_FRESH" ] || fail "reaper fresh: claimed file was touched (missing)"
  after_log_lines=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')
  [ "$after_log_lines" -eq "$before_log_lines" ] || fail "reaper fresh: state.log grew for a fresh claim"

  pass "reaper: fresh claim (recent updated, default timeouts) left untouched"
}

REAP_CLAIMED_SCRIBE_FRESH="$MA_ROOT/scribe-notes/103-reaper-scribe-fresh.claimed.md"

test_reaper_fresh_last_inbox_exit_code() {
  # A fresh claim in scribe-notes — the LAST inbox the reaper processes —
  # with no claimed files anywhere else. The final staleness check
  # evaluating false must not leak into the reaper's exit status.
  local leftovers
  leftovers=$(find "$MA_ROOT/builder-tasks" "$MA_ROOT/validator-notes" -maxdepth 1 -name '*.claimed.md' | wc -l | tr -d ' ')
  [ "$leftovers" -eq 1 ] || fail "reaper fresh last inbox: expected only the fresh builder claim as precondition, found $leftovers claimed files"
  rm -f -- "$REAP_CLAIMED_FRESH"

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat >"$REAP_CLAIMED_SCRIBE_FRESH" <<EOF
---
issue: 703
slug: reaper-scribe-fresh
stage: scribe
pass: 1
retries: 0
owner: claimer-103
updated: $now
---
Task body.
EOF

  local status=0
  bash "$REAPER" || status=$?
  [ "$status" -eq 0 ] || fail "reaper fresh last inbox: expected exit 0, got $status"
  [ -f "$REAP_CLAIMED_SCRIBE_FRESH" ] || fail "reaper fresh last inbox: claimed file was touched (missing)"

  pass "reaper: fresh claim in last-processed inbox (scribe-notes) exits 0, untouched"
}

MALFORMED_READY="$MA_ROOT/builder-tasks/400-malformed.ready.md"
MALFORMED_CLAIMED="$MA_ROOT/builder-tasks/400-malformed.claimed.md"
MALFORMED_BLOCKED="$MA_ROOT/builder-tasks/400-malformed.blocked.md"

test_claim_malformed_frontmatter() {
  # Missing the "updated:" key entirely -- as a human-authored ready file
  # might be.
  cat >"$MALFORMED_READY" <<'EOF'
---
issue: 902
slug: malformed
stage: builder
pass: 1
retries: 0
owner: null
---
Task body.
EOF

  : >"$NOTIFY_LOG"

  local status=0
  q_claim "$MALFORMED_READY" "claimer-malformed" >/dev/null || status=$?

  [ "$status" -eq 2 ] || fail "malformed frontmatter: expected q_claim to return 2, got $status"
  [ -f "$MALFORMED_BLOCKED" ] || fail "malformed frontmatter: expected blocked file, none found"
  [ ! -f "$MALFORMED_CLAIMED" ] || fail "malformed frontmatter: claimed file still present"
  [ ! -f "$MALFORMED_READY" ] || fail "malformed frontmatter: ready file still present"

  grep -q "updated" "$MALFORMED_BLOCKED" || fail "malformed frontmatter: blocked reason doesn't name the missing key"
  grep -q "400-malformed" "$NOTIFY_LOG" || fail "malformed frontmatter: notification missing file reference"
  grep -qi "blocked" "$NOTIFY_LOG" || fail "malformed frontmatter: notification missing 'blocked' wording"

  pass "malformed frontmatter: missing 'updated' key -> q_claim blocks the file, notifies, returns 2 (never churns forever)"
}

# --- Enqueue brief-content lint (queue.sh _q_brief_lint_applies /
# _q_missing_brief_markers, enforced in q_claim) ---
#
# Directional contract for the lint: a compliant original PM builder brief (all
# four markers, no origin) claims normally (positive), a brief missing a marker
# is parked as .blocked.md naming the marker (negative), and an origin-carrying
# fail-back with none of the markers is exempt and claims normally (exemption).

BRIEF_LINT_READY_OK="$MA_ROOT/builder-tasks/460-brief-lint-ok.ready.md"
BRIEF_LINT_CLAIMED_OK="$MA_ROOT/builder-tasks/460-brief-lint-ok.claimed.md"

test_brief_lint_compliant_claims() {
  cat >"$BRIEF_LINT_READY_OK" <<'EOF'
---
issue: 460
slug: brief-lint-ok
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
# Builder brief

**Premise verification (PM, 2026-07-08):** evidence line.

## Gates
Run the tests.

## Authorizations roster
- AUTHORIZED: the change.

## Handoff
validator-notes/460-brief-lint-ok.ready.md
EOF

  local status=0 claimed_path
  claimed_path=$(q_claim "$BRIEF_LINT_READY_OK" "claimer-lint-ok") || status=$?
  [ "$status" -eq 0 ] || fail "brief lint compliant: expected claim to succeed, got $status"
  [ "$claimed_path" = "$BRIEF_LINT_CLAIMED_OK" ] || fail "brief lint compliant: unexpected claimed path '$claimed_path'"
  [ -f "$BRIEF_LINT_CLAIMED_OK" ] || fail "brief lint compliant: claimed file missing"

  rm -f -- "$BRIEF_LINT_CLAIMED_OK"

  pass "brief lint compliant: builder brief with all four markers + no origin claims normally"
}

BRIEF_LINT_READY_BAD="$MA_ROOT/builder-tasks/461-brief-lint-bad.ready.md"
BRIEF_LINT_CLAIMED_BAD="$MA_ROOT/builder-tasks/461-brief-lint-bad.claimed.md"
BRIEF_LINT_BLOCKED_BAD="$MA_ROOT/builder-tasks/461-brief-lint-bad.blocked.md"

test_brief_lint_missing_marker_blocks() {
  # Missing only '## Authorizations roster'; the other three markers present.
  cat >"$BRIEF_LINT_READY_BAD" <<'EOF'
---
issue: 461
slug: brief-lint-bad
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
# Builder brief

**Premise verification (PM, 2026-07-08):** evidence line.

## Gates
Run the tests.

## Handoff
validator-notes/461-brief-lint-bad.ready.md
EOF

  : >"$NOTIFY_LOG"

  local status=0
  q_claim "$BRIEF_LINT_READY_BAD" "claimer-lint-bad" >/dev/null || status=$?

  [ "$status" -eq 2 ] || fail "brief lint missing marker: expected q_claim to return 2, got $status"
  [ -f "$BRIEF_LINT_BLOCKED_BAD" ] || fail "brief lint missing marker: expected blocked file, none found"
  [ ! -f "$BRIEF_LINT_CLAIMED_BAD" ] || fail "brief lint missing marker: claimed file still present"
  [ ! -f "$BRIEF_LINT_READY_BAD" ] || fail "brief lint missing marker: ready file still present"

  grep -q "Authorizations roster" "$BRIEF_LINT_BLOCKED_BAD" || fail "brief lint missing marker: block reason doesn't name the missing marker"
  grep -q "461-brief-lint-bad" "$NOTIFY_LOG" || fail "brief lint missing marker: notification missing file reference"
  grep -qi "blocked" "$NOTIFY_LOG" || fail "brief lint missing marker: notification missing 'blocked' wording"

  rm -f -- "$BRIEF_LINT_BLOCKED_BAD"

  pass "brief lint missing marker: builder brief missing '## Authorizations roster' -> blocked naming it, notified, returns 2"
}

BRIEF_LINT_READY_EXEMPT="$MA_ROOT/builder-tasks/462-brief-lint-exempt.ready.md"
BRIEF_LINT_CLAIMED_EXEMPT="$MA_ROOT/builder-tasks/462-brief-lint-exempt.claimed.md"

test_brief_lint_origin_exempt_claims() {
  # A worker/scribe-authored fail-back carrying origin, lacking the Premise line
  # and every section marker, yet must claim normally (exempt — it traces to an
  # already-linted parent brief). pass is deliberately 1 so origin is the ONLY
  # thing exempting it: were the origin check dropped, this pass-1 brief would
  # block, so the test isolates the origin exemption rather than riding on the
  # pass > 1 exemption.
  cat >"$BRIEF_LINT_READY_EXEMPT" <<'EOF'
---
issue: 462
slug: brief-lint-exempt
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
origin: scribe-post-review-fix
---
# Fail-back fix brief

## The single required change
Do the thing.
EOF

  local status=0 claimed_path
  claimed_path=$(q_claim "$BRIEF_LINT_READY_EXEMPT" "claimer-lint-exempt") || status=$?
  [ "$status" -eq 0 ] || fail "brief lint exempt: expected claim to succeed, got $status"
  [ "$claimed_path" = "$BRIEF_LINT_CLAIMED_EXEMPT" ] || fail "brief lint exempt: unexpected claimed path '$claimed_path'"
  [ -f "$BRIEF_LINT_CLAIMED_EXEMPT" ] || fail "brief lint exempt: claimed file missing"

  rm -f -- "$BRIEF_LINT_CLAIMED_EXEMPT"

  pass "brief lint exempt: builder fail-back with origin (pass 1) + no markers claims normally (origin exemption)"
}

BRIEF_LINT_READY_PASSN="$MA_ROOT/builder-tasks/463-brief-lint-passn.ready.md"
BRIEF_LINT_CLAIMED_PASSN="$MA_ROOT/builder-tasks/463-brief-lint-passn.claimed.md"

test_brief_lint_passN_exempt_claims() {
  # A terse pass > 1 re-scope brief with NO origin field and none of the four
  # markers. It must claim normally: the lint only gates original first-pass PM
  # briefs, and a pass-N re-scope traces to an already-linted parent. pass is 2
  # and origin is absent so this isolates the pass exemption: were the pass == 1
  # check dropped, this brief would block. Terse pass-N re-scopes without origin
  # are exactly the historical corpus shape the v1 scope wrongly captured.
  cat >"$BRIEF_LINT_READY_PASSN" <<'EOF'
---
issue: 463
slug: brief-lint-passn
stage: builder
pass: 2
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
# Re-scope brief

## The single required change
Do the other thing.
EOF

  local status=0 claimed_path
  claimed_path=$(q_claim "$BRIEF_LINT_READY_PASSN" "claimer-lint-passn") || status=$?
  [ "$status" -eq 0 ] || fail "brief lint passN: expected claim to succeed, got $status"
  [ "$claimed_path" = "$BRIEF_LINT_CLAIMED_PASSN" ] || fail "brief lint passN: unexpected claimed path '$claimed_path'"
  [ -f "$BRIEF_LINT_CLAIMED_PASSN" ] || fail "brief lint passN: claimed file missing"

  rm -f -- "$BRIEF_LINT_CLAIMED_PASSN"

  pass "brief lint passN: pass>1 re-scope with no origin + no markers claims normally (pass exemption)"
}

# --- Name-integrity lint (queue.sh _q_name_integrity_applies /
# _q_name_integrity_violation, enforced in q_claim) ---
#
# Directional contract: a builder brief whose filename base AND every
# Handoff-section path cohere with its own frontmatter issue-slug claims
# normally (positive); a filename base that disagrees, or a Handoff path naming
# a different issue-slug (the 514-616 phantom-chain shape), is parked as
# .blocked.md naming both values (negatives). Unlike the marker lint,
# name-integrity has NO pass>1 / origin: exemption — an exempt-from-markers
# brief with a mismatched name still blocks (names must always cohere).

NAME_INT_READY_OK="$MA_ROOT/builder-tasks/470-name-ok.ready.md"
NAME_INT_CLAIMED_OK="$MA_ROOT/builder-tasks/470-name-ok.claimed.md"

test_name_integrity_coherent_claims() {
  # Filename base == issue-slug AND the Handoff path names the same base.
  cat >"$NAME_INT_READY_OK" <<'EOF'
---
issue: 470
slug: name-ok
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.

**Premise verification (PM, 2026-07-08):** evidence line.

## Gates
Run the tests.

## Authorizations roster
- AUTHORIZED: the change.

## Handoff
`<REPO ROOT>/multi-agent/validator-notes/470-name-ok.ready.md` per convention.
EOF

  local status=0 claimed_path
  claimed_path=$(q_claim "$NAME_INT_READY_OK" "claimer-name-ok") || status=$?
  [ "$status" -eq 0 ] || fail "name-integrity coherent: expected claim to succeed, got $status"
  [ "$claimed_path" = "$NAME_INT_CLAIMED_OK" ] || fail "name-integrity coherent: unexpected claimed path '$claimed_path'"
  [ -f "$NAME_INT_CLAIMED_OK" ] || fail "name-integrity coherent: claimed file missing"

  rm -f -- "$NAME_INT_CLAIMED_OK"
  pass "name-integrity coherent: filename base and Handoff path both match frontmatter issue-slug -> claims normally"
}

NAME_INT_READY_FN="$MA_ROOT/builder-tasks/999-name-x.ready.md"
NAME_INT_BLOCKED_FN="$MA_ROOT/builder-tasks/999-name-x.blocked.md"

test_name_integrity_filename_mismatch_blocks() {
  # Filename base "999-name-x" disagrees with frontmatter issue-slug
  # "471-name-x". All four markers are present, so the block is the
  # name-integrity check firing, not the marker lint.
  cat >"$NAME_INT_READY_FN" <<EOF
---
issue: 471
slug: name-x
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF

  : >"$NOTIFY_LOG"
  local status=0
  q_claim "$NAME_INT_READY_FN" "claimer-name-fn" >/dev/null || status=$?

  [ "$status" -eq 2 ] || fail "name-integrity filename: expected q_claim to return 2, got $status"
  [ -f "$NAME_INT_BLOCKED_FN" ] || fail "name-integrity filename: expected blocked file, none found"
  [ ! -f "$NAME_INT_READY_FN" ] || fail "name-integrity filename: ready file still present"
  grep -q "999-name-x" "$NAME_INT_BLOCKED_FN" || fail "name-integrity filename: block reason omits the filename base"
  grep -q "471-name-x" "$NAME_INT_BLOCKED_FN" || fail "name-integrity filename: block reason omits the frontmatter issue-slug"
  grep -qi "blocked" "$NOTIFY_LOG" || fail "name-integrity filename: notification missing 'blocked' wording"

  rm -f -- "$NAME_INT_BLOCKED_FN"
  pass "name-integrity filename: filename base != frontmatter issue-slug -> blocked naming both values, notified, returns 2"
}

NAME_INT_READY_HB="$MA_ROOT/builder-tasks/472-name-h.ready.md"
NAME_INT_BLOCKED_HB="$MA_ROOT/builder-tasks/472-name-h.blocked.md"

test_name_integrity_handoff_contradiction_blocks() {
  # Filename base coheres (472-name-h == issue-slug), but the Handoff section
  # steers a worker at a DIFFERENT issue-slug (616-phantom) — the exact 514-616
  # contradiction. name-integrity blocks even though (a) is clean.
  cat >"$NAME_INT_READY_HB" <<'EOF'
---
issue: 472
slug: name-h
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.

**Premise verification (PM, 2026-07-08):** evidence line.

## Gates
Run the tests.

## Authorizations roster
- AUTHORIZED: the change.

## Handoff
`<REPO ROOT>/multi-agent/validator-notes/616-phantom.ready.md` per convention.
EOF

  : >"$NOTIFY_LOG"
  local status=0
  q_claim "$NAME_INT_READY_HB" "claimer-name-hb" >/dev/null || status=$?

  [ "$status" -eq 2 ] || fail "name-integrity handoff: expected q_claim to return 2, got $status"
  [ -f "$NAME_INT_BLOCKED_HB" ] || fail "name-integrity handoff: expected blocked file, none found"
  grep -q "616-phantom" "$NAME_INT_BLOCKED_HB" || fail "name-integrity handoff: block reason omits the contradicting handoff base"
  grep -q "472-name-h" "$NAME_INT_BLOCKED_HB" || fail "name-integrity handoff: block reason omits the frontmatter issue-slug"

  rm -f -- "$NAME_INT_BLOCKED_HB"
  pass "name-integrity handoff: a Handoff path naming a different issue-slug -> blocked, notified, returns 2"
}

NAME_INT_READY_EX="$MA_ROOT/builder-tasks/998-name-exempt.ready.md"
NAME_INT_BLOCKED_EX="$MA_ROOT/builder-tasks/998-name-exempt.blocked.md"

test_name_integrity_exempt_class_still_checked() {
  # An origin-carrying fail-back with none of the four markers is EXEMPT from
  # the marker lint, but a mismatched filename (998-name-exempt vs frontmatter
  # 473-name-exempt) still blocks: exempt classes are exempt from MARKER checks,
  # never from name-integrity.
  cat >"$NAME_INT_READY_EX" <<'EOF'
---
issue: 473
slug: name-exempt
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
origin: scribe-post-review-fix
---
# Fail-back fix brief

## The single required change
Do the thing.
EOF

  : >"$NOTIFY_LOG"
  local status=0
  q_claim "$NAME_INT_READY_EX" "claimer-name-ex" >/dev/null || status=$?

  [ "$status" -eq 2 ] || fail "name-integrity exempt: expected q_claim to return 2 (name-integrity blocks despite marker exemption), got $status"
  [ -f "$NAME_INT_BLOCKED_EX" ] || fail "name-integrity exempt: expected blocked file, none found"
  grep -q "998-name-exempt" "$NAME_INT_BLOCKED_EX" || fail "name-integrity exempt: block reason omits the filename base"
  grep -q "473-name-exempt" "$NAME_INT_BLOCKED_EX" || fail "name-integrity exempt: block reason omits the frontmatter issue-slug"

  rm -f -- "$NAME_INT_BLOCKED_EX"
  pass "name-integrity exempt: an origin/marker-exempt brief with a mismatched name is still blocked by name-integrity"
}

OWNER_CLAIMED="$MA_ROOT/builder-tasks/500-owner-check.claimed.md"
OWNER_DONE="$MA_ROOT/builder-tasks/500-owner-check.done.md"

test_q_done_owner_mismatch() {
  cat >"$OWNER_CLAIMED" <<'EOF'
---
issue: 903
slug: owner-check
stage: builder
pass: 1
retries: 0
owner: claimer-real
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  local status=0
  q_done "$OWNER_CLAIMED" "claimer-impostor" || status=$?
  [ "$status" -eq 1 ] || fail "q_done owner mismatch: expected return 1, got $status"
  [ -f "$OWNER_CLAIMED" ] || fail "q_done owner mismatch: claimed file was renamed despite mismatch"
  [ ! -f "$OWNER_DONE" ] || fail "q_done owner mismatch: done file created despite mismatch"

  status=0
  q_done "$OWNER_CLAIMED" "claimer-real" || status=$?
  [ "$status" -eq 0 ] || fail "q_done owner match: expected return 0, got $status"
  [ -f "$OWNER_DONE" ] || fail "q_done owner match: expected done file, none found"
  [ ! -f "$OWNER_CLAIMED" ] || fail "q_done owner match: claimed file still present"

  pass "q_done: expected_owner mismatch leaves file untouched (return 1); matching owner completes normally"
}

FAIL_OWNER_CLAIMED="$MA_ROOT/builder-tasks/501-owner-check-fail.claimed.md"
FAIL_OWNER_FAILED="$MA_ROOT/builder-tasks/501-owner-check-fail.failed.md"

test_q_fail_owner_mismatch() {
  cat >"$FAIL_OWNER_CLAIMED" <<'EOF'
---
issue: 904
slug: owner-check-fail
stage: builder
pass: 1
retries: 0
owner: claimer-real
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  local status=0
  q_fail "$FAIL_OWNER_CLAIMED" "reason text" "claimer-impostor" || status=$?
  [ "$status" -eq 1 ] || fail "q_fail owner mismatch: expected return 1, got $status"
  [ -f "$FAIL_OWNER_CLAIMED" ] || fail "q_fail owner mismatch: claimed file was renamed despite mismatch"
  grep -q "reason text" "$FAIL_OWNER_CLAIMED" && fail "q_fail owner mismatch: reason was appended despite mismatch"
  [ ! -f "$FAIL_OWNER_FAILED" ] || fail "q_fail owner mismatch: failed file created despite mismatch"

  status=0
  q_fail "$FAIL_OWNER_CLAIMED" "reason text" "claimer-real" || status=$?
  [ "$status" -eq 0 ] || fail "q_fail owner match: expected return 0, got $status"
  [ -f "$FAIL_OWNER_FAILED" ] || fail "q_fail owner match: expected failed file, none found"
  grep -q "reason text" "$FAIL_OWNER_FAILED" || fail "q_fail owner match: reason missing from failed file"

  pass "q_fail: expected_owner mismatch leaves file untouched (return 1); matching owner completes normally"
}

# --- Validator Pass-1 findings (V1, V2, V3a, V3c, V4, V8) ---

test_v1_ma_root_bash_source() {
  # Empirical closure of the Validator's V1 blind spot: MA_ROOT must resolve
  # correctly under launchd's real conditions (CWD "/", no git, no
  # pre-seeded MA_ROOT env var) -- not just in this harness's own sandbox,
  # which always sets MA_ROOT explicitly. /bin/bash matches the bash 3.2
  # target on macOS.
  local repo_root queue_sh expected actual
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  queue_sh="$SCRIPT_DIR/queue.sh"
  expected="$repo_root/multi-agent"

  actual=$(cd / && env -i HOME=/tmp /bin/bash -c "source '$queue_sh'; printf '%s' \"\$MA_ROOT\"")
  [ "$actual" = "$expected" ] || fail "v1: MA_ROOT expected '$expected', got '$actual'"

  pass "v1: MA_ROOT resolves to the repo's multi-agent/ from CWD / with a scrubbed env (no git, no MA_ROOT)"
}

test_v2_install_loops_env_vars() {
  local install_sh tmp_agents_dir fake_bin_dir fake_launchctl_log
  install_sh="$SCRIPT_DIR/install-loops.sh"
  tmp_agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-install-test.XXXXXX")
  fake_bin_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-install-fakebin.XXXXXX")
  fake_launchctl_log="$tmp_agents_dir/launchctl-invoked.log"

  # A fake `launchctl` ahead of the real PATH: if install-loops.sh ever
  # actually invoked it (it must not -- enabling is a manual human step),
  # this would record it.
  cat >"$fake_bin_dir/launchctl" <<EOF
#!/usr/bin/env bash
printf 'launchctl called: %s\n' "\$*" >>"$fake_launchctl_log"
EOF
  chmod +x "$fake_bin_dir/launchctl"

  local expected_ma_root
  expected_ma_root="$(cd "$SCRIPT_DIR/../.." && pwd)/multi-agent"

  # Unset the harness's own exported MA_ROOT so install-loops.sh computes
  # its real installer-time default (REPO_ROOT/multi-agent), same as it
  # would on a fresh machine.
  ( unset MA_ROOT
    MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" PATH="$fake_bin_dir:$PATH" bash "$install_sh" >/dev/null
  ) || fail "v2: install-loops.sh exited nonzero"

  [ ! -f "$fake_launchctl_log" ] || fail "v2: install-loops.sh invoked launchctl"

  local plist_count=0
  local plist
  for plist in "$tmp_agents_dir"/"$MA_DEFAULT_LABEL_PREFIX".*.plist; do
    [ -e "$plist" ] || continue
    plist_count=$((plist_count + 1))
    grep -q "<key>EnvironmentVariables</key>" "$plist" || fail "v2: $plist missing EnvironmentVariables"
    grep -q "<key>PATH</key>" "$plist" || fail "v2: $plist missing PATH key"
    local path_value
    path_value=$(awk '/<key>PATH<\/key>/{getline; print; exit}' "$plist")
    printf '%s' "$path_value" | grep -q '<string>[^<].*</string>' || fail "v2: $plist has an empty PATH value"
    grep -qF "<string>${expected_ma_root}</string>" "$plist" || fail "v2: $plist missing correct MA_ROOT ($expected_ma_root)"
  done
  [ "$plist_count" -eq 4 ] || fail "v2: expected 4 plists, found $plist_count"

  rm -rf -- "$tmp_agents_dir" "$fake_bin_dir"

  pass "v2: install-loops.sh bakes EnvironmentVariables (non-empty PATH, correct MA_ROOT) into all 4 plists; never invokes launchctl"
}

# --- launchd label prefix (--label-prefix) ---------------------------------
#
# launchd labels are per-USER, not per-repo. Two checkouts of this system on one
# Mac under the same prefix would install over each other's four agents, and the
# survivor would poll the loser's queue. The prefix is therefore the one thing a
# port MUST change, and these tests fence all three of its states: the default
# is untouched without the flag, a custom prefix names every artifact, and a
# prefix that could not be safely spliced into a Label or a filename is refused.

LABEL_TEST_AGENTS=(builder-loop validator-loop scribe-loop reaper)

test_install_default_label_prefix_unchanged() {
  local tmp_agents_dir agent
  tmp_agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-label-default.XXXXXX")

  # MA_LAUNCH_AGENTS_DIR keeps this off the real ~/Library/LaunchAgents; the
  # flag under test is --label-prefix, which is deliberately NOT passed here.
  MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
    bash "$SCRIPT_DIR/install-loops.sh" >/dev/null 2>&1 ||
    fail "label default: install-loops.sh with no flag exited nonzero"

  for agent in "${LABEL_TEST_AGENTS[@]}"; do
    [ -f "$tmp_agents_dir/$MA_DEFAULT_LABEL_PREFIX.$agent.plist" ] ||
      fail "label default: missing $MA_DEFAULT_LABEL_PREFIX.$agent.plist"
  done

  rm -rf -- "$tmp_agents_dir"
  pass "label default: install-loops.sh with no --label-prefix still writes the four $MA_DEFAULT_LABEL_PREFIX.* plists (behavior unchanged)"
}

test_install_custom_label_prefix() {
  local tmp_agents_dir prefix agent plist count
  tmp_agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-label-custom.XXXXXX")
  prefix="com.example.port-test"

  MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
    bash "$SCRIPT_DIR/install-loops.sh" --label-prefix "$prefix" >/dev/null 2>&1 ||
    fail "label custom: install-loops.sh --label-prefix exited nonzero"

  for agent in "${LABEL_TEST_AGENTS[@]}"; do
    plist="$tmp_agents_dir/$prefix.$agent.plist"
    [ -f "$plist" ] || fail "label custom: missing $prefix.$agent.plist"
    grep -qF "<string>$prefix.$agent</string>" "$plist" ||
      fail "label custom: $plist does not carry Label $prefix.$agent"
    # The log filename is derived by stripping the prefix off the label. A
    # stripped-wrong name would leave the whole label in the log path.
    grep -qF "logs/launchd-$agent.out.log" "$plist" ||
      fail "label custom: $plist log path did not strip the prefix off the label"
    grep -q "<key>EnvironmentVariables</key>" "$plist" ||
      fail "label custom: $plist lost its baked EnvironmentVariables"
  done

  count=$(find "$tmp_agents_dir" -name '*.plist' | grep -c .)
  [ "$count" -eq 4 ] || fail "label custom: expected exactly 4 plists, found $count"
  [ ! -f "$tmp_agents_dir/$MA_DEFAULT_LABEL_PREFIX.builder-loop.plist" ] ||
    fail "label custom: a default-prefixed plist was written alongside the custom one"

  # The uninstaller has to accept the same prefix, or a custom install is
  # unremovable by the tool that created it.
  MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
    bash "$SCRIPT_DIR/uninstall-loops.sh" --label-prefix "$prefix" >/dev/null 2>&1 ||
    fail "label custom: uninstall-loops.sh --label-prefix exited nonzero"

  count=$(find "$tmp_agents_dir" -name '*.plist' | grep -c .)
  [ "$count" -eq 0 ] || fail "label custom: uninstall left $count plist(s) behind"

  rm -rf -- "$tmp_agents_dir"
  pass "label custom: --label-prefix names all 4 plists, Labels and log paths; no default-prefixed plist leaks; uninstall-loops.sh --label-prefix removes exactly them"
}

test_install_invalid_label_prefix_rejected() {
  local tmp_agents_dir bad status count out
  tmp_agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-label-bad.XXXXXX")

  # Each of these would produce an invalid launchd Label, an invalid plist
  # filename, or a path escape once spliced into "$DIR/<prefix>.<agent>.plist".
  # The multiline case is the one a per-line `grep -Eq '^...$'` match lets
  # through: its first line is a valid prefix, so only a whole-string match
  # rejects it before a literal newline reaches a plist filename.
  for bad in \
    '' \
    'nodots' \
    'com.foo/bar' \
    '../evil' \
    'com..foo' \
    'com.foo.' \
    '.com.foo' \
    'com.foo bar' \
    'com.$(whoami)' \
    $'com.foo\ncom.bar'; do
    status=0
    out=$(MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
      bash "$SCRIPT_DIR/install-loops.sh" --label-prefix "$bad" 2>&1) || status=$?
    [ "$status" -ne 0 ] ||
      fail "label invalid: install-loops.sh ACCEPTED the invalid prefix '$bad'"
    printf '%s' "$out" | grep -qi 'invalid --label-prefix' ||
      fail "label invalid: install-loops.sh rejected '$bad' without saying why"

    status=0
    MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
      bash "$SCRIPT_DIR/uninstall-loops.sh" --label-prefix "$bad" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] ||
      fail "label invalid: uninstall-loops.sh ACCEPTED the invalid prefix '$bad'"
  done

  count=$(find "$tmp_agents_dir" -name '*.plist' | grep -c .)
  [ "$count" -eq 0 ] ||
    fail "label invalid: a rejected prefix still wrote $count plist(s)"

  # A missing value must not silently fall back to the default.
  status=0
  MA_LAUNCH_AGENTS_DIR="$tmp_agents_dir" \
    bash "$SCRIPT_DIR/install-loops.sh" --label-prefix >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "label invalid: a valueless --label-prefix was accepted"

  rm -rf -- "$tmp_agents_dir"
  pass "label invalid: empty, dotless, slashed, traversal, empty-segment, trailing/leading-dot, spaced, substitution-shaped and valueless prefixes are all refused loudly by BOTH installers; no plist is written"
}

# _test_ts_from_offset_sec <seconds-ago>
# Print an ISO-8601 UTC timestamp <seconds-ago> seconds before now.
_test_ts_from_offset_sec() {
  local offset="$1" epoch
  epoch=$(( $(date -u +%s) - offset ))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

V3A_CLAIMED_WITHIN="$MA_ROOT/builder-tasks/104-v3a-within.claimed.md"
V3A_CLAIMED_BEYOND="$MA_ROOT/builder-tasks/105-v3a-beyond.claimed.md"
V3A_READY_BEYOND="$MA_ROOT/builder-tasks/105-v3a-beyond.ready.md"

test_v3a_owner_null_liveness_escape_hatch() {
  # MA_REAP_BUILDER_MIN=1 below keeps this fast and deterministic without
  # touching the real 90-minute default.
  local within_ts beyond_ts
  within_ts=$(_test_ts_from_offset_sec 90)   # 1.5x a 1-minute timeout
  beyond_ts=$(_test_ts_from_offset_sec 150)  # 2.5x a 1-minute timeout

  cat >"$V3A_CLAIMED_WITHIN" <<EOF
---
issue: 705
slug: v3a-within
stage: builder
pass: 1
retries: 0
owner: null
updated: $within_ts
---
Task body.
EOF

  cat >"$V3A_CLAIMED_BEYOND" <<EOF
---
issue: 706
slug: v3a-beyond
stage: builder
pass: 1
retries: 0
owner: null
updated: $beyond_ts
---
Task body.
EOF

  MA_REAP_BUILDER_MIN=1 bash "$REAPER" || fail "v3a: invocation exited nonzero"

  [ -f "$V3A_CLAIMED_WITHIN" ] || fail "v3a: owner:null claim within 2x timeout was reaped (should be left alone)"
  [ -f "$V3A_READY_BEYOND" ] || fail "v3a: owner:null claim beyond 2x timeout was not requeued"
  [ ! -f "$V3A_CLAIMED_BEYOND" ] || fail "v3a: claimed file for beyond-2x case still present after requeue"

  rm -f -- "$V3A_CLAIMED_WITHIN" "$V3A_READY_BEYOND"

  pass "v3a: owner:null claim within 2x timeout left alone; beyond 2x timeout requeued (liveness escape hatch)"
}

test_v3c_requeue_clears_owner() {
  local claimed="$MA_ROOT/builder-tasks/107-v3c-requeue.claimed.md"
  local ready="$MA_ROOT/builder-tasks/107-v3c-requeue.ready.md"
  cat >"$claimed" <<'EOF'
---
issue: 707
slug: v3c-requeue
stage: builder
pass: 1
retries: 0
owner: claimer-v3c
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  q_requeue "$claimed"
  [ -f "$ready" ] || fail "v3c: ready file not restored after requeue"

  local owner
  owner=$(q_get "$ready" owner)
  [ "$owner" = "null" ] || fail "v3c: expected owner=null after requeue, got '$owner'"

  rm -f -- "$ready"

  pass "v3c: q_requeue clears owner back to null"
}

V4_CLAIMED_A="$MA_ROOT/builder-tasks/910-v4-a.claimed.md"
V4_CLAIMED_B="$MA_ROOT/validator-notes/911-v4-b.claimed.md"

test_v4_deterministic_tiebreak() {
  cat >"$V4_CLAIMED_A" <<'EOF'
---
issue: 910
slug: v4-a
stage: builder
pass: 1
retries: 0
owner: claimer-v4a
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  cat >"$V4_CLAIMED_B" <<'EOF'
---
issue: 911
slug: v4-b
stage: validator
pass: 1
retries: 0
owner: claimer-v4b
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  # $V4_CLAIMED_A sorts lexically smaller than $V4_CLAIMED_B (both share
  # $MA_ROOT; "builder-tasks" < "validator-notes"), so it should keep its
  # claim while the other is requeued -- exactly one survivor, no livelock.
  local status=0
  _ml_enforce_single_claim "$V4_CLAIMED_A" || status=$?
  [ "$status" -eq 0 ] || fail "v4: expected the lexically-smaller path to keep its claim (status=$status)"
  [ -f "$V4_CLAIMED_A" ] || fail "v4: winner's claimed file was touched"

  status=0
  _ml_enforce_single_claim "$V4_CLAIMED_B" || status=$?
  [ "$status" -ne 0 ] || fail "v4: expected the lexically-larger path to be requeued"
  [ ! -f "$V4_CLAIMED_B" ] || fail "v4: loser's claimed file still present"

  local ready_b="$MA_ROOT/validator-notes/911-v4-b.ready.md"
  [ -f "$ready_b" ] || fail "v4: loser was not requeued to ready"

  rm -f -- "$V4_CLAIMED_A" "$ready_b"

  pass "v4: deterministic tiebreak keeps the lexically-smaller claim, requeues the other"
}

V8_UNKNOWN_FILE="$MA_ROOT/builder-tasks/930-unknown-state.md"

test_v8_unknown_state_guard() {
  cat >"$V8_UNKNOWN_FILE" <<'EOF'
---
issue: 930
slug: unknown-state
stage: builder
pass: 1
retries: 0
owner: claimer-v8
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  local status=0
  q_fail "$V8_UNKNOWN_FILE" "reason text" 2>/dev/null || status=$?
  [ "$status" -eq 1 ] || fail "v8: expected q_fail to return 1 for an unrecognized-suffix file, got $status"

  local other_files
  other_files=$(find "$MA_ROOT/builder-tasks" -maxdepth 1 -name '930-unknown-state*' | wc -l | tr -d ' ')
  [ "$other_files" -eq 1 ] || fail "v8: expected only the original file to remain, found $other_files"
  [ -f "$V8_UNKNOWN_FILE" ] || fail "v8: original file was renamed/removed"

  rm -f -- "$V8_UNKNOWN_FILE"

  pass "v8: q_fail on a file without a recognized state suffix returns 1, creates no double-suffixed file"
}

LOCALTIME_READY="$MA_ROOT/builder-tasks/813-localtime.ready.md"
LOCALTIME_CLAIMED="$MA_ROOT/builder-tasks/813-localtime.claimed.md"
LOCALTIME_FAILED="$MA_ROOT/builder-tasks/813-localtime.failed.md"

# Directional contract for the display-vs-machine timestamp split:
#   - state.log lines and the `## FAILED` body appendix are human-facing ->
#     system-local with a numeric offset ([+-]HHMM).
#   - frontmatter `updated` is parsed by the reaper -> UTC with a `Z` suffix.
# Each surface gets a positive assertion (right dialect) AND a negative one
# (wrong dialect fails), so a future regression on either side of the split
# surfaces as a test failure instead of passing silently. `%z` never emits
# `Z`, so the two dialects stay distinguishable even in a UTC-local machine.
test_local_time_display() {
  cat >"$LOCALTIME_READY" <<EOF
---
issue: 813
slug: localtime
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF

  local local_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$'
  local utc_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

  # Display surface: the newest state.log line's timestamp is system-local.
  q_claim "$LOCALTIME_READY" "claimer-813" >/dev/null || fail "localtime: claim failed"

  local log_ts
  log_ts=$(tail -n 1 "$MA_ROOT/state.log" | awk '{print $1}')
  [[ "$log_ts" =~ $local_re ]] || fail "localtime: state.log ts '$log_ts' is not local-offset format"
  [[ "$log_ts" =~ $utc_re ]] && fail "localtime: state.log ts '$log_ts' is UTC 'Z' (display must be local)"

  # Machine surface: frontmatter `updated` stamped by q_claim stays UTC.
  local fm_updated
  fm_updated=$(q_get "$LOCALTIME_CLAIMED" updated)
  [[ "$fm_updated" =~ $utc_re ]] || fail "localtime: frontmatter updated '$fm_updated' is not UTC 'Z' format"
  [[ "$fm_updated" =~ $local_re ]] && fail "localtime: frontmatter updated '$fm_updated' carries a local offset (must stay UTC)"

  # Split surface: q_fail's body appendix is local, frontmatter still UTC.
  q_fail "$LOCALTIME_CLAIMED" "localtime split check" || fail "localtime: q_fail failed"

  local failed_ts
  failed_ts=$(awk '/^## FAILED /{print $3}' "$LOCALTIME_FAILED")
  [[ "$failed_ts" =~ $local_re ]] || fail "localtime: '## FAILED' body ts '$failed_ts' is not local-offset format"
  [[ "$failed_ts" =~ $utc_re ]] && fail "localtime: '## FAILED' body ts '$failed_ts' is UTC 'Z' (display must be local)"

  local fm_updated_after
  fm_updated_after=$(q_get "$LOCALTIME_FAILED" updated)
  [[ "$fm_updated_after" =~ $utc_re ]] || fail "localtime: post-fail frontmatter updated '$fm_updated_after' is not UTC 'Z'"
  [[ "$fm_updated_after" =~ $local_re ]] && fail "localtime: post-fail frontmatter updated '$fm_updated_after' carries a local offset (must stay UTC)"

  # Leave no fixture behind for the oldest-first loop-tick scan below.
  rm -f -- "$LOCALTIME_READY" "$LOCALTIME_CLAIMED" "$LOCALTIME_FAILED"

  pass "localtime: display surfaces (state.log, ## FAILED body) local-offset; frontmatter updated stays UTC"
}

test_race
test_requeue
test_fail
test_roundtrip
test_state_log
test_enforce_single_claim
test_claim_malformed_frontmatter
test_brief_lint_compliant_claims
test_brief_lint_missing_marker_blocks
test_brief_lint_origin_exempt_claims
test_brief_lint_passN_exempt_claims
test_name_integrity_coherent_claims
test_name_integrity_filename_mismatch_blocks
test_name_integrity_handoff_contradiction_blocks
test_name_integrity_exempt_class_still_checked
test_q_done_owner_mismatch
test_q_fail_owner_mismatch
test_reaper_requeue
test_reaper_deadletter
test_reaper_supersede_dual_handoff
test_reaper_fresh
test_reaper_fresh_last_inbox_exit_code
test_v1_ma_root_bash_source
test_v2_install_loops_env_vars
test_install_default_label_prefix_unchanged
test_install_custom_label_prefix
test_install_invalid_label_prefix_rejected
test_v3a_owner_null_liveness_escape_hatch
test_v3c_requeue_clears_owner
test_v4_deterministic_tiebreak
test_v8_unknown_state_guard
test_local_time_display

# --- Loop-tick tests (builder-loop.sh / validator-loop.sh) ---
#
# Earlier tests deliberately leave state behind that the loop-tick tests
# below must not inherit: test_reaper_requeue leaves a genuine
# .ready.md in builder-tasks (it only asserts the requeue+re-claim
# mechanics, never runs it to completion), and
# test_reaper_fresh_last_inbox_exit_code leaves a fresh claim in
# scribe-notes (it asserts the file is left untouched). A leftover
# .ready.md would be older than anything the loop-tick tests create and
# would win the oldest-first scan; a leftover .claimed.md would trip the
# lane-busy check. Clean both up before relying on a free, empty lane.
rm -f -- "$REAP_READY_REQUEUE" "$REAP_CLAIMED_SCRIBE_FRESH" \
  "$REAP_SUPERSEDED_SUPERSEDE" "$REAP_DS_HANDOFF_SUPERSEDE"

BUILDER_LOOP="$SCRIPT_DIR/builder-loop.sh"
VALIDATOR_LOOP="$SCRIPT_DIR/validator-loop.sh"

STUB_ARGS_LOG="$TMP_ROOT/worker-stub-args.log"
STUB_EXIT_FILE="$TMP_ROOT/worker-stub-exit-code"
STUB_OUTPUT="$TMP_ROOT/worker-stub-output.txt"
STUB_HANDOFF_PATH="$TMP_ROOT/worker-stub-handoff-path"
STUB_HANDOFF_MODE="$TMP_ROOT/worker-stub-handoff-mode"
WORKER_STUB="$TMP_ROOT/worker-stub.sh"

# The stub records the args it was called with (claimed path, repo root)
# and prints canned output, so tests can assert both the WORKER_CMD
# contract (args) and the log-capture behavior (stub stdout ends up in
# the loop's log file). Exit code is controlled per-scenario via
# STUB_EXIT_FILE.
#
# It can also emit a downstream handoff so the postcondition-gate tests
# can drive the "correct handoff" scenario through the shared stub: if the
# STUB_HANDOFF_PATH file exists, its content names the handoff file to
# write, and the STUB_HANDOFF_MODE file (content "good" or "malformed",
# default "good") selects whether that handoff carries a complete
# frontmatter block. Absent STUB_HANDOFF_PATH, the stub writes no handoff.
cat >"$WORKER_STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >>"$STUB_ARGS_LOG"
if [ -f "$STUB_OUTPUT" ]; then
  cat "$STUB_OUTPUT"
fi
if [ -f "$STUB_HANDOFF_PATH" ]; then
  handoff_path=$(cat "$STUB_HANDOFF_PATH")
  handoff_mode=good
  [ -f "$STUB_HANDOFF_MODE" ] && handoff_mode=$(cat "$STUB_HANDOFF_MODE")
  mkdir -p "$(dirname "$handoff_path")"
  if [ "$handoff_mode" = malformed ]; then
    printf '%s\n' '---' 'stage: validator' '---' 'Malformed: required keys omitted.' >"$handoff_path"
  else
    printf '%s\n' '---' 'issue: 0' 'slug: stub' 'stage: validator' 'pass: 1' \
      'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'Stub handoff body.' >"$handoff_path"
  fi
fi
exit_code=0
if [ -f "$STUB_EXIT_FILE" ]; then
  exit_code=$(cat "$STUB_EXIT_FILE")
fi
exit "$exit_code"
STUBEOF
chmod +x "$WORKER_STUB"
export STUB_ARGS_LOG STUB_EXIT_FILE STUB_OUTPUT STUB_HANDOFF_PATH STUB_HANDOFF_MODE
export WORKER_CMD="$WORKER_STUB"

# Filename base matches frontmatter issue-slug (800-tick-happy) to satisfy the
# name-integrity lint, and aligns with the issue-derived handoff/log paths below.
BUILDER_READY_HAPPY="$MA_ROOT/builder-tasks/800-tick-happy.ready.md"
BUILDER_CLAIMED_HAPPY="$MA_ROOT/builder-tasks/800-tick-happy.claimed.md"
BUILDER_DONE_HAPPY="$MA_ROOT/builder-tasks/800-tick-happy.done.md"

test_tick_happy_path() {
  cat >"$BUILDER_READY_HAPPY" <<EOF
---
issue: 800
slug: tick-happy
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF

  : >"$STUB_ARGS_LOG"
  rm -f "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$STUB_HANDOFF_MODE"
  # The builder postcondition gate requires a well-formed validator handoff
  # before a claim is recorded done, so the happy path must produce one.
  local happy_handoff="$MA_ROOT/validator-notes/800-tick-happy.ready.md"
  printf '%s' "$happy_handoff" >"$STUB_HANDOFF_PATH"

  bash "$BUILDER_LOOP" || fail "tick happy path: builder-loop exited nonzero"

  [ -f "$BUILDER_DONE_HAPPY" ] || fail "tick happy path: expected done file, none found"
  [ ! -f "$BUILDER_READY_HAPPY" ] || fail "tick happy path: ready file still present"
  [ ! -f "$BUILDER_CLAIMED_HAPPY" ] || fail "tick happy path: claimed file still present"

  grep -q "$BUILDER_CLAIMED_HAPPY" "$STUB_ARGS_LOG" || fail "tick happy path: worker did not receive the claimed file path"

  local log_count
  log_count=$(find "$MA_ROOT/logs" -maxdepth 1 -name '800-tick-happy-builder-*.log' | wc -l | tr -d ' ')
  [ "$log_count" -eq 1 ] || fail "tick happy path: expected exactly 1 log file, found $log_count"

  # Leave no stray handoff behind — a lingering .ready.md in validator-notes
  # would win the oldest-first scan in a later validator-loop test.
  rm -f -- "$happy_handoff" "$STUB_HANDOFF_PATH"

  pass "tick happy path: ready -> done via stub worker (writes valid handoff), claimed path passed, log captured"
}

LANE_BUSY_CLAIMED="$MA_ROOT/validator-notes/201-lane-busy.claimed.md"
LANE_BUSY_READY="$MA_ROOT/builder-tasks/202-lane-busy.ready.md"

test_tick_lane_busy() {
  cat >"$LANE_BUSY_CLAIMED" <<'EOF'
---
issue: 801
slug: lane-busy
stage: validator
pass: 1
retries: 0
owner: someone
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  cat >"$LANE_BUSY_READY" <<'EOF'
---
issue: 802
slug: lane-busy-2
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  : >"$STUB_ARGS_LOG"

  local status=0
  bash "$BUILDER_LOOP" || status=$?
  [ "$status" -eq 0 ] || fail "tick lane busy: expected exit 0, got $status"

  [ -f "$LANE_BUSY_READY" ] || fail "tick lane busy: ready file was consumed while another lane claim is in flight"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "tick lane busy: worker was invoked while lane busy"

  rm -f -- "$LANE_BUSY_CLAIMED" "$LANE_BUSY_READY"

  pass "tick lane busy: builder-loop exits 0 without claiming while another claim is in flight"
}

# Filename base matches frontmatter issue-slug (803-tick-fail) for name integrity.
BUILDER_READY_FAIL="$MA_ROOT/builder-tasks/803-tick-fail.ready.md"
BUILDER_FAILED_FAIL="$MA_ROOT/builder-tasks/803-tick-fail.failed.md"

test_tick_worker_failure() {
  cat >"$BUILDER_READY_FAIL" <<EOF
---
issue: 803
slug: tick-fail
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF

  : >"$STUB_ARGS_LOG"
  printf '7\n' >"$STUB_EXIT_FILE"
  printf 'stub worker: simulated failure output\n' >"$STUB_OUTPUT"

  bash "$BUILDER_LOOP" || fail "tick worker failure: builder-loop should still exit 0 (q_fail recorded the outcome)"

  [ -f "$BUILDER_FAILED_FAIL" ] || fail "tick worker failure: expected failed file, none found"
  grep -q "simulated failure output" "$BUILDER_FAILED_FAIL" || fail "tick worker failure: reason missing stub output tail"
  # Negative half of the quota-signature contract: a nonzero exit WITHOUT the
  # session-limit signature must dead-letter as before and never drop a
  # defer marker (the positive half is test_tick_quota_defer_requeues).
  [ ! -f "$MA_ROOT/.quota-deferred-until" ] || fail "tick worker failure: quota marker created for a non-quota failure"

  rm -f "$STUB_EXIT_FILE" "$STUB_OUTPUT"

  pass "tick worker failure: nonzero worker exit -> failed file with log tail in reason, loop still exits 0"
}

V5_READY_EVIL="$MA_ROOT/builder-tasks/920-evil.ready.md"
V5_FAILED_EVIL="$MA_ROOT/builder-tasks/920-evil.failed.md"

test_v5_invalid_issue_slug_guard() {
  cat >"$V5_READY_EVIL" <<'EOF'
---
issue: ../../evil
slug: some-slug
stage: builder
pass: 1
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  : >"$STUB_ARGS_LOG"

  bash "$BUILDER_LOOP" || fail "v5: builder-loop exited nonzero"

  [ -f "$V5_FAILED_EVIL" ] || fail "v5: expected .failed.md for invalid issue, none found"
  [ ! -f "$V5_READY_EVIL" ] || fail "v5: ready file still present"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "v5: worker was invoked despite invalid issue"
  grep -q "invalid issue/slug" "$V5_FAILED_EVIL" || fail "v5: failed reason doesn't mention invalid issue/slug"

  pass "v5: issue=../../evil is rejected (guard runs before either worktree/branch fork) -- .failed.md, worker never invoked"
}

VALIDATOR_READY_MAXPASS="$MA_ROOT/validator-notes/204-tick-maxpass.ready.md"
VALIDATOR_BLOCKED_MAXPASS="$MA_ROOT/validator-notes/204-tick-maxpass.blocked.md"

test_tick_max_pass() {
  cat >"$VALIDATOR_READY_MAXPASS" <<'EOF'
---
issue: 804
slug: tick-maxpass
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"

  bash "$VALIDATOR_LOOP" || fail "tick max-pass: validator-loop exited nonzero"

  [ -f "$VALIDATOR_BLOCKED_MAXPASS" ] || fail "tick max-pass: expected blocked file, none found"
  [ ! -f "$VALIDATOR_READY_MAXPASS" ] || fail "tick max-pass: ready file still present"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "tick max-pass: worker was invoked despite the max-pass gate"
  grep -q "804" "$NOTIFY_LOG" || fail "tick max-pass: notification missing issue number"

  pass "tick max-pass: pass>=3 blocked before claim, human notified, worker never invoked"
}

# --- Postcondition-gate tests (worker exits 0 but its handoff is missing,
# malformed, or ambiguous) ---
#
# These exercise _ml_check_postcondition via ml_tick: a clean worker exit is
# necessary but not sufficient; the expected downstream handoff must also
# exist with complete frontmatter, and (validator) exactly one of the two
# possible handoffs must be present.

# _mk_ready <file> <issue> <slug> <stage> <pass>
# Write a well-formed ready file with the given frontmatter.
_mk_ready() {
  cat >"$1" <<EOF
---
issue: $2
slug: $3
stage: $4
pass: $5
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
$COMPLIANT_BRIEF_BODY
EOF
}

# _mk_stub <file> <body-before-exit>
# Write an executable worker stub that runs <body-before-exit> then exit 0.
# The body is expanded at write time, so callers may embed $MA_ROOT.
_mk_stub() {
  local stub="$1" body="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
$body
exit 0
EOF
  chmod +x "$stub"
}

test_tick_postcondition_builder_no_handoff() {
  local ready="$MA_ROOT/builder-tasks/820-pc-no-handoff.ready.md"
  local failed="$MA_ROOT/builder-tasks/820-pc-no-handoff.failed.md"
  _mk_ready "$ready" 820 pc-no-handoff builder 1
  : >"$NOTIFY_LOG"

  local stub="$TMP_ROOT/stub-no-handoff.sh"
  _mk_stub "$stub" ':'

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "pc builder no-handoff: builder-loop exited nonzero (q_fail should have recorded it)"

  [ -f "$failed" ] || fail "pc builder no-handoff: expected failed file, none found"
  grep -qi "postcondition" "$failed" || fail "pc builder no-handoff: reason missing 'postcondition'"
  grep -q "820" "$NOTIFY_LOG" || fail "pc builder no-handoff: notification missing issue number"

  rm -f -- "$failed"
  pass "pc builder no-handoff: worker exit 0 with no validator handoff -> failed, human notified"
}

test_tick_postcondition_builder_malformed_handoff() {
  local ready="$MA_ROOT/builder-tasks/821-pc-malformed.ready.md"
  local failed="$MA_ROOT/builder-tasks/821-pc-malformed.failed.md"
  local handoff="$MA_ROOT/validator-notes/821-pc-malformed.ready.md"
  _mk_ready "$ready" 821 pc-malformed builder 1
  : >"$NOTIFY_LOG"

  local stub="$TMP_ROOT/stub-malformed.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/validator-notes\"
printf '%s\\n' '---' 'issue: 821' 'slug: pc-malformed' 'stage: validator' '---' 'Missing pass/retries/owner/updated.' >\"$handoff\""

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "pc builder malformed: builder-loop exited nonzero"

  [ -f "$failed" ] || fail "pc builder malformed: expected failed file, none found"
  grep -qi "malformed frontmatter" "$failed" || fail "pc builder malformed: reason missing 'malformed frontmatter'"
  grep -q "821" "$NOTIFY_LOG" || fail "pc builder malformed: notification missing issue number"

  rm -f -- "$failed" "$handoff"
  pass "pc builder malformed: worker exit 0 with incomplete-frontmatter handoff -> failed, human notified"
}

test_tick_postcondition_builder_correct_handoff() {
  local ready="$MA_ROOT/builder-tasks/822-pc-correct.ready.md"
  local done_file="$MA_ROOT/builder-tasks/822-pc-correct.done.md"
  local handoff="$MA_ROOT/validator-notes/822-pc-correct.ready.md"
  _mk_ready "$ready" 822 pc-correct builder 1

  local stub="$TMP_ROOT/stub-correct.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/validator-notes\"
printf '%s\\n' '---' 'issue: 822' 'slug: pc-correct' 'stage: validator' 'pass: 1' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'Handoff.' >\"$handoff\""

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "pc builder correct: builder-loop exited nonzero"

  [ -f "$done_file" ] || fail "pc builder correct: expected done file, none found"
  [ -f "$handoff" ] || fail "pc builder correct: validator handoff was not preserved"

  rm -f -- "$done_file" "$handoff"
  pass "pc builder correct: worker exit 0 with a complete validator handoff -> done"
}

test_tick_postcondition_validator_scribe_clear() {
  local ready="$MA_ROOT/validator-notes/830-pc-clear.ready.md"
  local done_file="$MA_ROOT/validator-notes/830-pc-clear.done.md"
  local handoff="$MA_ROOT/scribe-notes/830-pc-clear.ready.md"
  _mk_ready "$ready" 830 pc-clear validator 1

  local stub="$TMP_ROOT/stub-scribe.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/scribe-notes\"
printf '%s\\n' '---' 'issue: 830' 'slug: pc-clear' 'stage: scribe' 'pass: 1' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'Scribe handoff.' >\"$handoff\""

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "pc validator clear: validator-loop exited nonzero"

  [ -f "$done_file" ] || fail "pc validator clear: expected done file, none found"

  rm -f -- "$done_file" "$handoff"
  pass "pc validator clear: worker exit 0 with exactly one scribe handoff -> done"
}

test_tick_postcondition_validator_failback_ok() {
  local ready="$MA_ROOT/validator-notes/831-pc-failback.ready.md"
  local done_file="$MA_ROOT/validator-notes/831-pc-failback.done.md"
  local handoff="$MA_ROOT/builder-tasks/831-pc-failback.ready.md"
  _mk_ready "$ready" 831 pc-failback validator 1

  # Fail-back brief with pass incremented 1 -> 2: postcondition accepts it.
  local stub="$TMP_ROOT/stub-failback.sh"
  _mk_stub "$stub" "printf '%s\\n' '---' 'issue: 831' 'slug: pc-failback' 'stage: builder' 'pass: 2' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'Fail-back brief.' >\"$handoff\""

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "pc validator failback ok: validator-loop exited nonzero"

  [ -f "$done_file" ] || fail "pc validator failback ok: expected done file, none found"

  rm -f -- "$done_file" "$handoff"
  pass "pc validator failback ok: worker exit 0 with one fail-back brief (pass++ ) -> done"
}

test_tick_postcondition_validator_both() {
  local ready="$MA_ROOT/validator-notes/832-pc-both.ready.md"
  local failed="$MA_ROOT/validator-notes/832-pc-both.failed.md"
  local scribe="$MA_ROOT/scribe-notes/832-pc-both.ready.md"
  local failback="$MA_ROOT/builder-tasks/832-pc-both.ready.md"
  _mk_ready "$ready" 832 pc-both validator 1
  : >"$NOTIFY_LOG"

  local stub="$TMP_ROOT/stub-both.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/scribe-notes\"
printf '%s\\n' '---' 'issue: 832' 'slug: pc-both' 'stage: scribe' 'pass: 1' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'S.' >\"$scribe\"
printf '%s\\n' '---' 'issue: 832' 'slug: pc-both' 'stage: builder' 'pass: 2' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'B.' >\"$failback\""

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "pc validator both: validator-loop exited nonzero"

  [ -f "$failed" ] || fail "pc validator both: expected failed file, none found"
  grep -qi "BOTH" "$failed" || fail "pc validator both: reason missing 'BOTH'"
  grep -q "832" "$NOTIFY_LOG" || fail "pc validator both: notification missing issue number"

  # The two strays from the violated contract must be neutralized: neither
  # .ready.md may survive (a later tick could claim it), and each must have
  # been renamed to the inert .superseded.md suffix in place.
  local scribe_superseded="$MA_ROOT/scribe-notes/832-pc-both.superseded.md"
  local failback_superseded="$MA_ROOT/builder-tasks/832-pc-both.superseded.md"
  [ ! -f "$scribe" ] || fail "pc validator both: scribe stray still claimable (.ready.md remains)"
  [ ! -f "$failback" ] || fail "pc validator both: fail-back stray still claimable (.ready.md remains)"
  [ -f "$scribe_superseded" ] || fail "pc validator both: scribe stray not renamed to .superseded.md"
  [ -f "$failback_superseded" ] || fail "pc validator both: fail-back stray not renamed to .superseded.md"

  rm -f -- "$failed" "$scribe_superseded" "$failback_superseded"
  pass "pc validator both: worker exit 0 with scribe AND fail-back handoffs -> failed, human notified, both strays neutralized to .superseded.md"
}

test_tick_postcondition_validator_neither() {
  local ready="$MA_ROOT/validator-notes/833-pc-neither.ready.md"
  local failed="$MA_ROOT/validator-notes/833-pc-neither.failed.md"
  _mk_ready "$ready" 833 pc-neither validator 1
  : >"$NOTIFY_LOG"

  local stub="$TMP_ROOT/stub-neither.sh"
  _mk_stub "$stub" ':'

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "pc validator neither: validator-loop exited nonzero"

  [ -f "$failed" ] || fail "pc validator neither: expected failed file, none found"
  grep -qi "NEITHER" "$failed" || fail "pc validator neither: reason missing 'NEITHER'"
  grep -q "833" "$NOTIFY_LOG" || fail "pc validator neither: notification missing issue number"

  rm -f -- "$failed"
  pass "pc validator neither: worker exit 0 with no handoff at all -> failed, human notified"
}

test_tick_postcondition_validator_failback_wrong_pass() {
  local ready="$MA_ROOT/validator-notes/834-pc-wrongpass.ready.md"
  local failed="$MA_ROOT/validator-notes/834-pc-wrongpass.failed.md"
  local handoff="$MA_ROOT/builder-tasks/834-pc-wrongpass.ready.md"
  _mk_ready "$ready" 834 pc-wrongpass validator 1
  : >"$NOTIFY_LOG"

  # Fail-back brief that did NOT advance the pass counter (still pass 1):
  # this is exactly the loop-forever hazard the pass-increment check closes.
  local stub="$TMP_ROOT/stub-wrongpass.sh"
  _mk_stub "$stub" "printf '%s\\n' '---' 'issue: 834' 'slug: pc-wrongpass' 'stage: builder' 'pass: 1' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'Fail-back brief.' >\"$handoff\""

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "pc validator wrong-pass: validator-loop exited nonzero"

  [ -f "$failed" ] || fail "pc validator wrong-pass: expected failed file, none found"
  grep -qi "expected 2" "$failed" || fail "pc validator wrong-pass: reason missing expected-pass detail"
  grep -q "834" "$NOTIFY_LOG" || fail "pc validator wrong-pass: notification missing issue number"

  rm -f -- "$failed" "$handoff"
  pass "pc validator wrong-pass: fail-back brief without pass++ -> failed, human notified"
}

# --- PM-sanctioned pass-override tests (max-pass ceiling) ---
#
# Directional contract for the override: a ready file at pass >= 3 is claimed
# only when it also carries `pm_approved_pass: N` equal to its own `pass`
# (positive case); an absent or mismatched field blocks exactly as before
# (negative cases). Only a human-authored brief can carry the field — no loop
# code path writes it — so the anti-runaway ceiling is preserved.

test_tick_pm_override_matching() {
  local ready="$MA_ROOT/validator-notes/850-pm-override-ok.ready.md"
  local done_file="$MA_ROOT/validator-notes/850-pm-override-ok.done.md"
  local blocked="$MA_ROOT/validator-notes/850-pm-override-ok.blocked.md"
  local handoff="$MA_ROOT/scribe-notes/850-pm-override-ok.ready.md"
  cat >"$ready" <<'EOF'
---
issue: 850
slug: pm-override-ok
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
pm_approved_pass: 3
---
Task body.
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$STUB_HANDOFF_MODE"
  # A valid scribe handoff lets the claimed (overridden) task reach done.
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$VALIDATOR_LOOP" || fail "pm override match: validator-loop exited nonzero"

  [ -f "$done_file" ] || fail "pm override match: expected done file (claim should proceed past the ceiling)"
  [ ! -f "$blocked" ] || fail "pm override match: file was blocked despite matching pm_approved_pass"
  [ -s "$STUB_ARGS_LOG" ] || fail "pm override match: worker was not invoked (claim did not proceed)"
  grep -q "pm-override" "$MA_ROOT/state.log" || fail "pm override match: override not logged distinctly (reason=pm-override missing)"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH"
  pass "pm override match: pass=3 + pm_approved_pass=3 -> claimed past the ceiling, override logged, completes to done"
}

test_tick_pm_override_absent_blocks() {
  local ready="$MA_ROOT/validator-notes/851-pm-override-absent.ready.md"
  local blocked="$MA_ROOT/validator-notes/851-pm-override-absent.blocked.md"
  # No pm_approved_pass field at all: the ceiling must block exactly as before.
  cat >"$ready" <<'EOF'
---
issue: 851
slug: pm-override-absent
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Task body.
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$STUB_HANDOFF_PATH"

  bash "$VALIDATOR_LOOP" || fail "pm override absent: validator-loop exited nonzero"

  [ -f "$blocked" ] || fail "pm override absent: expected blocked file, none found"
  [ ! -f "$ready" ] || fail "pm override absent: ready file still present"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "pm override absent: worker invoked despite the max-pass gate"
  grep -q "851" "$NOTIFY_LOG" || fail "pm override absent: notification missing issue number"

  rm -f -- "$blocked"
  pass "pm override absent: pass=3 with no pm_approved_pass -> blocked, worker never invoked"
}

test_tick_pm_override_mismatch_blocks() {
  local ready="$MA_ROOT/validator-notes/852-pm-override-mismatch.ready.md"
  local blocked="$MA_ROOT/validator-notes/852-pm-override-mismatch.blocked.md"
  # pm_approved_pass=2 authorizes pass 2, not this pass 3: still blocked. Guards
  # against a stale approval left from an earlier pass sneaking a claim through.
  cat >"$ready" <<'EOF'
---
issue: 852
slug: pm-override-mismatch
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
pm_approved_pass: 2
---
Task body.
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$STUB_HANDOFF_PATH"

  bash "$VALIDATOR_LOOP" || fail "pm override mismatch: validator-loop exited nonzero"

  [ -f "$blocked" ] || fail "pm override mismatch: expected blocked file, none found"
  [ ! -f "$ready" ] || fail "pm override mismatch: ready file still present"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "pm override mismatch: worker invoked despite mismatched pm_approved_pass"
  grep -q "852" "$NOTIFY_LOG" || fail "pm override mismatch: notification missing issue number"

  rm -f -- "$blocked"
  pass "pm override mismatch: pass=3 + pm_approved_pass=2 -> blocked, worker never invoked"
}

# --- Quota-defer tests (worker exits nonzero reporting session-limit
# exhaustion -> defer, not dead-letter; tick-level marker gating) ---
#
# Directional contract for the session-limit signature: a nonzero worker exit
# WITH the signature defers (requeue, no retry increment, marker set), a
# nonzero exit WITHOUT it dead-letters as before (asserted in
# test_tick_worker_failure). The marker lifecycle fails open — expired,
# malformed, and out-of-horizon markers are all cleared so a bad value can
# never wedge the loops permanently.

QUOTA_MARKER="$MA_ROOT/.quota-deferred-until"
QUOTA_SIGNATURE="You've hit your session limit · resets 3:00pm (America/New_York)"

test_tick_quota_defer_requeues() {
  local ready="$MA_ROOT/builder-tasks/840-quota-defer.ready.md"
  local claimed="$MA_ROOT/builder-tasks/840-quota-defer.claimed.md"
  local failed="$MA_ROOT/builder-tasks/840-quota-defer.failed.md"
  _mk_ready "$ready" 840 quota-defer builder 1

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"
  rm -f -- "$QUOTA_MARKER" "$STUB_HANDOFF_PATH"
  printf '%s\n' "$QUOTA_SIGNATURE" >"$STUB_OUTPUT"
  printf '1\n' >"$STUB_EXIT_FILE"

  bash "$BUILDER_LOOP" || fail "quota defer: builder-loop exited nonzero"

  [ -f "$ready" ] || fail "quota defer: task not requeued to .ready.md"
  [ ! -f "$claimed" ] || fail "quota defer: claimed file still present"
  [ ! -f "$failed" ] || fail "quota defer: task was dead-lettered instead of deferred"

  local retries
  retries=$(q_get "$ready" retries)
  [ "$retries" = "0" ] || fail "quota defer: retries incremented ($retries), should stay 0"

  [ -f "$QUOTA_MARKER" ] || fail "quota defer: defer marker not written"
  local until now
  until=$(cat "$QUOTA_MARKER")
  case "$until" in
    '' | *[!0-9]*) fail "quota defer: marker content '$until' is not numeric" ;;
  esac
  now=$(date +%s)
  [ "$until" -gt "$now" ] || fail "quota defer: marker epoch '$until' is not in the future"

  grep -qi "quota" "$NOTIFY_LOG" || fail "quota defer: no quota notification emitted"

  rm -f -- "$ready" "$QUOTA_MARKER" "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  pass "quota defer: worker exit 1 + session-limit signature -> requeued (retries unchanged), future-dated marker, human notified, not dead-lettered"
}

test_tick_quota_defer_active_skips() {
  local ready="$MA_ROOT/builder-tasks/841-quota-active.ready.md"
  local claimed="$MA_ROOT/builder-tasks/841-quota-active.claimed.md"
  _mk_ready "$ready" 841 quota-active builder 1

  : >"$STUB_ARGS_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$STUB_HANDOFF_PATH"
  # Marker one hour in the future: the tick must skip entirely.
  printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$QUOTA_MARKER"

  bash "$BUILDER_LOOP" || fail "quota active: builder-loop exited nonzero"

  [ -f "$ready" ] || fail "quota active: ready file consumed despite active defer marker"
  [ ! -f "$claimed" ] || fail "quota active: file was claimed despite active defer marker"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "quota active: worker invoked despite active defer marker"
  [ -f "$QUOTA_MARKER" ] || fail "quota active: marker removed while still in the future"

  rm -f -- "$ready" "$QUOTA_MARKER"
  pass "quota active: future-dated marker -> tick skips, file stays .ready.md, worker never invoked, marker preserved"
}

test_tick_quota_defer_expired_proceeds() {
  local ready="$MA_ROOT/builder-tasks/842-quota-expired.ready.md"
  local done_file="$MA_ROOT/builder-tasks/842-quota-expired.done.md"
  local handoff="$MA_ROOT/validator-notes/842-quota-expired.ready.md"
  _mk_ready "$ready" 842 quota-expired builder 1

  : >"$STUB_ARGS_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  # Past-dated marker: the tick must remove it and proceed normally. A valid
  # builder handoff lets the reclaimed task complete to done.
  printf '%s\n' "$(( $(date +%s) - 60 ))" >"$QUOTA_MARKER"
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$BUILDER_LOOP" || fail "quota expired: builder-loop exited nonzero"

  [ ! -f "$QUOTA_MARKER" ] || fail "quota expired: past-dated marker not removed"
  [ -f "$done_file" ] || fail "quota expired: task did not proceed to done after marker expiry"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH"
  pass "quota expired: past-dated marker -> removed, tick claims and completes normally"
}

test_tick_quota_defer_malformed_marker() {
  local ready="$MA_ROOT/builder-tasks/843-quota-malformed.ready.md"
  local done_file="$MA_ROOT/builder-tasks/843-quota-malformed.done.md"
  local handoff="$MA_ROOT/validator-notes/843-quota-malformed.ready.md"
  _mk_ready "$ready" 843 quota-malformed builder 1

  : >"$STUB_ARGS_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  printf 'not-a-number\n' >"$QUOTA_MARKER"
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$BUILDER_LOOP" || fail "quota malformed: builder-loop exited nonzero"

  [ ! -f "$QUOTA_MARKER" ] || fail "quota malformed: non-numeric marker not removed"
  [ -f "$done_file" ] || fail "quota malformed: tick did not proceed after malformed marker"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH"
  pass "quota malformed: non-numeric marker -> removed (fail open), tick proceeds normally"
}

test_tick_quota_defer_beyond_horizon() {
  # A numeric but implausibly-far-future marker must be treated as corrupt and
  # cleared, so a bad value can never pause the loops indefinitely (the
  # never-wedge safety property the Validator is asked to attack).
  local ready="$MA_ROOT/builder-tasks/844-quota-horizon.ready.md"
  local done_file="$MA_ROOT/builder-tasks/844-quota-horizon.done.md"
  local handoff="$MA_ROOT/validator-notes/844-quota-horizon.ready.md"
  _mk_ready "$ready" 844 quota-horizon builder 1

  : >"$STUB_ARGS_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  # Ten years out — far beyond the sane horizon.
  printf '%s\n' "$(( $(date +%s) + 315360000 ))" >"$QUOTA_MARKER"
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$BUILDER_LOOP" || fail "quota horizon: builder-loop exited nonzero"

  [ ! -f "$QUOTA_MARKER" ] || fail "quota horizon: out-of-horizon marker not removed"
  [ -f "$done_file" ] || fail "quota horizon: tick did not proceed past a wedged marker"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH"
  pass "quota horizon: numeric-but-implausible marker -> removed (never wedges loops), tick proceeds"
}

test_tick_idle() {
  find "$MA_ROOT/builder-tasks" "$MA_ROOT/validator-notes" "$MA_ROOT/scribe-notes" \
    -maxdepth 1 -type f \( -name '*.ready.md' -o -name '*.claimed.md' \) -delete

  local before_log_lines after_log_lines
  before_log_lines=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')

  local status=0
  bash "$BUILDER_LOOP" || status=$?
  [ "$status" -eq 0 ] || fail "tick idle: builder-loop expected exit 0, got $status"

  status=0
  bash "$VALIDATOR_LOOP" || status=$?
  [ "$status" -eq 0 ] || fail "tick idle: validator-loop expected exit 0, got $status"

  after_log_lines=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')
  [ "$after_log_lines" -eq "$before_log_lines" ] || fail "tick idle: state.log grew on idle ticks"

  pass "tick idle: empty inboxes -> both loops exit 0, no state.log growth"
}

# --- Environment-signature table (loop-lib _ml_classify_env_failure + the
# ml_tick failure branch): quota / auth / network all defer, non-signature
# dead-letters ---

test_classify_env_failure_signatures() {
  [ "$(_ml_classify_env_failure "you have hit your session limit today")" = quota ] \
    || fail "classify: session-limit not classified quota"
  [ "$(_ml_classify_env_failure "Error: Not logged in")" = auth ] \
    || fail "classify: 'Not logged in' not classified auth"
  [ "$(_ml_classify_env_failure "Please run /login to continue")" = auth ] \
    || fail "classify: 'Please run /login' not classified auth"
  [ "$(_ml_classify_env_failure "API Error: 500 upstream")" = network ] \
    || fail "classify: 'API Error' not classified network"
  [ "$(_ml_classify_env_failure "Connection closed mid-response")" = network ] \
    || fail "classify: 'Connection closed mid-response' not classified network"

  local out status=0
  out=$(_ml_classify_env_failure "worker asserted a real failure") || status=$?
  [ -z "$out" ] || fail "classify: a non-signature failure must print no class (got '$out')"
  [ "$status" -ne 0 ] || fail "classify: a non-signature failure must return nonzero"

  pass "classify: quota/auth/network signatures map to their class; a non-signature failure returns nonzero (dead-letters)"
}

test_tick_auth_defer() {
  local ready="$MA_ROOT/builder-tasks/845-auth-defer.ready.md"
  local claimed="$MA_ROOT/builder-tasks/845-auth-defer.claimed.md"
  local failed="$MA_ROOT/builder-tasks/845-auth-defer.failed.md"
  _mk_ready "$ready" 845 auth-defer builder 1

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"
  rm -f -- "$QUOTA_MARKER" "$STUB_HANDOFF_PATH"
  printf 'Error: Not logged in. Please run /login\n' >"$STUB_OUTPUT"
  printf '1\n' >"$STUB_EXIT_FILE"

  bash "$BUILDER_LOOP" || fail "auth defer: builder-loop exited nonzero"

  [ -f "$ready" ] || fail "auth defer: task not requeued to .ready.md"
  [ ! -f "$claimed" ] || fail "auth defer: claimed file still present"
  [ ! -f "$failed" ] || fail "auth defer: task dead-lettered instead of deferred"

  local retries
  retries=$(q_get "$ready" retries)
  [ "$retries" = "0" ] || fail "auth defer: retries incremented ($retries), should stay 0"

  [ -f "$QUOTA_MARKER" ] || fail "auth defer: defer marker not written"
  local until now
  until=$(cat "$QUOTA_MARKER"); now=$(date +%s)
  [ "$until" -gt "$now" ] || fail "auth defer: marker epoch '$until' not in the future"
  grep -q "auth-deferred" "$MA_ROOT/state.log" || fail "auth defer: q_log reason 'auth-deferred' missing (class not distinct)"
  grep -qi "authenticat\|login" "$NOTIFY_LOG" || fail "auth defer: notification does not mention auth/login"

  rm -f -- "$ready" "$QUOTA_MARKER" "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  pass "auth defer: nonzero exit + auth signature -> requeued (retries unchanged), 30-min marker, distinct reason, not dead-lettered"
}

test_tick_network_defer() {
  local ready="$MA_ROOT/builder-tasks/859-net-defer.ready.md"
  local claimed="$MA_ROOT/builder-tasks/859-net-defer.claimed.md"
  local failed="$MA_ROOT/builder-tasks/859-net-defer.failed.md"
  _mk_ready "$ready" 859 net-defer builder 1

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"
  rm -f -- "$QUOTA_MARKER" "$STUB_HANDOFF_PATH"
  printf 'API Error: Connection closed mid-response\n' >"$STUB_OUTPUT"
  printf '1\n' >"$STUB_EXIT_FILE"

  bash "$BUILDER_LOOP" || fail "network defer: builder-loop exited nonzero"

  [ -f "$ready" ] || fail "network defer: task not requeued to .ready.md"
  [ ! -f "$failed" ] || fail "network defer: task dead-lettered instead of deferred"

  local retries
  retries=$(q_get "$ready" retries)
  [ "$retries" = "0" ] || fail "network defer: retries incremented ($retries), should stay 0"

  [ -f "$QUOTA_MARKER" ] || fail "network defer: defer marker not written"
  grep -q "network-deferred" "$MA_ROOT/state.log" || fail "network defer: q_log reason 'network-deferred' missing (class not distinct)"
  grep -qi "network" "$NOTIFY_LOG" || fail "network defer: notification does not mention network"

  rm -f -- "$ready" "$QUOTA_MARKER" "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  pass "network defer: nonzero exit + network signature -> requeued (retries unchanged), 30-min marker, distinct reason, not dead-lettered"
}

# --- Founder-awareness TextMate opens on terminal loop transitions (loop-lib
# _ml_open_file_for_review / _ml_notify_file, wired into ml_tick's failed /
# blocked / deferral paths) ---
#
# osascript banners (ma_notify's default) are silently dropped by macOS TCC when
# launched from a launchd agent, so background failures surfaced nothing to the
# founder. Every founder-awareness terminal transition now ALSO opens a file in
# TextMate — the one channel proven to reach the founder from launchd. A ->failed
# / ->blocked opens the renamed handoff file; a deferral (no handoff file) appends
# to NOTIFICATIONS.md and opens THAT, rate-limited so a storm can't spam windows.
# `open`/`osascript` are PATH-shimmed suite-wide, so no test launches a real GUI.

test_failed_transition_opens_in_textmate() {
  local ready="$MA_ROOT/builder-tasks/861-notify-fail.ready.md"
  local failed="$MA_ROOT/builder-tasks/861-notify-fail.failed.md"
  _mk_ready "$ready" 861 notify-fail builder 1

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"
  rm -f -- "$STUB_HANDOFF_PATH"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"
  # A genuine worker failure (nonzero exit, NO env signature) so this dead-letters
  # to .failed.md rather than deferring.
  printf 'stub worker: plain failure, no session-limit signature\n' >"$STUB_OUTPUT"
  printf '7\n' >"$STUB_EXIT_FILE"

  bash "$BUILDER_LOOP" || fail "failed open: builder-loop should still exit 0 (q_fail recorded the outcome)"

  [ -f "$failed" ] || fail "failed open: expected .failed.md, none found"

  # The .failed.md is opened, then a bare `open -a TextMate` raises the window —
  # exactly twice, exactly the #884 pattern.
  local open_count
  open_count=$(wc -l <"$OPEN_STUB_LOG" | tr -d ' ')
  [ "$open_count" -eq 2 ] || fail "failed open: expected open invoked twice (file open + raise), got $open_count"
  grep -qF -- "-a TextMate $failed" "$OPEN_STUB_LOG" \
    || fail "failed open: open not invoked with '-a TextMate <failed path>'"
  grep -qxF -- "-a TextMate" "$OPEN_STUB_LOG" \
    || fail "failed open: no bare 'open -a TextMate' raise after the file open"
  grep -q "issue=861 stage=builder .*opened-textmate rc=0 raise_rc=0 file=861-notify-fail.failed.md" "$MA_ROOT/state.log" \
    || fail "failed open: audit line missing/incomplete (expected 'opened-textmate rc=0 raise_rc=0 file=861-notify-fail.failed.md')"

  # The raise must go through LaunchServices, never a TCC-blocked Apple event.
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "failed open: raise went through osascript — the TCC-blocked path is back"

  # ma_notify is an ADDITION, not a replacement: the banner still fires, and with
  # MA_NOTIFY_CMD set it routes through the stub (never osascript), unaffected.
  grep -q "861" "$NOTIFY_LOG" || fail "failed open: MA_NOTIFY_CMD banner did not fire (issue missing from NOTIFY_LOG)"
  grep -qi "worker failed" "$NOTIFY_LOG" || fail "failed open: banner text changed (expected 'worker failed')"

  rm -f -- "$failed" "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  pass "failed open: a genuine worker failure opens the .failed.md in TextMate (file open + raise), audits both exit codes, still fires the MA_NOTIFY_CMD banner, no osascript"
}

test_deferral_appends_and_opens_notifications() {
  local ready="$MA_ROOT/builder-tasks/862-notify-defer.ready.md"
  local nfile="$MA_ROOT/NOTIFICATIONS.md"
  _mk_ready "$ready" 862 notify-defer builder 1

  : >"$NOTIFY_LOG"
  : >"$STUB_ARGS_LOG"
  rm -f -- "$QUOTA_MARKER" "$STUB_HANDOFF_PATH" "$nfile" "${nfile}.opened"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"
  printf '%s\n' "$QUOTA_SIGNATURE" >"$STUB_OUTPUT"
  printf '1\n' >"$STUB_EXIT_FILE"

  bash "$BUILDER_LOOP" || fail "defer open: builder-loop exited nonzero"

  # A deferral has no handoff file, so the founder-awareness signal is an entry in
  # NOTIFICATIONS.md plus an open of that file.
  [ -f "$nfile" ] || fail "defer open: NOTIFICATIONS.md not created"
  grep -qi "quota exhausted" "$nfile" || fail "defer open: deferral message not appended to NOTIFICATIONS.md"
  [ -f "${nfile}.opened" ] || fail "defer open: throttle marker not written after the open"
  grep -qF -- "-a TextMate $nfile" "$OPEN_STUB_LOG" \
    || fail "defer open: open not invoked with '-a TextMate <NOTIFICATIONS.md>'"
  grep -qxF -- "-a TextMate" "$OPEN_STUB_LOG" \
    || fail "defer open: no bare 'open -a TextMate' raise after the file open"
  grep -q "issue=862 stage=builder .*notifications-opened-textmate rc=0 raise_rc=0" "$MA_ROOT/state.log" \
    || fail "defer open: audit line missing (expected 'notifications-opened-textmate rc=0 raise_rc=0')"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "defer open: raise went through osascript — the TCC-blocked path is back"

  rm -f -- "$ready" "$QUOTA_MARKER" "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$nfile" "${nfile}.opened"
  pass "defer open: an env deferral appends to NOTIFICATIONS.md and opens it in TextMate (file open + raise), audited, no osascript"
}

test_deferral_open_throttled_within_window() {
  local nfile="$MA_ROOT/NOTIFICATIONS.md"
  rm -f -- "$nfile" "${nfile}.opened"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"

  # First event: opens the editor and records the throttle marker.
  ( PATH="$OPEN_STUB_DIR:$PATH"; _ml_notify_file "first deferral" 870 builder 1 ) \
    || fail "throttle: first _ml_notify_file returned nonzero (must never fail the task)"
  local first_count
  first_count=$(wc -l <"$OPEN_STUB_LOG" | tr -d ' ')
  [ "$first_count" -eq 2 ] || fail "throttle: first event should open + raise (2 invocations), got $first_count"
  [ -f "${nfile}.opened" ] || fail "throttle: marker not recorded on the first open"

  # Second event INSIDE the window (marker is fresh): appended silently, no open.
  : >"$OPEN_STUB_LOG"
  ( PATH="$OPEN_STUB_DIR:$PATH"; _ml_notify_file "second deferral" 870 builder 1 ) \
    || fail "throttle: second _ml_notify_file returned nonzero"
  [ ! -s "$OPEN_STUB_LOG" ] \
    || fail "throttle: a second event inside the window wrongly re-opened the editor"
  local lines
  lines=$(grep -c . "$nfile")
  [ "$lines" -eq 2 ] || fail "throttle: expected both events appended to NOTIFICATIONS.md, got $lines line(s)"
  grep -q "notifications-appended-throttled" "$MA_ROOT/state.log" \
    || fail "throttle: suppressed open not audited as 'notifications-appended-throttled'"

  # A third event with the marker aged past the window re-opens (throttle is a
  # window, not a permanent latch).
  : >"$OPEN_STUB_LOG"
  printf '%s\n' "$(( $(date +%s) - 4000 ))" >"${nfile}.opened"
  ( PATH="$OPEN_STUB_DIR:$PATH"; MA_NOTIFY_OPEN_THROTTLE_SEC=1800 _ml_notify_file "third deferral" 870 builder 1 ) \
    || fail "throttle: third _ml_notify_file returned nonzero"
  [ -s "$OPEN_STUB_LOG" ] \
    || fail "throttle: an event AFTER the window expired did not re-open the editor"

  rm -f -- "$nfile" "${nfile}.opened"
  pass "throttle: first deferral opens; a second inside the window appends silently (no window spam); an event past the window re-opens"
}

# --- PM cycle-scoped pass-override grants (loop-lib gate + queue.sh clear) ---
#
# The grant lets a PM sanction cross the two legs of a pass: the builder gate
# records .pm-pass-grants/<base>-pass<N> when it honors the PM-authored field,
# and the validator leg — whose builder-authored handoff cannot legally carry
# the field — is honored via the grant. The grant is minted ONLY by that gate
# (property), and cleared when the validator leg of the pass reaches terminal.

test_grant_created_and_survives_builder_leg() {
  local ready="$MA_ROOT/builder-tasks/860-grant-xleg.ready.md"
  local done_file="$MA_ROOT/builder-tasks/860-grant-xleg.done.md"
  local handoff="$MA_ROOT/validator-notes/860-grant-xleg.ready.md"
  local grant="$MA_ROOT/.pm-pass-grants/860-grant-xleg-pass3"
  cat >"$ready" <<'EOF'
---
issue: 860
slug: grant-xleg
stage: builder
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
pm_approved_pass: 3
---
Pass-3 re-scope (marker-lint exempt at pass>1; name-integrity still coheres).
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT" "$grant"
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$BUILDER_LOOP" || fail "grant builder leg: builder-loop exited nonzero"

  [ -f "$done_file" ] || fail "grant builder leg: pass-3 with matching field not honored (no done file)"
  [ -e "$grant" ] || fail "grant builder leg: gate did not record the cycle-scoped grant"
  grep -q "pm-override" "$MA_ROOT/state.log" || fail "grant builder leg: override not logged"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH" "$grant"
  pass "grant builder leg: pass-3 field honored -> grant recorded and survives the builder leg's terminal (needed for cross-leg)"
}

test_grant_cross_leg_honored_and_cleared() {
  local ready="$MA_ROOT/validator-notes/861-grant-cross.ready.md"
  local done_file="$MA_ROOT/validator-notes/861-grant-cross.done.md"
  local handoff="$MA_ROOT/scribe-notes/861-grant-cross.ready.md"
  local grant="$MA_ROOT/.pm-pass-grants/861-grant-cross-pass3"
  mkdir -p "$MA_ROOT/.pm-pass-grants"
  : >"$grant"
  # No pm_approved_pass field: a builder-authored validator handoff may never
  # carry it. The pre-existing grant (recorded by this pass's builder leg) must
  # authorize the pass anyway.
  cat >"$ready" <<'EOF'
---
issue: 861
slug: grant-cross
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Validator handoff body.
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f -- "$STUB_EXIT_FILE" "$STUB_OUTPUT"
  printf '%s' "$handoff" >"$STUB_HANDOFF_PATH"

  bash "$VALIDATOR_LOOP" || fail "grant cross-leg: validator-loop exited nonzero"

  [ -f "$done_file" ] || fail "grant cross-leg: pre-existing grant did not authorize pass-3 without a field"
  [ ! -e "$grant" ] || fail "grant cross-leg: grant not cleared when the validator pass reached terminal (done)"
  grep -q "pm-override" "$MA_ROOT/state.log" || fail "grant cross-leg: override not logged"

  rm -f -- "$done_file" "$handoff" "$STUB_HANDOFF_PATH"
  pass "grant cross-leg: an existing grant honors a fieldless validator pass-3, and the grant is cleared at the validator leg's terminal"
}

test_grant_not_minted_without_field() {
  local ready="$MA_ROOT/validator-notes/862-grant-none.ready.md"
  local blocked="$MA_ROOT/validator-notes/862-grant-none.blocked.md"
  local grant="$MA_ROOT/.pm-pass-grants/862-grant-none-pass3"
  rm -f -- "$grant"
  cat >"$ready" <<'EOF'
---
issue: 862
slug: grant-none
stage: validator
pass: 3
retries: 0
owner: null
updated: 2026-07-05T14:03:00Z
---
Validator handoff body.
EOF

  : >"$STUB_ARGS_LOG"
  : >"$NOTIFY_LOG"
  rm -f -- "$STUB_HANDOFF_PATH"

  bash "$VALIDATOR_LOOP" || fail "grant none: validator-loop exited nonzero"

  [ -f "$blocked" ] || fail "grant none: pass-3 without field or grant should block"
  [ ! -e "$grant" ] || fail "grant none: a grant was minted with no PM field present (property violated)"
  [ ! -s "$STUB_ARGS_LOG" ] || fail "grant none: worker invoked despite the block"

  rm -f -- "$blocked"
  pass "grant none: pass-3 with neither a field nor a grant -> blocked, and no grant is minted (cannot-mint property)"
}

test_grant_only_writer_is_gate() {
  # Grep property: the ONLY line writing into .pm-pass-grants/ lives in
  # loop-lib.sh (inside _ml_grant_pass_override), and that helper is called from
  # exactly one site — the max-pass gate. No worker/loop/queue path else mints a
  # grant, so the loop can never authorize its own escalation.
  local writers
  writers=$(grep -rnF ': >"$MA_ROOT/.pm-pass-grants' "$SCRIPT_DIR"/*.sh | grep -v '/test-queue.sh:')
  [ -n "$writers" ] || fail "grant writer: could not find the grant-write line at all"
  [ "$(printf '%s\n' "$writers" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "grant writer: expected exactly one grant-write line, found:
$writers"
  printf '%s\n' "$writers" | grep -q '/loop-lib.sh:' \
    || fail "grant writer: the grant-write line is not in loop-lib.sh: $writers"

  # Count only non-comment references (the definition + the single call site);
  # comment mentions of the helper name are filtered out.
  local occurrences
  occurrences=$(grep -n '_ml_grant_pass_override' "$SCRIPT_DIR/loop-lib.sh" \
    | grep -vE ':[[:space:]]*#' | wc -l | tr -d ' ')
  [ "$occurrences" -eq 2 ] \
    || fail "grant writer: expected _ml_grant_pass_override in exactly two non-comment lines of loop-lib.sh (definition + one call), got $occurrences"

  pass "grant writer: the single grant-write line lives in loop-lib.sh, called from exactly one gate site (cannot-mint property, grep-verified)"
}

# --- STOP-with-findings as a typed fail-back (loop-lib
# _ml_body_has_stop_section + _ml_check_postcondition's rc typing + ml_tick's
# postcondition routing) ---
#
# One postcondition miss, two outcomes, split on ONE discriminator: did the
# worker append a findings/STOP section?
#   yes -> .blocked  a deliberate hand-back awaiting a re-scope (fail-back)
#   no   -> .failed  a worker that fabricated success (the D1 safety property)
# The negative half is the load-bearing one: if it ever flips to .blocked, the
# fabricated-success hole re-opens.

test_stop_failback_blocks_builder() {
  local ready="$MA_ROOT/builder-tasks/846-stop-failback.ready.md"
  local blocked="$MA_ROOT/builder-tasks/846-stop-failback.blocked.md"
  local failed="$MA_ROOT/builder-tasks/846-stop-failback.failed.md"
  _mk_ready "$ready" 846 stop-failback builder 1
  # Worker appends a STOP-shaped section to the claimed brief (its documented
  # response to a broken premise) and writes NO handoff.
  local stub="$TMP_ROOT/stub-stop.sh"
  _mk_stub "$stub" "printf '\n## FINDINGS\nStopped: premise stale, no handoff written.\n' >>\"\$1\""
  : >"$NOTIFY_LOG"

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "stop failback: builder-loop exited nonzero"

  [ -f "$blocked" ] || fail "stop failback: expected .blocked.md (typed fail-back), none found"
  [ ! -f "$failed" ] || fail "stop failback: a STOP-with-findings was recorded as .failed"
  grep -qi "fail-back" "$blocked" || fail "stop failback: block reason does not name the fail-back"
  grep -q "premise stale, no handoff written" "$blocked" \
    || fail "stop failback: the worker's findings were not preserved in the blocked file"
  if grep -qi "contract violation" "$blocked"; then
    fail "stop failback: a legitimate STOP is still framed as a contract violation"
  fi
  grep -q "846" "$NOTIFY_LOG" || fail "stop failback: notification missing issue number"

  rm -f -- "$blocked"
  pass "stop failback: builder appends findings and writes no handoff -> .blocked (fail-back), findings intact, NOT .failed"
}

test_silent_miss_still_fails_builder() {
  local ready="$MA_ROOT/builder-tasks/847-silent-miss.ready.md"
  local failed="$MA_ROOT/builder-tasks/847-silent-miss.failed.md"
  local blocked="$MA_ROOT/builder-tasks/847-silent-miss.blocked.md"
  _mk_ready "$ready" 847 silent-miss builder 1
  # Exit 0, no handoff, NO findings — the fabricated-success case.
  local stub="$TMP_ROOT/stub-silent.sh"
  _mk_stub "$stub" ":"
  : >"$NOTIFY_LOG"

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "silent miss: builder-loop exited nonzero"

  [ -f "$failed" ] || fail "silent miss: expected .failed.md, none found (D1 regression)"
  [ ! -f "$blocked" ] || fail "silent miss: a silent exit-0 was softened to .blocked (D1 regression)"
  grep -q "postcondition failed after worker exit 0" "$failed" \
    || fail "silent miss: generic postcondition reason missing"
  grep -q "847" "$NOTIFY_LOG" || fail "silent miss: notification missing issue number"

  rm -f -- "$failed"
  pass "silent miss: exit-0 with no handoff AND no findings -> still .failed (fabricated-success stays a failure)"
}

test_stop_failback_blocks_validator() {
  local ready="$MA_ROOT/validator-notes/848-stop-validator.ready.md"
  local blocked="$MA_ROOT/validator-notes/848-stop-validator.blocked.md"
  local failed="$MA_ROOT/validator-notes/848-stop-validator.failed.md"
  _mk_ready "$ready" 848 stop-validator validator 1
  local stub="$TMP_ROOT/stub-stop-validator.sh"
  _mk_stub "$stub" "printf '\n## STOP\nCannot review: the branch under review does not exist.\n' >>\"\$1\""
  : >"$NOTIFY_LOG"

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "stop failback validator: validator-loop exited nonzero"

  [ -f "$blocked" ] || fail "stop failback validator: expected .blocked.md, none found"
  [ ! -f "$failed" ] || fail "stop failback validator: recorded as .failed"
  grep -q "branch under review does not exist" "$blocked" \
    || fail "stop failback validator: findings not preserved"

  rm -f -- "$blocked"
  pass "stop failback validator: validator STOPs with findings (neither handoff written) -> .blocked, not .failed"
}

test_stop_failback_blocks_scribe() {
  local ready="$MA_ROOT/scribe-notes/849-stop-scribe.ready.md"
  local blocked="$MA_ROOT/scribe-notes/849-stop-scribe.blocked.md"
  local failed="$MA_ROOT/scribe-notes/849-stop-scribe.failed.md"
  _mk_ready "$ready" 849 stop-scribe scribe 1
  # A red-PR handback: no merge-approval pending file, findings appended.
  local stub="$TMP_ROOT/stub-stop-scribe.sh"
  _mk_stub "$stub" "printf '\n## HALTED\nPR checks are red; not opening the approval gate.\n' >>\"\$1\""
  : >"$NOTIFY_LOG"

  ( export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) \
    || fail "stop failback scribe: scribe-loop exited nonzero"

  [ -f "$blocked" ] || fail "stop failback scribe: expected .blocked.md, none found"
  [ ! -f "$failed" ] || fail "stop failback scribe: recorded as .failed"
  grep -q "PR checks are red" "$blocked" || fail "stop failback scribe: findings not preserved"

  rm -f -- "$blocked"
  pass "stop failback scribe: scribe STOPs with findings (no pending approval) -> .blocked, not .failed"
}

test_stop_section_scan_anchoring() {
  local f="$TMP_ROOT/stop-scan.md"

  # Positive: each historical heading variant, appended after the brief's
  # `## Handoff` section the way a worker actually writes one.
  local variant
  for variant in '## FINDINGS' '## STOP — premise stale' '## HALTED' \
                 '## Blocked: missing credentials' '## BLOCKED on a missing secret' \
                 '## Premise stale'; do
    printf '%s\n' '---' 'issue: 1' 'slug: s' '---' 'Body.' '' '## Handoff' 'Write it.' \
      '' "$variant" 'Detail.' >"$f"
    _ml_body_has_stop_section "$f" \
      || fail "stop scan: appended '$variant' not detected as a worker STOP section"
  done

  # Negative: a brief with no STOP-shaped heading at all.
  printf '%s\n' '---' 'issue: 1' 'slug: s' '---' 'Body.' '' '## Gates' 'Run tests.' \
    '' '## Handoff' 'Write it.' >"$f"
  if _ml_body_has_stop_section "$f"; then
    fail "stop scan: an untouched brief matched (every postcondition miss would soften to .blocked)"
  fi

  # Negative: the brief's OWN findings section, above `## Handoff` — a
  # Validator-authored fail-back brief routinely carries one, and it must not
  # let a later silent exit-0 masquerade as a worker hand-back.
  printf '%s\n' '---' 'issue: 1' 'slug: s' '---' 'Body.' '' '## Findings from pass 1' \
    'Fix these.' '' '## Handoff' 'Write it.' >"$f"
  if _ml_body_has_stop_section "$f"; then
    fail "stop scan: a fail-back brief's own pre-Handoff findings section matched (D1 hole)"
  fi

  # Negative: frontmatter is not body — a slug that spells a keyword is inert.
  printf '%s\n' '---' 'issue: 1' 'slug: stop-firstclass-failback' '---' 'Body.' \
    '' '## Handoff' 'Write it.' >"$f"
  if _ml_body_has_stop_section "$f"; then
    fail "stop scan: a frontmatter value was read as a heading"
  fi

  # Positive: a terse file with no `## Handoff` heading at all (a pass>1
  # re-scope, or a validator/scribe handoff) is scanned whole, so its STOP is
  # still typed as a fail-back.
  printf '%s\n' '---' 'issue: 1' 'slug: s' '---' 'Terse brief.' '' '## STOP' 'Detail.' >"$f"
  _ml_body_has_stop_section "$f" \
    || fail "stop scan: STOP in a file with no ## Handoff anchor was missed"

  # Negative: the queue's OWN transition footers. q_block/q_fail append these at
  # EOF, i.e. after `## Handoff`, so nothing but the footer's shape keeps them
  # from reading as worker-appended findings. Paired directionally with the
  # '## BLOCKED on a missing secret' positive above: same keyword, same case —
  # only the digit right after it separates a queue footer from a worker
  # heading, and the positive proves the exclusion did not eat the keyword.
  local footer
  for footer in '## BLOCKED 2026-07-21T08:00:00-0400' '## FAILED 2026-07-21T08:00:00-0400'; do
    printf '%s\n' '---' 'issue: 1' 'slug: s' '---' 'Body.' '' '## Handoff' 'Write it.' \
      '' "$footer" 'max pass ceiling reached' >"$f"
    if _ml_body_has_stop_section "$f"; then
      fail "stop scan: the queue's own '$footer' footer matched as worker findings (a requeued file would disable the discriminator)"
    fi
  done

  rm -f -- "$f"
  pass "stop scan: matches worker-appended STOP/FINDINGS/HALTED/BLOCKED/PREMISE headings; ignores frontmatter, untouched briefs, a brief's own pre-Handoff findings section, and q_block/q_fail's own '## BLOCKED|FAILED <ts>' footers"
}

test_requeued_blocked_footer_still_fails_builder() {
  local ready="$MA_ROOT/builder-tasks/850-requeue-footer.ready.md"
  local blocked="$MA_ROOT/builder-tasks/850-requeue-footer.blocked.md"
  local failed="$MA_ROOT/builder-tasks/850-requeue-footer.failed.md"
  _mk_ready "$ready" 850 requeue-footer builder 1

  # Fixture: the documented max-pass recovery. Produce the footer by calling
  # q_block itself — so this test tracks queue.sh's real footer format rather
  # than a copy of it — then requeue the file the way the PM does when it
  # sanctions a pass past the ceiling.
  q_block "$ready" "max pass ceiling reached" >/dev/null \
    || fail "requeue footer: q_block failed while building the fixture"
  [ -f "$blocked" ] || fail "requeue footer: fixture setup produced no .blocked.md"
  grep -q '^## BLOCKED ' "$blocked" \
    || fail "requeue footer: q_block no longer appends a '## BLOCKED <ts>' footer — premise moved, re-scope this test"
  mv -- "$blocked" "$ready"

  # Exit 0, no handoff, NO worker findings — the fabricated-success case, now
  # run against a brief that permanently carries the queue's own BLOCKED footer.
  local stub="$TMP_ROOT/stub-requeue-footer.sh"
  _mk_stub "$stub" ":"
  : >"$NOTIFY_LOG"

  ( export WORKER_CMD="$stub"; bash "$BUILDER_LOOP" ) \
    || fail "requeue footer: builder-loop exited nonzero"

  [ -f "$failed" ] || fail "requeue footer: expected .failed.md, none found (D1 regression)"
  [ ! -f "$blocked" ] \
    || fail "requeue footer: q_block's own '## BLOCKED <ts>' footer was read as worker findings, softening a silent exit-0 to .blocked (D1 off for every once-blocked task)"
  grep -q "postcondition failed after worker exit 0" "$failed" \
    || fail "requeue footer: generic postcondition reason missing"

  rm -f -- "$failed"
  pass "requeue footer: a requeued brief carrying q_block's own '## BLOCKED <ts>' footer still routes a silent exit-0 to .failed (D1 survives the max-pass requeue)"
}

test_validator_both_not_softened_by_findings() {
  local ready="$MA_ROOT/validator-notes/851-both-findings.ready.md"
  local failed="$MA_ROOT/validator-notes/851-both-findings.failed.md"
  local blocked="$MA_ROOT/validator-notes/851-both-findings.blocked.md"
  local scribe="$MA_ROOT/scribe-notes/851-both-findings.ready.md"
  local failback="$MA_ROOT/builder-tasks/851-both-findings.ready.md"
  _mk_ready "$ready" 851 both-findings validator 1
  : >"$NOTIFY_LOG"

  # The BOTH-handoffs contract violation, this time with findings appended. An
  # ambiguous routing state is not a halt: explaining it does not make it one,
  # so the typing must ignore the findings and keep this in .failed.
  local stub="$TMP_ROOT/stub-both-findings.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/scribe-notes\"
printf '%s\\n' '---' 'issue: 851' 'slug: both-findings' 'stage: scribe' 'pass: 1' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'S.' >\"$scribe\"
printf '%s\\n' '---' 'issue: 851' 'slug: both-findings' 'stage: builder' 'pass: 2' 'retries: 0' 'owner: null' 'updated: 2026-07-05T00:00:00Z' '---' 'B.' >\"$failback\"
printf '\\n## FINDINGS\\nWrote both handoffs; could not decide which route applies.\\n' >>\"\$1\""

  ( export WORKER_CMD="$stub"; bash "$VALIDATOR_LOOP" ) \
    || fail "both findings: validator-loop exited nonzero"

  [ -f "$failed" ] || fail "both findings: expected .failed.md, none found"
  [ ! -f "$blocked" ] \
    || fail "both findings: the BOTH-handoffs contract violation was softened to .blocked because the worker appended findings"
  grep -qi "BOTH" "$failed" || fail "both findings: reason missing 'BOTH'"

  # The strays must still be neutralized on this route.
  local scribe_superseded="$MA_ROOT/scribe-notes/851-both-findings.superseded.md"
  local failback_superseded="$MA_ROOT/builder-tasks/851-both-findings.superseded.md"
  [ -f "$scribe_superseded" ] || fail "both findings: scribe stray not renamed to .superseded.md"
  [ -f "$failback_superseded" ] || fail "both findings: fail-back stray not renamed to .superseded.md"

  rm -f -- "$failed" "$scribe_superseded" "$failback_superseded"
  pass "both findings: validator writes BOTH handoffs AND appends findings -> still .failed, strays neutralized (a contract violation is not a fail-back)"
}

test_tick_happy_path
test_tick_lane_busy
test_tick_worker_failure
test_v5_invalid_issue_slug_guard
test_tick_max_pass
test_tick_postcondition_builder_no_handoff
test_tick_postcondition_builder_malformed_handoff
test_tick_postcondition_builder_correct_handoff
test_tick_postcondition_validator_scribe_clear
test_tick_postcondition_validator_failback_ok
test_tick_postcondition_validator_both
test_tick_postcondition_validator_neither
test_tick_postcondition_validator_failback_wrong_pass
test_tick_pm_override_matching
test_tick_pm_override_absent_blocks
test_tick_pm_override_mismatch_blocks
test_tick_quota_defer_requeues
test_tick_quota_defer_active_skips
test_tick_quota_defer_expired_proceeds
test_tick_quota_defer_malformed_marker
test_tick_quota_defer_beyond_horizon
test_classify_env_failure_signatures
test_tick_auth_defer
test_tick_network_defer
test_failed_transition_opens_in_textmate
test_deferral_appends_and_opens_notifications
test_deferral_open_throttled_within_window
test_grant_created_and_survives_builder_leg
test_grant_cross_leg_honored_and_cleared
test_grant_not_minted_without_field
test_grant_only_writer_is_gate
test_stop_section_scan_anchoring
test_stop_failback_blocks_builder
test_silent_miss_still_fails_builder
test_requeued_blocked_footer_still_fails_builder
test_stop_failback_blocks_validator
test_validator_both_not_softened_by_findings
test_tick_idle

# --- Phase-3 scribe lane: push guard + human-gated merge -------------------
#
# Two safety properties are the adversarial focus here:
#   1. No code path merges without a HUMAN-produced .approved.md (proven by
#      never producing that suffix in any test's loop/worker path, and by the
#      red-checks / rejected / identity-mismatch cases leaving it unmerged).
#   2. The main-push guard cannot be bypassed by any ref spelling (proven by the
#      directional _ml_ref_targets_main pairs) and, end to end, a worker that
#      attempts a main push fails the task even if it also writes a pending
#      file.
# All remote calls are stubbed via a PATH shim — no test ever contacts a real
# remote.

SCRIBE_LOOP="$SCRIPT_DIR/scribe-loop.sh"
GUARD="$SCRIPT_DIR/git-push-guard.sh"
GH_STUB_DIR="$TMP_ROOT/scribe-ghbin"
GH_STUB_LOG="$TMP_ROOT/scribe-gh.log"
FAKE_REPO="$TMP_ROOT/fake-repo"
export GH_STUB_LOG
mkdir -p "$FAKE_REPO"

# _write_scribe_ghstub <expected-head> <checks-exit> <merge-exit>
# Write gh + git stubs into $GH_STUB_DIR. The gh stub simulates the small
# surface the merge path uses (`pr view` prints the head branch, `pr checks`
# exits per <checks-exit>, `pr merge`/`pr comment` per <merge-exit>/0); the git
# stub makes any `push`/`worktree` a logged no-op so the merge path never
# touches a real remote, delegating anything else to real git.
_write_scribe_ghstub() {
  local head="$1" checks_exit="$2" merge_exit="$3" head_sha="${4:-approvedsha}"
  mkdir -p "$GH_STUB_DIR"
  # `pr view` is field-aware: the merge gate asks for headRefName (gate 2) and
  # headRefOid (gate 3) through the same subcommand, so a stub that answered
  # both with the branch name would make the SHA gate impossible to exercise.
  cat >"$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_STUB_LOG"
case "\$1 \$2" in
  "pr view")
    case " \$* " in
      *headRefOid*)  printf '%s\n' "$head_sha" ;;
      *)             printf '%s\n' "$head" ;;
    esac
    ;;
  "pr checks") exit $checks_exit ;;
  "pr merge") exit $merge_exit ;;
  "pr comment") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_STUB_DIR/gh"
  cat >"$GH_STUB_DIR/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"$GH_STUB_LOG"
case " \$* " in
  *" push "* | *" worktree "*) exit 0 ;;
esac
exec /usr/bin/git "\$@"
EOF
  chmod +x "$GH_STUB_DIR/git"
}

# _write_scribe_ghstub_cwdaware <expected-head> <checks-exit> <merge-exit>
# Like _write_scribe_ghstub, but the gh stub only "resolves the repo" when it is
# invoked from a directory containing a .gh-repo-sentinel file. This emulates
# real gh, which reads the target repo from the current directory's git remotes
# and errors out with no repo context elsewhere (e.g. the launchd cwd `/`). The
# stub is therefore sensitive to whether the merge path cd'd into repo_root
# before each gh call, so a regression that drops the cd fails the test instead
# of passing silently against a cwd-blind stub.
_write_scribe_ghstub_cwdaware() {
  local head="$1" checks_exit="$2" merge_exit="$3" head_sha="${4:-approvedsha}"
  mkdir -p "$GH_STUB_DIR"
  cat >"$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s (cwd=%s)\n' "\$*" "\$PWD" >>"$GH_STUB_LOG"
if [ ! -e .gh-repo-sentinel ]; then
  printf 'gh: no repo context at %s\n' "\$PWD" >>"$GH_STUB_LOG"
  exit 1
fi
case "\$1 \$2" in
  "pr view")
    # Field-aware for the same reason as _write_scribe_ghstub: gate 2 asks for
    # headRefName and gate 3 for headRefOid through the same subcommand.
    case " \$* " in
      *headRefOid*)  printf '%s\n' "$head_sha" ;;
      *)             printf '%s\n' "$head" ;;
    esac
    ;;
  "pr checks") exit $checks_exit ;;
  "pr merge") exit $merge_exit ;;
  "pr comment") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_STUB_DIR/gh"
  cat >"$GH_STUB_DIR/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"$GH_STUB_LOG"
case " \$* " in
  *" push "* | *" worktree "*) exit 0 ;;
esac
exec /usr/bin/git "\$@"
EOF
  chmod +x "$GH_STUB_DIR/git"
}

test_ref_targets_main_positive() {
  # Every spelling that MUST resolve to "targets main". Space-split into args on
  # purpose (each string is a full `git push` argument vector).
  local spellings=(
    "origin main"
    "origin heads/main"
    "origin refs/heads/main"
    "origin HEAD:main"
    "origin HEAD:refs/heads/main"
    "origin +main"
    "origin +refs/heads/main"
    "origin main:main"
    "origin :main"
    "--force origin main"
    "-f origin refs/heads/main"
    "origin --delete main"
    "origin somebranch:heads/main"
  )
  local s
  for s in "${spellings[@]}"; do
    # shellcheck disable=SC2086 # deliberate word-split into an argument vector
    if ! _ml_ref_targets_main $s; then
      fail "ref-targets-main positive: '$s' must be caught but was not"
    fi
  done
  pass "ref-targets-main positive: all ${#spellings[@]} main spellings caught (heads/, refs/heads/, HEAD:, :main, +force, --delete)"
}

test_ref_targets_main_negative() {
  # Non-main refspecs that must NOT be caught — including near-misses that share
  # the substring "main" but are different branches.
  local spellings=(
    "origin auto/835-phase3-middle-step"
    "origin mainline"
    "origin feature/main-thing"
    "-u origin auto/1-x"
    "origin HEAD:auto/1-x"
    "origin auto/1-x:auto/1-x"
    "origin develop"
    "origin :auto/1-x"
    "origin --delete auto/1-x"
    "origin +auto/1-x"
  )
  local s
  for s in "${spellings[@]}"; do
    # shellcheck disable=SC2086 # deliberate word-split into an argument vector
    if _ml_ref_targets_main $s; then
      fail "ref-targets-main negative: '$s' must NOT be caught but was"
    fi
  done
  pass "ref-targets-main negative: no non-main refspec falsely caught (mainline / feature/main-thing / auto/*)"
}

test_guarded_push_refuses_main() {
  : >"$NOTIFY_LOG"
  local marker="$MA_ROOT/.push-violations/880-guard-refuse.violation"
  rm -f -- "$marker"

  local status=0
  ml_guarded_push 880 guard-refuse origin refs/heads/main || status=$?
  [ "$status" -ne 0 ] || fail "guarded push refuse: expected nonzero for a main push"
  [ -f "$marker" ] || fail "guarded push refuse: violation marker not written"
  grep -qi "REFUSED" "$NOTIFY_LOG" || fail "guarded push refuse: no LOUD notification"
  grep -q "issue=880 stage=scribe remote reason=push" "$MA_ROOT/state.log" || fail "guarded push refuse: refusal not audited to state.log"

  rm -f -- "$marker"
  pass "guarded push refuse: main push -> marker + LOUD notify + audit line, remote never contacted (returns nonzero)"
}

test_guarded_push_allows_branch() {
  _write_scribe_ghstub "auto/1-x" 0 0
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"
  local marker="$MA_ROOT/.push-violations/881-guard-allow.violation"
  rm -f -- "$marker"

  local status=0
  ( PATH="$GH_STUB_DIR:$PATH"; ml_guarded_push 881 guard-allow origin auto/1-x ) || status=$?
  [ "$status" -eq 0 ] || fail "guarded push allow: expected 0 for a non-main push, got $status"
  grep -q "git push origin auto/1-x" "$GH_STUB_LOG" || fail "guarded push allow: real git push not invoked"
  [ ! -f "$marker" ] || fail "guarded push allow: violation marker wrongly written for a branch push"
  grep -q "issue=881 stage=scribe remote reason=push" "$MA_ROOT/state.log" || fail "guarded push allow: push not audited"

  pass "guarded push allow: non-main branch push -> audited and executed via real git, no violation"
}

test_scribe_pending_written() {
  local ready="$MA_ROOT/scribe-notes/860-scribe-happy.ready.md"
  local done_file="$MA_ROOT/scribe-notes/860-scribe-happy.done.md"
  local pending="$MA_ROOT/merge-approvals/860-scribe-happy.pending.md"
  _mk_ready "$ready" 860 scribe-happy scribe 1
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  : >"$NOTIFY_LOG"

  local stub="$TMP_ROOT/stub-scribe-happy.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/merge-approvals\"
printf '%s\\n' '---' 'issue: 860' 'slug: scribe-happy' 'pr: 861' 'pr_url: http://x/pull/861' 'head_sha: approvedsha' 'checks: passing' 'branch: auto/860-scribe-happy' '---' 'Pending: awaiting human approval.' >\"$pending\""

  # Shim `open` onto PATH: this test's worker writes a pending file, so the claim
  # reaches q_done and traverses the scribe success branch that opens the pending
  # in TextMate. Without the stub, the run launches a real GUI window.
  _write_open_stub 0
  ( PATH="$OPEN_STUB_DIR:$PATH"; export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) \
    || fail "scribe happy: scribe-loop exited nonzero"

  [ -f "$done_file" ] || fail "scribe happy: expected scribe-note done file, none found"
  [ -f "$pending" ] || fail "scribe happy: pending approval file missing"
  [ ! -f "$MA_ROOT/scribe-notes/860-scribe-happy.claimed.md" ] || fail "scribe happy: claimed file still present"

  rm -f -- "$done_file" "$pending" "${pending}.reminded"
  pass "scribe happy: ready -> worker pushes/PRs and writes pending approval (NO merge) -> scribe-note done"
}

test_scribe_push_main_fails() {
  local ready="$MA_ROOT/scribe-notes/864-scribe-pushmain.ready.md"
  local failed="$MA_ROOT/scribe-notes/864-scribe-pushmain.failed.md"
  local pending="$MA_ROOT/merge-approvals/864-scribe-pushmain.pending.md"
  local marker="$MA_ROOT/.push-violations/864-scribe-pushmain.violation"
  _mk_ready "$ready" 864 scribe-pushmain scribe 1
  mkdir -p "$MA_ROOT/merge-approvals"
  : >"$NOTIFY_LOG"

  # The worker routes a push to main through the real guard, then IGNORES its
  # refusal and writes a pending file and exits 0 anyway. The loop must still
  # fail the task, because the guard recorded a violation marker this run.
  local stub="$TMP_ROOT/stub-scribe-pushmain.sh"
  _mk_stub "$stub" "\"$GUARD\" 864 scribe-pushmain origin main || true
mkdir -p \"$MA_ROOT/merge-approvals\"
printf '%s\\n' '---' 'issue: 864' 'slug: scribe-pushmain' 'pr: 900' 'branch: auto/864-scribe-pushmain' '---' 'body' >\"$pending\""

  ( export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) || fail "scribe push-main: scribe-loop exited nonzero (q_fail should have recorded it)"

  [ -f "$failed" ] || fail "scribe push-main: expected failed file, none found"
  grep -qi "push to main" "$failed" || fail "scribe push-main: fail reason missing push-guard detail"
  grep -qi "REFUSED" "$NOTIFY_LOG" || fail "scribe push-main: no LOUD notification"

  rm -f -- "$failed" "$pending" "$marker"
  pass "scribe push-main: worker attempts a main push -> violation marker -> task FAILED + notify, even though a pending file was written"
}

test_scribe_push_violation_not_softened_by_findings() {
  local ready="$MA_ROOT/scribe-notes/865-push-findings.ready.md"
  local failed="$MA_ROOT/scribe-notes/865-push-findings.failed.md"
  local blocked="$MA_ROOT/scribe-notes/865-push-findings.blocked.md"
  local marker="$MA_ROOT/.push-violations/865-push-findings.violation"
  _mk_ready "$ready" 865 push-findings scribe 1
  : >"$NOTIFY_LOG"

  # The guard breach a worker then explains away. The push to main is refused,
  # the scribe appends findings and exits 0 — exactly the exit-code
  # unreliability the STOP discriminator exists to work around. The findings get
  # no vote here: a guard breach is not a hand-back awaiting a re-scope, so it
  # must stay .failed in the state, the reason line and the notification.
  local stub="$TMP_ROOT/stub-push-findings.sh"
  _mk_stub "$stub" "\"$GUARD\" 865 push-findings origin main || true
printf '\\n## FINDINGS\\nThe push guard refused my push to main; handing back.\\n' >>\"\$1\""

  ( export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) \
    || fail "push violation findings: scribe-loop exited nonzero"

  [ -f "$failed" ] || fail "push violation findings: expected .failed.md, none found"
  [ ! -f "$blocked" ] \
    || fail "push violation findings: a refused main-push was softened to .blocked because the worker appended findings"
  grep -qi "push to main" "$failed" || fail "push violation findings: fail reason missing push-guard detail"
  if grep -qi "fail-back" "$failed"; then
    fail "push violation findings: a main-push guard breach is framed as a routine fail-back"
  fi
  grep -qi "REFUSED" "$NOTIFY_LOG" || fail "push violation findings: no LOUD notification"

  rm -f -- "$failed" "$marker"
  pass "push violation findings: refused main push + appended findings + exit 0 -> .failed, never softened to .blocked (the guard rule outranks the findings)"
}

test_run_worker_exports_ma_root_for_guard() {
  # Regression for the MA_ROOT split. The scribe worker runs with cwd = the
  # worktree and routes pushes through the guard, which sources queue.sh.
  # queue.sh derives MA_ROOT from its own BASH_SOURCE via `: "${MA_ROOT:=...}"`;
  # sourced by a RELATIVE path from the worktree cwd, that resolves to
  # <worktree>/multi-agent, NOT the parent root the loop reads. Unless
  # _ml_run_worker exports the parent MA_ROOT into the worker's environment, a
  # refused main-push writes its violation marker and audit line into the
  # worktree, where the scribe postcondition never looks — the task is NOT
  # failed and the parent state.log audit is incomplete.
  #
  # Crucially, this test does NOT rely on the harness's single shared
  # `export MA_ROOT` (line 21): that global export is exactly what masks the
  # split in test_scribe_push_main_fails. It un-exports MA_ROOT inside a
  # subshell (keeping the value as a plain shell variable, the way queue.sh
  # leaves it in the real loop) so ONLY an explicit export inside
  # _ml_run_worker can reach the worker. A distinct parent root and a separate
  # worktree with its own copy of the scripts make the split observable: a
  # marker in the parent means MA_ROOT was propagated; a marker in the worktree
  # means it was not.
  local parent_root worktree stub claimed
  parent_root="$TMP_ROOT/split-parent/multi-agent"
  worktree="$TMP_ROOT/split-worktree"
  mkdir -p "$parent_root" "$worktree/scripts/multi-agent"
  # merge-policy.sh comes along because loop-lib.sh sources it: the guard sources
  # loop-lib, so a checkout carrying loop-lib without merge-policy cannot even
  # load the guard. Copying it here mirrors the real deployment (the two files
  # ship together); omitting it would make this test fail for a reason that has
  # nothing to do with the MA_ROOT split it exists to prove.
  cp "$SCRIPT_DIR/queue.sh" "$SCRIPT_DIR/loop-lib.sh" "$SCRIPT_DIR/merge-policy.sh" \
    "$SCRIPT_DIR/git-push-guard.sh" "$worktree/scripts/multi-agent/"
  chmod +x "$worktree/scripts/multi-agent/git-push-guard.sh"

  # A WORKER_CMD stub that reproduces the two conditions that trigger the split:
  # cwd = the worktree (the real claude path cd's there; the WORKER_CMD branch
  # does not, so the stub does it), and the guard invoked by a RELATIVE path.
  stub="$TMP_ROOT/stub-split-guard.sh"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
cd "$worktree" || exit 1
scripts/multi-agent/git-push-guard.sh 890 guard-split origin main || true
exit 0
EOF
  chmod +x "$stub"

  claimed="$parent_root/scribe-notes/890-guard-split.claimed.md"

  (
    # Keep MA_ROOT's value but drop it from the environment, so the worker can
    # only see it if _ml_run_worker re-exports it (the fix under test).
    export -n MA_ROOT
    MA_ROOT="$parent_root"
    export WORKER_CMD="$stub"
    _ml_run_worker scribe "$claimed" "$TMP_ROOT/split-parent" "$worktree" 890 guard-split >/dev/null
  )

  local parent_marker worktree_marker
  parent_marker="$parent_root/.push-violations/890-guard-split.violation"
  worktree_marker="$worktree/multi-agent/.push-violations/890-guard-split.violation"

  [ -f "$parent_marker" ] || fail "ma_root split: violation marker did not land in the parent MA_ROOT (postcondition would miss a main-push)"
  [ ! -f "$worktree_marker" ] || fail "ma_root split: violation marker leaked into the worktree MA_ROOT (guard resolved the wrong root)"

  # The audit line must also reach the parent state.log, not the worktree's.
  grep -q "issue=890 stage=scribe remote reason=push" "$parent_root/state.log" \
    || fail "ma_root split: refusal not audited to the parent state.log"
  [ ! -f "$worktree/multi-agent/state.log" ] \
    || fail "ma_root split: audit line leaked into the worktree state.log"

  # End to end: the scribe postcondition, reading the parent MA_ROOT, now finds
  # the marker and fails the task — the property test_scribe_push_main_fails only appears to prove.
  local status=0
  ( export -n MA_ROOT; MA_ROOT="$parent_root"; _ml_check_postcondition scribe 890 guard-split 1 ) \
    >/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "ma_root split: postcondition did not fail the task despite a recorded main-push violation"

  rm -rf -- "$TMP_ROOT/split-parent" "$worktree" "$stub"
  pass "ma_root split: _ml_run_worker exports MA_ROOT so a relative-path guard from the worktree writes its violation + audit to the PARENT root (postcondition fails the task); no leak into the worktree"
}

test_scribe_approval_green_merges() {
  local appr="$MA_ROOT/merge-approvals/870-scribe-appr.approved.md"
  local merged="$MA_ROOT/merge-approvals/870-scribe-appr.merged.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$appr" <<'EOF'
---
issue: 870
slug: scribe-appr
pr: 910
pr_url: http://x/pull/910
head_sha: approvedsha
checks: passing
branch: auto/870-scribe-appr
---
Approved by a human (renamed .pending.md -> .approved.md).
EOF

  _write_scribe_ghstub "auto/870-scribe-appr" 0 0
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "scribe approval green: approval not renamed to .merged.md"
  [ ! -f "$appr" ] || fail "scribe approval green: .approved.md still present after merge"
  grep -q "gh pr merge 910 --squash" "$GH_STUB_LOG" || fail "scribe approval green: gh pr merge --squash not invoked"
  grep -q "gh pr comment 910" "$GH_STUB_LOG" || fail "scribe approval green: audit comment not posted"
  grep -q "push origin --delete auto/870-scribe-appr" "$GH_STUB_LOG" || fail "scribe approval green: remote branch not deleted"
  grep -q "issue=870 stage=scribe remote reason=merge" "$MA_ROOT/state.log" || fail "scribe approval green: merge not audited"
  grep -qi "merged" "$NOTIFY_LOG" || fail "scribe approval green: no merge notification"

  rm -f -- "$merged"
  pass "scribe approval green: .approved.md + green checks + matching head -> squash-merge, audit comment, branch delete, .merged.md, audit + notify"
}

test_scribe_approval_red_no_merge() {
  local appr="$MA_ROOT/merge-approvals/871-scribe-red.approved.md"
  local merged="$MA_ROOT/merge-approvals/871-scribe-red.merged.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  cat >"$appr" <<'EOF'
---
issue: 871
slug: scribe-red
pr: 911
pr_url: http://x/pull/911
head_sha: approvedsha
checks: passing
branch: auto/871-scribe-red
---
Approved, but checks have since gone red at current head.
EOF

  # checks-exit 1 => `gh pr checks` reports not-green.
  _write_scribe_ghstub "auto/871-scribe-red" 1 0
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$appr" ] || fail "scribe approval red: .approved.md was consumed despite red checks"
  [ ! -f "$merged" ] || fail "scribe approval red: merged despite red checks"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe approval red: gh pr merge invoked despite red checks"
  grep -qi "not green" "$NOTIFY_LOG" || fail "scribe approval red: no not-green notification"

  rm -f -- "$appr"
  pass "scribe approval red: .approved.md + red checks at current head -> NO merge, approval left intact, human notified"
}

test_scribe_approval_head_mismatch_no_merge() {
  # Identity gate: the live PR head no longer matches the expected auto branch
  # (a recycled/renumbered PR). Must NOT merge even though checks would be green.
  local appr="$MA_ROOT/merge-approvals/874-scribe-mismatch.approved.md"
  local merged="$MA_ROOT/merge-approvals/874-scribe-mismatch.merged.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  cat >"$appr" <<'EOF'
---
issue: 874
slug: scribe-mismatch
pr: 914
pr_url: http://x/pull/914
head_sha: approvedsha
checks: passing
branch: auto/874-scribe-mismatch
---
Approved, but the live PR head has drifted.
EOF

  # gh pr view returns a DIFFERENT head than expected.
  _write_scribe_ghstub "auto/999-someone-else" 0 0
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$appr" ] || fail "scribe head-mismatch: .approved.md consumed despite head mismatch"
  [ ! -f "$merged" ] || fail "scribe head-mismatch: merged despite head mismatch"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe head-mismatch: gh pr merge invoked despite head mismatch"
  grep -qi "!= expected" "$NOTIFY_LOG" || fail "scribe head-mismatch: no identity-mismatch notification"

  rm -f -- "$appr"
  pass "scribe head-mismatch: live PR head != expected auto branch -> NO merge, approval intact, human notified"
}

test_scribe_approval_from_nonrepo_cwd_merges() {
  # Regression: under launchd the tick shell's cwd is `/` (the plists set no
  # WorkingDirectory), where gh has no repo context. The merge path must cd into
  # repo_root before every gh call. Directional: the cwd-aware stub only
  # succeeds when invoked from the repo (sentinel present), so a merge here
  # PROVES the code cd'd — dropping the cd would leave gh in the non-repo cwd,
  # fail the head lookup, and skip the merge.
  local appr="$MA_ROOT/merge-approvals/875-scribe-cwd.approved.md"
  local merged="$MA_ROOT/merge-approvals/875-scribe-cwd.merged.md"
  local nonrepo="$TMP_ROOT/nonrepo-cwd"
  mkdir -p "$MA_ROOT/merge-approvals" "$nonrepo"
  rm -f -- "$MA_ROOT/.quota-deferred-until" "$nonrepo/.gh-repo-sentinel"
  : >"$FAKE_REPO/.gh-repo-sentinel"
  cat >"$appr" <<'EOF'
---
issue: 875
slug: scribe-cwd
pr: 915
pr_url: http://x/pull/915
head_sha: approvedsha
checks: passing
branch: auto/875-scribe-cwd
---
Approved by a human; the loop runs from a non-repo cwd.
EOF

  _write_scribe_ghstub_cwdaware "auto/875-scribe-cwd" 0 0
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  # Directional guard: confirm the stub really DOES fail outside the repo, so a
  # later merge success genuinely required the code to cd into repo_root (not a
  # cwd-blind stub that passes regardless).
  ( cd "$nonrepo"; PATH="$GH_STUB_DIR:$PATH"; gh pr view 915 --json headRefName >/dev/null 2>&1 ) \
    && fail "scribe cwd regression: stub wrongly resolved a repo from a non-repo cwd (test cannot detect the regression)"

  # Run the merge half from a NON-repo cwd, exactly as launchd would.
  ( cd "$nonrepo"; PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "scribe cwd regression: approval not merged when the tick ran from a non-repo cwd (cd into repo_root missing?)"
  [ ! -f "$appr" ] || fail "scribe cwd regression: .approved.md still present after merge"
  grep -q "gh pr merge 915 --squash" "$GH_STUB_LOG" || fail "scribe cwd regression: gh pr merge not invoked from the repo cwd"
  grep -q "issue=875 stage=scribe remote reason=merge detail=MERGED" "$MA_ROOT/state.log" || fail "scribe cwd regression: merge not audited"

  rm -f -- "$merged" "$FAKE_REPO/.gh-repo-sentinel"
  pass "scribe cwd regression: approval merges when the tick runs from a non-repo cwd (gh calls cd into repo_root first)"
}

test_scribe_approval_gh_unavailable() {
  # gh itself errors on the head lookup (network/auth/bad cwd): the empty result
  # must be read as "unavailable", NOT as a head mismatch. A distinct
  # SKIPPED-gh-unavailable reason is audited and the approval is left intact to
  # retry on the next tick.
  local appr="$MA_ROOT/merge-approvals/876-scribe-ghdown.approved.md"
  local merged="$MA_ROOT/merge-approvals/876-scribe-ghdown.merged.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$appr" <<'EOF'
---
issue: 876
slug: scribe-ghdown
pr: 916
pr_url: http://x/pull/916
head_sha: approvedsha
checks: passing
branch: auto/876-scribe-ghdown
---
Approved, but gh is unavailable at merge time.
EOF

  # gh stub: `pr view` exits nonzero with empty output — gh unavailable.
  mkdir -p "$GH_STUB_DIR"
  cat >"$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_STUB_LOG"
case "\$1 \$2" in
  "pr view") exit 3 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_STUB_DIR/gh"
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$appr" ] || fail "scribe gh-unavailable: .approved.md consumed despite a failed head lookup"
  [ ! -f "$merged" ] || fail "scribe gh-unavailable: merged despite a failed head lookup"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe gh-unavailable: gh pr merge invoked despite a failed head lookup"
  grep -q "issue=876 stage=scribe remote reason=merge detail=SKIPPED-gh-unavailable" "$MA_ROOT/state.log" \
    || fail "scribe gh-unavailable: SKIPPED-gh-unavailable not audited to state.log"

  rm -f -- "$appr"
  pass "scribe gh-unavailable: gh head lookup errors -> SKIPPED-gh-unavailable audited, no merge, approval intact"
}

test_scribe_approval_refusals_audited() {
  # Task 2: every remaining NOT-merged path writes a distinct, greppable
  # state.log reason so a refusal is never invisible. Drives gate-1 branch
  # mismatch, live-head mismatch, and merge-command failure, asserting each
  # one's audit line plus an intact approval.
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"

  # --- Gate 1: PR present but the file's branch != expected auto branch ------
  local a1="$MA_ROOT/merge-approvals/877-scribe-refuse.approved.md"
  cat >"$a1" <<'EOF'
---
issue: 877
slug: scribe-refuse
pr: 917
branch: auto/999-wrong-branch
head_sha: approvedsha
---
Approval whose branch field does not match the canonical auto branch.
EOF
  _write_scribe_ghstub "auto/877-scribe-refuse" 0 0
  : >"$GH_STUB_LOG"; : >"$NOTIFY_LOG"
  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  [ -f "$a1" ] || fail "scribe refusals: branch-mismatch approval consumed"
  grep -q "gh pr view" "$GH_STUB_LOG" && fail "scribe refusals: gh called despite a gate-1 branch mismatch"
  grep -q "issue=877 stage=scribe remote reason=merge detail=SKIPPED-no-pr-or-branch-mismatch" "$MA_ROOT/state.log" \
    || fail "scribe refusals: SKIPPED-no-pr-or-branch-mismatch not audited"
  rm -f -- "$a1"

  # --- Gate 2: live PR head has drifted from the expected auto branch --------
  local a2="$MA_ROOT/merge-approvals/878-scribe-drift.approved.md"
  cat >"$a2" <<'EOF'
---
issue: 878
slug: scribe-drift
pr: 918
branch: auto/878-scribe-drift
head_sha: approvedsha
---
Approval whose live PR head has drifted.
EOF
  _write_scribe_ghstub "auto/999-someone-else" 0 0
  : >"$GH_STUB_LOG"; : >"$NOTIFY_LOG"
  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  [ -f "$a2" ] || fail "scribe refusals: head-mismatch approval consumed"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe refusals: merge invoked despite a head mismatch"
  grep -q "issue=878 stage=scribe remote reason=merge detail=SKIPPED-live-head-mismatch" "$MA_ROOT/state.log" \
    || fail "scribe refusals: SKIPPED-live-head-mismatch not audited"
  rm -f -- "$a2"

  # --- Gate 3a: the branch moved to a commit nobody approved -----------------
  # The regression this guards: gates 1 and 2 are branch-scoped, so before this
  # gate existed, a push landing on an approved branch between the human's
  # rename and the merge tick merged under the earlier commit's approval.
  local a2b="$MA_ROOT/merge-approvals/8781-scribe-shamoved.approved.md"
  cat >"$a2b" <<'EOF'
---
issue: 8781
slug: scribe-shamoved
pr: 9181
branch: auto/8781-scribe-shamoved
head_sha: approvedsha
---
Approval whose branch has since been pushed to a different commit.
EOF
  # Right PR, right branch, green checks — only the commit differs.
  _write_scribe_ghstub "auto/8781-scribe-shamoved" 0 0 "someothersha"
  : >"$GH_STUB_LOG"; : >"$NOTIFY_LOG"
  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  [ -f "$a2b" ] || fail "scribe refusals: sha-moved approval consumed"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe refusals: merge invoked despite the head SHA moving"
  grep -q "issue=8781 stage=scribe remote reason=merge detail=SKIPPED-head-sha-moved" "$MA_ROOT/state.log" \
    || fail "scribe refusals: SKIPPED-head-sha-moved not audited"
  rm -f -- "$a2b"

  # --- Gate 3b: approval carries no head_sha at all — fail closed -----------
  local a2c="$MA_ROOT/merge-approvals/8782-scribe-nosha.approved.md"
  cat >"$a2c" <<'EOF'
---
issue: 8782
slug: scribe-nosha
pr: 9182
branch: auto/8782-scribe-nosha
---
Hand-made approval with no head_sha. Must not merge.
EOF
  _write_scribe_ghstub "auto/8782-scribe-nosha" 0 0 "approvedsha"
  : >"$GH_STUB_LOG"; : >"$NOTIFY_LOG"
  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  [ -f "$a2c" ] || fail "scribe refusals: no-head_sha approval consumed"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "scribe refusals: merge invoked with no approved commit recorded"
  grep -q "issue=8782 stage=scribe remote reason=merge detail=SKIPPED-no-head-sha" "$MA_ROOT/state.log" \
    || fail "scribe refusals: SKIPPED-no-head-sha not audited"
  rm -f -- "$a2c"

  # --- Merge command itself fails (checks green, head matches) ---------------
  local a3="$MA_ROOT/merge-approvals/879-scribe-mergefail.approved.md"
  cat >"$a3" <<'EOF'
---
issue: 879
slug: scribe-mergefail
pr: 919
branch: auto/879-scribe-mergefail
head_sha: approvedsha
---
Approval whose gh pr merge command fails.
EOF
  _write_scribe_ghstub "auto/879-scribe-mergefail" 0 1
  : >"$GH_STUB_LOG"; : >"$NOTIFY_LOG"
  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  [ -f "$a3" ] || fail "scribe refusals: merge-fail approval consumed"
  [ ! -f "$MA_ROOT/merge-approvals/879-scribe-mergefail.merged.md" ] || fail "scribe refusals: renamed to merged despite a merge failure"
  grep -q "issue=879 stage=scribe remote reason=merge detail=SKIPPED-merge-command-failed" "$MA_ROOT/state.log" \
    || fail "scribe refusals: SKIPPED-merge-command-failed not audited"
  rm -f -- "$a3"

  pass "scribe refusals audited: gate-1 branch mismatch / live-head mismatch / merge-command failure each write a distinct state.log reason and leave the approval intact"
}

test_scribe_rejected_untouched() {
  local rej="$MA_ROOT/merge-approvals/872-scribe-rej.rejected.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  cat >"$rej" <<'EOF'
---
issue: 872
slug: scribe-rej
pr: 912
branch: auto/872-scribe-rej
head_sha: approvedsha
---
Human rejected this PR (renamed .pending.md -> .rejected.md).
EOF

  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  # High reminder interval so a first-sighting stays silent.
  ( MA_APPROVAL_REMIND_SEC=99999 ml_process_approvals "$FAKE_REPO" )

  [ -f "$rej" ] || fail "scribe rejected: .rejected.md was touched"
  [ ! -f "$MA_ROOT/merge-approvals/872-scribe-rej.merged.md" ] || fail "scribe rejected: a rejected file was merged"
  [ -f "${rej}.reminded" ] || fail "scribe rejected: reminder marker not created on first sighting"
  [ ! -s "$NOTIFY_LOG" ] || fail "scribe rejected: notified on first sighting (must be silent)"

  rm -f -- "$rej" "${rej}.reminded"
  pass "scribe rejected: .rejected.md never merged and left untouched; first sighting records a reminder marker silently"
}

test_scribe_reminder_fires() {
  local pend="$MA_ROOT/merge-approvals/873-scribe-remind.pending.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  cat >"$pend" <<'EOF'
---
issue: 873
slug: scribe-remind
pr: 913
branch: auto/873-scribe-remind
head_sha: approvedsha
---
Still pending human approval.
EOF
  # Pre-existing marker with a long-ago timestamp so the interval elapses.
  printf '0\n' >"${pend}.reminded"
  : >"$NOTIFY_LOG"

  ( MA_APPROVAL_REMIND_SEC=1 ml_process_approvals "$FAKE_REPO" )

  grep -qi "awaiting human" "$NOTIFY_LOG" || fail "scribe reminder: expected a low-frequency human reminder"

  rm -f -- "$pend" "${pend}.reminded"
  pass "scribe reminder: pending file past the reminder interval -> exactly one human reminder"
}

# --- Pending-file approval footer: paste-ready absolute mv command ---------
#
# The Scribe worker authors the merge-approval pending file from the prose
# template in docs/personas/scribe.md (no loop-lib helper generates its body),
# so the template is the testable artifact. The footer must yield a command a
# human can paste from ANY terminal cwd: fully absolute paths (no relative
# path), renaming <issue>-<slug>.pending.md -> .approved.md. Directional pair:
# the shipped template (absolute, both suffixes) passes; a relative-path drift
# of the same template must NOT satisfy the absolute-path check.
SCRIBE_PERSONA="$SCRIPT_DIR/../../docs/personas/scribe.md"
ABS_MV_PLACEHOLDER_RE='<(REPO ROOT|ABS)>/multi-agent/merge-approvals/'

test_pending_footer_abspath() {
  [ -f "$SCRIBE_PERSONA" ] || fail "pending footer: scribe persona doc missing at $SCRIBE_PERSONA"

  # Positive: the footer template line is an mv naming both suffixes, prefixed
  # with the absolute-path placeholder the worker fills for handoff writes.
  local mv_template
  mv_template=$(grep -E '^[[:space:]]*mv .*\.pending\.md .*\.approved\.md' "$SCRIBE_PERSONA" | head -n 1)
  [ -n "$mv_template" ] || fail "pending footer: persona has no 'mv ...pending.md ...approved.md' footer line"
  printf '%s' "$mv_template" | grep -Eq "$ABS_MV_PLACEHOLDER_RE" \
    || fail "pending footer: mv template is not absolute (no <REPO ROOT>/multi-agent/merge-approvals/ prefix): $mv_template"

  # Substitute the placeholders the worker fills at author time and assert the
  # result is a fully-concrete, paste-ready command for one <issue>-<slug>.
  local abs="$MA_ROOT" gen expected
  gen=$(printf '%s' "$mv_template" \
    | sed -e "s#<REPO ROOT>#$abs#g" -e "s#<ABS>#$abs#g" -e 's#<issue>#835#g' -e 's#<slug>#demo#g' \
    | sed -e 's#^[[:space:]]*##')
  expected="mv ${abs}/multi-agent/merge-approvals/835-demo.pending.md ${abs}/multi-agent/merge-approvals/835-demo.approved.md"
  [ "$gen" = "$expected" ] || fail "pending footer: generated command != expected paste-ready form
  got:      $gen
  expected: $expected"

  # Negative (directional): a relative-path drift of the same template must NOT
  # satisfy the absolute-path check, so regressing the footer to a bare relative
  # path surfaces here as a failure instead of passing silently.
  local relative_template="  mv multi-agent/merge-approvals/<issue>-<slug>.pending.md multi-agent/merge-approvals/<issue>-<slug>.approved.md"
  printf '%s' "$relative_template" | grep -Eq "$ABS_MV_PLACEHOLDER_RE" \
    && fail "pending footer: a relative-path mv template wrongly satisfied the absolute-path check"

  pass "pending footer: persona template yields a paste-ready absolute mv naming both .pending.md and .approved.md suffixes"
}

# --- Pending file opened in TextMate at create time (loop-lib
# _ml_open_pending_for_review, wired into ml_tick's scribe success path) -------
#
# Approvals are session-less, so the loop opens each newly created pending file
# in the founder's review editor exactly once — at create time on the scribe
# success tick, never on the low-frequency reminder re-scans. A successful file
# open is followed by a bare `open -a TextMate` (no file argument) that raises
# the window. `open` and `osascript` are both PATH-shimmed so no test launches or
# fronts a real GUI app — and the `osascript` shim now exists purely as a tripwire:
# the raise must go through LaunchServices, never an Apple event, because an Apple
# event needs Automation (TCC) permission that the launchd-spawned loops cannot
# hold or prompt for. Any test invoking it means the TCC-blocked path came back.
# Properties:
#   (a) a new pending -> `open` is invoked exactly twice: once with
#       `-a TextMate <path>` to open the file, then bare `-a TextMate` to raise the
#       window; both exit codes land in the audit line (rc=, raise_rc=);
#   (b) this create-time open fires exactly once, on the scribe success tick — it
#       is a DISTINCT mechanism from the low-frequency reminder re-open (a pending
#       past its interval is re-opened by _ml_remind_pending -> _ml_open_file_for_review,
#       covered by its own test group below); the create-time path here never fires
#       on the reminder re-scans;
#   (c) a failing file open leaves the task done and the flow unaffected
#       (best-effort), its real exit code is audited, and no raise is attempted;
#   (d) no pending file -> the function no-ops entirely (no launch, no audit line);
#   (e) a failing raise after a successful open is audited verbatim and is equally
#       harmless — the task still completes;
#   (f) in every branch, `osascript` is never invoked.
# OPEN_STUB_DIR / OPEN_STUB_LOG / OSASCRIPT_STUB_LOG are defined once near the top
# of this file (the whole suite runs behind that PATH shim); _write_open_stub just
# rewrites the same fake `open`/`osascript` with the exit codes a given test wants.

# _write_open_stub <open-exit-code> [raise-exit-code]
# Write a fake `open` into $OPEN_STUB_DIR that records its argument vector to
# $OPEN_STUB_LOG and exits <open-exit-code> when handed a file to open, or
# [raise-exit-code] (default 0) when invoked bare as `-a TextMate` — the raise.
# Distinct codes per form are what let a test prove each is audited verbatim
# rather than normalized or copied from the other. Also writes a fake `osascript`
# recording its invocations to $OSASCRIPT_STUB_LOG; nothing under test may call
# it, so a non-empty log is a failure, not an expectation.
_write_open_stub() {
  local exit_code="$1" raise_exit_code="${2:-0}"
  mkdir -p "$OPEN_STUB_DIR"
  cat >"$OPEN_STUB_DIR/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$OPEN_STUB_LOG"
[ "\$*" = "-a TextMate" ] && exit $raise_exit_code
exit $exit_code
EOF
  chmod +x "$OPEN_STUB_DIR/open"
  cat >"$OPEN_STUB_DIR/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$OSASCRIPT_STUB_LOG"
exit 0
EOF
  chmod +x "$OPEN_STUB_DIR/osascript"
}

test_scribe_pending_opens_in_textmate() {
  local ready="$MA_ROOT/scribe-notes/882-scribe-open.ready.md"
  local done_file="$MA_ROOT/scribe-notes/882-scribe-open.done.md"
  local pending="$MA_ROOT/merge-approvals/882-scribe-open.pending.md"
  _mk_ready "$ready" 882 scribe-open scribe 1
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  : >"$NOTIFY_LOG"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  local stub="$TMP_ROOT/stub-scribe-open.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/merge-approvals\"
printf '%s\\n' '---' 'issue: 882' 'slug: scribe-open' 'pr: 883' 'branch: auto/882-scribe-open' '---' 'Pending: awaiting human approval.' >\"$pending\""

  ( PATH="$OPEN_STUB_DIR:$PATH"; export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) \
    || fail "scribe open: scribe-loop exited nonzero"

  [ -f "$done_file" ] || fail "scribe open: expected scribe-note done file, none found"
  [ -f "$pending" ] || fail "scribe open: pending approval file missing"

  local open_count
  open_count=$(wc -l <"$OPEN_STUB_LOG" | tr -d ' ')
  [ "$open_count" -eq 2 ] || fail "scribe open: expected open invoked exactly twice (file open + raise), got $open_count"
  grep -qF -- "-a TextMate $pending" "$OPEN_STUB_LOG" \
    || fail "scribe open: open not invoked with '-a TextMate <pending path>'"

  # A successful launch must also RAISE the window: `open <file>` alone does not
  # reliably front an already-running TextMate, which is the failure the founder
  # actually saw (pendings logged as opened, never seen). The raise is a second,
  # BARE `open -a TextMate` — an exact-line match, so a raise that wrongly carried
  # the file path (re-opening the document instead of fronting the app) fails here.
  grep -qxF -- "-a TextMate" "$OPEN_STUB_LOG" \
    || fail "scribe open: no bare 'open -a TextMate' raise after the successful file open"
  grep -q "issue=882 stage=scribe .*pending-opened-textmate rc=0 raise_rc=0" "$MA_ROOT/state.log" \
    || fail "scribe open: audit line missing both exit codes (expected 'pending-opened-textmate rc=0 raise_rc=0')"

  # The raise must go through LaunchServices, NOT an Apple event: `osascript`
  # activation needs Automation (TCC) permission the launchd-spawned loop cannot
  # hold, so it silently did nothing in the only environment that matters.
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe open: raise went through osascript — the TCC-blocked Apple-event path is back"

  rm -f -- "$done_file" "$pending" "${pending}.reminded"
  pass "scribe open: new pending -> open -a TextMate with the path, then a bare open -a TextMate raise; rc=0 raise_rc=0 audited; no osascript"
}

# --- Reminder re-opens a still-pending approval in TextMate (loop-lib
# _ml_remind_pending -> _ml_open_file_for_review) ------------------------------
#
# The create-time open above fires once, on the scribe success tick. But an
# approval that no human actions keeps sitting in the queue, and the only later
# nudge was ma_notify's banner — which macOS silently drops for a launchd-spawned
# loop with no TCC session, so a stale pending surfaced nothing and one sat unseen
# for two days. So on every interval-elapsed reminder sighting, a *.pending.md is
# now ALSO re-opened in TextMate (the launchd-reachable channel), throttled by the
# same .reminded marker that gates the banner — at most one re-open per
# MA_APPROVAL_REMIND_SEC. The re-open is scoped to *.pending.md ONLY: a
# *.rejected.md the human already actioned keeps the banner alone. Directional
# cases: past-interval pending re-opens (a) vs inside-interval (b) / first-sighting
# (c) / rejected (d) which must NOT re-open; the osascript tripwire stays empty
# throughout — the raise goes through LaunchServices, never a TCC-blocked Apple
# event.

# (a) A pending file past its reminder interval fires the banner AND re-opens in
# TextMate: `open -a TextMate <path>` then a bare `open -a TextMate` raise, both
# exit codes audited (rc=0 raise_rc=0). The pending file is left in place — the
# human gate is untouched.
test_scribe_reminder_reopens_pending() {
  local pend="$MA_ROOT/merge-approvals/9231-scribe-reopen.pending.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$pend" <<'EOF'
---
issue: 9231
slug: scribe-reopen
pr: 931
branch: auto/9231-scribe-reopen
head_sha: approvedsha
---
Still pending human approval.
EOF
  # Pre-existing marker with a long-ago timestamp so the interval elapses.
  printf '0\n' >"${pend}.reminded"
  : >"$NOTIFY_LOG"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  ( PATH="$OPEN_STUB_DIR:$PATH"; MA_APPROVAL_REMIND_SEC=1 ml_process_approvals "$FAKE_REPO" )

  grep -qi "awaiting human" "$NOTIFY_LOG" \
    || fail "scribe reopen: reminder banner did not fire (precondition for the re-open assertion)"
  [ -f "$pend" ] || fail "scribe reopen: pending file was consumed — the human gate was bypassed"

  local open_count
  open_count=$(wc -l <"$OPEN_STUB_LOG" | tr -d ' ')
  [ "$open_count" -eq 2 ] \
    || fail "scribe reopen: expected open invoked exactly twice (file open + raise), got $open_count"
  grep -qF -- "-a TextMate $pend" "$OPEN_STUB_LOG" \
    || fail "scribe reopen: open not invoked with '-a TextMate <pending path>'"
  grep -qxF -- "-a TextMate" "$OPEN_STUB_LOG" \
    || fail "scribe reopen: no bare 'open -a TextMate' raise after the file open"
  grep -q "issue=9231 stage=scribe .*opened-textmate rc=0 raise_rc=0" "$MA_ROOT/state.log" \
    || fail "scribe reopen: audit line missing both exit codes (expected 'opened-textmate rc=0 raise_rc=0')"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe reopen: raise went through osascript — the TCC-blocked Apple-event path is back"

  rm -f -- "$pend" "${pend}.reminded"
  pass "scribe reopen: a pending past its interval fires the banner and re-opens in TextMate (open + raise, rc=0 raise_rc=0 audited); pending left intact; no osascript"
}

# (b) A pending file still INSIDE its reminder interval neither notifies nor
# re-opens: the marker is fresh, so the interval has not elapsed.
test_scribe_reminder_inside_interval_no_reopen() {
  local pend="$MA_ROOT/merge-approvals/9232-scribe-inside.pending.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$pend" <<'EOF'
---
issue: 9232
slug: scribe-inside
pr: 932
branch: auto/9232-scribe-inside
head_sha: approvedsha
---
Still pending human approval.
EOF
  # Fresh marker (now): the interval has NOT elapsed.
  printf '%s\n' "$(date +%s)" >"${pend}.reminded"
  : >"$NOTIFY_LOG"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  ( PATH="$OPEN_STUB_DIR:$PATH"; MA_APPROVAL_REMIND_SEC=99999 ml_process_approvals "$FAKE_REPO" )

  [ ! -s "$NOTIFY_LOG" ] \
    || fail "scribe inside-interval: notified before the interval elapsed"
  [ ! -s "$OPEN_STUB_LOG" ] \
    || fail "scribe inside-interval: re-opened the editor before the interval elapsed"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe inside-interval: raised the editor before the interval elapsed"

  rm -f -- "$pend" "${pend}.reminded"
  pass "scribe inside-interval: a pending still within its reminder interval neither notifies nor re-opens"
}

# (c) A first-sighting pending (no marker yet) only records the marker: no banner,
# no re-open — a file that appears and is handled within one interval never spams.
test_scribe_reminder_fresh_pending_no_reopen() {
  local pend="$MA_ROOT/merge-approvals/9233-scribe-fresh.pending.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until" "${pend}.reminded"
  cat >"$pend" <<'EOF'
---
issue: 9233
slug: scribe-fresh
pr: 933
branch: auto/9233-scribe-fresh
head_sha: approvedsha
---
Freshly pending human approval.
EOF
  : >"$NOTIFY_LOG"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  ( PATH="$OPEN_STUB_DIR:$PATH"; MA_APPROVAL_REMIND_SEC=1 ml_process_approvals "$FAKE_REPO" )

  [ -f "${pend}.reminded" ] \
    || fail "scribe fresh: reminder marker not created on first sighting"
  [ ! -s "$NOTIFY_LOG" ] \
    || fail "scribe fresh: notified on first sighting (must be silent)"
  [ ! -s "$OPEN_STUB_LOG" ] \
    || fail "scribe fresh: re-opened the editor on first sighting (must be silent)"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe fresh: raised the editor on first sighting"

  rm -f -- "$pend" "${pend}.reminded"
  pass "scribe fresh: a first-sighting pending records its marker silently — no banner, no re-open"
}

# (d) Directional counterpart to (a): a *.rejected.md past its interval fires the
# banner but is NEVER re-opened — a human already actioned it. Guards the
# pending-only case in _ml_remind_pending.
test_scribe_rejected_reminder_no_reopen() {
  local rej="$MA_ROOT/merge-approvals/9234-scribe-rej-noopen.rejected.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$rej" <<'EOF'
---
issue: 9234
slug: scribe-rej-noopen
pr: 934
branch: auto/9234-scribe-rej-noopen
head_sha: approvedsha
---
Human rejected this PR (renamed .pending.md -> .rejected.md).
EOF
  # Pre-existing marker in the past so the reminder fires THIS tick — the point
  # is that even a firing reminder never re-opens a rejected file.
  printf '0\n' >"${rej}.reminded"
  : >"$NOTIFY_LOG"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  ( PATH="$OPEN_STUB_DIR:$PATH"; MA_APPROVAL_REMIND_SEC=1 ml_process_approvals "$FAKE_REPO" )

  grep -qi "awaiting human" "$NOTIFY_LOG" \
    || fail "scribe rejected no-reopen: reminder banner did not fire (precondition for the assertion)"
  [ ! -s "$OPEN_STUB_LOG" ] \
    || fail "scribe rejected no-reopen: a rejected file was re-opened in the editor (re-open is pending-only)"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe rejected no-reopen: a rejected file raised the editor"

  rm -f -- "$rej" "${rej}.reminded"
  pass "scribe rejected no-reopen: a rejected file past its interval fires the banner only — never re-opened (re-open is pending-only)"
}

# (d) No pending file -> the function no-ops: no launch, no activation, and no
# audit line claiming an open that never happened. Guards the early return, the
# one branch where an rc-logging bug would fabricate an `rc=0` for a file that
# does not exist.
test_open_pending_absent_noop() {
  local before after
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/merge-approvals/888-scribe-absent.pending.md"
  _write_open_stub 0
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  before=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')
  ( PATH="$OPEN_STUB_DIR:$PATH"; _ml_open_pending_for_review 888 scribe-absent 1 ) \
    || fail "scribe open-absent: function returned nonzero with no pending file (must never fail the task)"
  after=$(wc -l <"$MA_ROOT/state.log" | tr -d ' ')

  [ ! -s "$OPEN_STUB_LOG" ] || fail "scribe open-absent: open invoked for a pending file that does not exist"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] || fail "scribe open-absent: editor raised for a pending file that does not exist"
  [ "$after" -eq "$before" ] || fail "scribe open-absent: state.log grew — an open was audited but never attempted"

  pass "scribe open-absent: no pending file -> no open, no raise, no audit line"
}

test_scribe_open_failure_harmless() {
  local ready="$MA_ROOT/scribe-notes/886-scribe-openfail.ready.md"
  local done_file="$MA_ROOT/scribe-notes/886-scribe-openfail.done.md"
  local pending="$MA_ROOT/merge-approvals/886-scribe-openfail.pending.md"
  _mk_ready "$ready" 886 scribe-openfail scribe 1
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  : >"$NOTIFY_LOG"
  _write_open_stub 3   # simulate a failed GUI launch
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  local stub="$TMP_ROOT/stub-scribe-openfail.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/merge-approvals\"
printf '%s\\n' '---' 'issue: 886' 'slug: scribe-openfail' 'pr: 887' 'branch: auto/886-scribe-openfail' '---' 'Pending.' >\"$pending\""

  local status=0
  ( PATH="$OPEN_STUB_DIR:$PATH"; export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) || status=$?
  [ "$status" -eq 0 ] || fail "scribe open-fail: scribe-loop exited nonzero despite best-effort open"

  [ -f "$done_file" ] || fail "scribe open-fail: task not marked done despite a failed open"
  [ -f "$pending" ] || fail "scribe open-fail: pending file missing"
  # The launcher's OWN exit code is what lands in the audit line: the shim exits
  # 3, so an implementation that normalized every failure to a fixed rc=1 (or
  # that logged rc=0 regardless) fails here. That verbatim code is the whole
  # point — it is what separates "attempted" from "succeeded" after the fact.
  # A failed open leaves nothing to raise, so no raise is attempted and the audit
  # says so rather than fabricating a raise exit code.
  grep -q "issue=886 stage=scribe .*pending-opened-textmate rc=3 raise_rc=skipped" "$MA_ROOT/state.log" \
    || fail "scribe open-fail: audit line wrong (expected 'pending-opened-textmate rc=3 raise_rc=skipped')"
  local open_count
  open_count=$(wc -l <"$OPEN_STUB_LOG" | tr -d ' ')
  [ "$open_count" -eq 1 ] \
    || fail "scribe open-fail: expected the failed file open only, no raise; got $open_count open invocations"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe open-fail: raise attempted via osascript after a failed open"

  rm -f -- "$done_file" "$pending" "${pending}.reminded"
  pass "scribe open-fail: a failing open audits its real exit code, skips the raise (raise_rc=skipped), and leaves the task done"
}

# (e) The raise is best-effort in its OWN right: the file open succeeds but the
# bare `open -a TextMate` fails (e.g. no GUI session to front a window into).
# The task must still complete, and the raise's verbatim exit code must reach the
# audit line — an implementation that copied rc, hardcoded raise_rc=0, or let the
# failure escape and fail the task all die here.
test_scribe_raise_failure_harmless() {
  local ready="$MA_ROOT/scribe-notes/890-scribe-raisefail.ready.md"
  local done_file="$MA_ROOT/scribe-notes/890-scribe-raisefail.done.md"
  local pending="$MA_ROOT/merge-approvals/890-scribe-raisefail.pending.md"
  _mk_ready "$ready" 890 scribe-raisefail scribe 1
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  : >"$NOTIFY_LOG"
  _write_open_stub 0 4   # file open succeeds; the raise fails with 4
  : >"$OPEN_STUB_LOG"
  : >"$OSASCRIPT_STUB_LOG"

  local stub="$TMP_ROOT/stub-scribe-raisefail.sh"
  _mk_stub "$stub" "mkdir -p \"$MA_ROOT/merge-approvals\"
printf '%s\\n' '---' 'issue: 890' 'slug: scribe-raisefail' 'pr: 891' 'branch: auto/890-scribe-raisefail' '---' 'Pending.' >\"$pending\""

  local status=0
  ( PATH="$OPEN_STUB_DIR:$PATH"; export WORKER_CMD="$stub"; bash "$SCRIBE_LOOP" ) || status=$?
  [ "$status" -eq 0 ] || fail "scribe raise-fail: scribe-loop exited nonzero despite a best-effort raise"

  [ -f "$done_file" ] || fail "scribe raise-fail: task not marked done despite a failed raise"
  grep -q "issue=890 stage=scribe .*pending-opened-textmate rc=0 raise_rc=4" "$MA_ROOT/state.log" \
    || fail "scribe raise-fail: audit line missing the raise's verbatim exit code (expected 'pending-opened-textmate rc=0 raise_rc=4')"
  [ ! -s "$OSASCRIPT_STUB_LOG" ] \
    || fail "scribe raise-fail: fell back to the TCC-blocked osascript path when the LaunchServices raise failed"

  rm -f -- "$done_file" "$pending" "${pending}.reminded"
  pass "scribe raise-fail: a failing raise audits its real exit code (raise_rc=4) and leaves the task done"
}

# --- Worktrees keyed by issue-slug (loop-lib _ml_worktree_path; worker setup
# and merge close-out both derive the path here) ---

test_worktree_path_distinct_by_slug() {
  local a b
  a=$(_ml_worktree_path /repo 900 slug-a)
  b=$(_ml_worktree_path /repo 900 slug-b)
  [ "$a" = "/repo/.worktrees/900-slug-a" ] || fail "worktree path: unexpected path for slug-a: '$a'"
  [ "$b" = "/repo/.worktrees/900-slug-b" ] || fail "worktree path: unexpected path for slug-b: '$b'"
  [ "$a" != "$b" ] || fail "worktree path: same-issue different-slug tasks must get distinct paths"
  pass "worktree path: keyed by issue-slug -> two same-issue different-slug tasks get distinct paths"
}

test_worktree_closeout_removes_only_own() {
  # Regression: two tasks on the same issue but different slugs each own a
  # distinct worktree. A merge close-out for one must remove ONLY that slug's
  # tree, never the sibling's.
  local own="$FAKE_REPO/.worktrees/871-wt-own"
  local sibling="$FAKE_REPO/.worktrees/871-wt-sibling"
  mkdir -p "$own" "$sibling"
  : >"$own/marker"
  : >"$sibling/marker"

  local appr="$MA_ROOT/merge-approvals/871-wt-own.approved.md"
  local merged="$MA_ROOT/merge-approvals/871-wt-own.merged.md"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"$appr" <<'EOF'
---
issue: 871
slug: wt-own
pr: 950
branch: auto/871-wt-own
head_sha: approvedsha
---
Approved by a human.
EOF

  # gh: green merge path. git: actually delete on `worktree remove` so the test
  # observes which tree the close-out targeted; push is a no-op; else real git.
  mkdir -p "$GH_STUB_DIR"
  cat >"$GH_STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # Field-aware: gate 2 asks headRefName, gate 3 asks headRefOid.
    case " $* " in
      *headRefOid*)  printf '%s\n' "approvedsha" ;;
      *)             printf '%s\n' "auto/871-wt-own" ;;
    esac
    ;;
  "pr checks") exit 0 ;;
  "pr merge") exit 0 ;;
  "pr comment") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_STUB_DIR/gh"
  cat >"$GH_STUB_DIR/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*)
    for last; do :; done
    rm -rf -- "$last"
    exit 0 ;;
  *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
EOF
  chmod +x "$GH_STUB_DIR/git"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "worktree closeout: approval not merged (setup problem)"
  [ ! -d "$own" ] || fail "worktree closeout: the task's own issue-slug worktree was NOT removed"
  [ -d "$sibling" ] || fail "worktree closeout: a sibling slug's worktree on the same issue was destroyed"

  rm -f -- "$merged"
  rm -rf -- "$sibling"
  pass "worktree closeout: merge close-out removes exactly the task's own issue-slug worktree, never a sibling slug's on the same issue"
}

# --- Docs-only auto-approve class (merge-policy.sh) ------------------------
#
# The class lets a pure-docs PR merge without a human. Everything else keeps
# today's human gate. The tests below are built around the one property that
# makes that safe: eligibility is RECOMPUTED from the live PR and state.log at
# process time, so nothing a worker writes into the pending file can influence
# it (test_policy_ignores_frontmatter_claim is the direct proof).

# _write_policy_ghstub <head> <changed-paths> <total-lines> [checks-exit] [merge-exit] [patch]
# A gh stub that can answer the four questions the policy asks. The two
# `gh pr view` call sites are told apart by their --json field, so the stub can
# return a head branch to the identity gate and a line count to the size gate;
# the two `gh pr diff` call sites are told apart by --name-only, so the stub can
# return a path list to the path gate and a raw patch to the rename gate.
#
# <patch> defaults to a plain in-place edit of each changed path — no rename
# headers — which is what an ordinary docs PR's patch looks like. A test that
# wants a rename passes its own patch body. The patch is served from a file
# rather than interpolated into the stub script, so a patch body containing
# quotes or backslashes cannot corrupt the stub.
_write_policy_ghstub() {
  # ${6-...} not ${6:-...}: a test that passes an explicit empty patch (gh
  # answered, with nothing) means it, and must not be handed the default.
  local head="$1" paths="$2" total="$3" checks_exit="${4:-0}" merge_exit="${5:-0}" patch="${6-__default__}"
  mkdir -p "$GH_STUB_DIR"

  if [ "$patch" = "__default__" ]; then
    patch=$(
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old\n+new\n' "$p" "$p" "$p" "$p"
      done <<<"$paths"
    )
  fi
  printf '%s\n' "$patch" >"$GH_STUB_DIR/patch.diff"

  cat >"$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_STUB_LOG"
case "\$1 \$2" in
  "pr diff")
    case " \$* " in
      *--name-only*) printf '%s\n' "$paths" ;;
      *) cat "$GH_STUB_DIR/patch.diff" ;;
    esac
    ;;
  "pr view")
    case " \$* " in
      *additions*) printf '%s\n' "$total" ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  "pr checks") exit $checks_exit ;;
  "pr merge") exit $merge_exit ;;
  "pr comment") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_STUB_DIR/gh"
  cat >"$GH_STUB_DIR/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"$GH_STUB_LOG"
case " \$* " in
  *" push "* | *" worktree "*) exit 0 ;;
esac
exec /usr/bin/git "\$@"
EOF
  chmod +x "$GH_STUB_DIR/git"
}

# _mk_policy_pending <issue> <slug> <pr> [extra-frontmatter-line...]
# Write a pending approval file the way the scribe worker does.
_mk_policy_pending() {
  local issue="$1" slug="$2" pr="$3"
  shift 3
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  {
    printf '%s\n' '---'
    printf 'issue: %s\n' "$issue"
    printf 'slug: %s\n' "$slug"
    printf 'pr: %s\n' "$pr"
    printf 'branch: auto/%s-%s\n' "$issue" "$slug"
    # Matches _write_scribe_ghstub's default headRefOid, so fixtures clear the
    # commit-scoped gate and go on to exercise whatever they were written for.
    # A fixture that wants to test the SHA gate itself overrides this via the
    # extra-frontmatter args.
    printf 'head_sha: approvedsha\n'
    local extra
    for extra in "$@"; do
      printf '%s\n' "$extra"
    done
    printf '%s\n' '---'
    printf '%s\n' 'Pending: awaiting human approval.'
  } >"$MA_ROOT/merge-approvals/${issue}-${slug}.pending.md"
}

# _seed_clean_chain <issue>
# A clean, first-pass queue history: no failed/blocked transition, no pass > 1.
_seed_clean_chain() {
  q_log "$1" scribe ready claimed scribe-loop 1
  q_log "$1" scribe claimed done null 1
}

# _policy_class_configured
# True (0) iff an auto-approve class is actually configured — asked of the policy
# itself, using the same docs fixture the class tests below rely on, rather than
# assumed. False in a fresh port, whose placeholder policy classifies nothing.
_policy_class_configured() {
  mp_path_in_class 'docs/x.md' && [ "$MP_MAX_CHANGED_LINES" -ge 10 ]
}

test_policy_unconfigured_class_never_merges() {
  # The safety property a fresh port stands on: with no class configured, the
  # auto-approve pass merges NOTHING and every PR keeps its human gate. Asserted
  # here against the real approval path, with the class overridden in a subshell
  # to the shape export-kit.sh ships (a sentinel that matches no path, zero cap),
  # so this repo's own class is untouched.
  #
  # It runs in every configuration, ported or not: it is the one policy assertion
  # that must never be skipped.
  _mk_policy_pending 9613 policy-unconfigured 923
  _seed_clean_chain 9613
  _write_policy_ghstub "auto/9613-policy-unconfigured" "docs/ops-runbook.md" 5 0 0
  : >"$GH_STUB_LOG"

  (
    MP_ALLOWED_PATHS=('__UNCONFIGURED_AUTO_APPROVE_CLASS__/**')
    MP_MAX_CHANGED_LINES=0
    PATH="$GH_STUB_DIR:$PATH"
    ml_process_approvals "$FAKE_REPO"
  )

  _assert_stays_pending 9613 policy-unconfigured "policy unconfigured class"
  pass "policy unconfigured class: with no auto-approve class configured (the fresh-port default), a docs-only PR that WOULD be in class here stays pending for a human — the port is human-gated until its founder decides otherwise"
}

test_merge_policy_path_classification() {
  # The class boundary, path by path. The exclusions are the whole point: a
  # persona file or a dispatch-rules file changes how the agents BEHAVE, so it
  # must never ride in under the docs/ allow rule.
  local p
  for p in \
    'docs/x.md' \
    'docs/ops-runbook.md' \
    'docs/a/b/deeply/nested.md' \
    'README.md'; do
    mp_path_in_class "$p" || fail "policy paths: '$p' should be IN class but was rejected"
  done

  for p in \
    'docs/personas/scribe.md' \
    'docs/personas/nested/x.md' \
    'docs/brief-template.md' \
    'docs/remote-dispatch-rules.md' \
    'docs/cowork-dispatch-instructions.md' \
    'scripts/multi-agent/loop-lib.sh' \
    'scripts/multi-agent/merge-policy.sh' \
    'server/src/index.ts' \
    'docs' \
    'docs-internal/x.md' \
    'README.mdx' \
    'notdocs/x.md' \
    '/etc/passwd' \
    '../../etc/passwd' \
    'docs/../server/src/index.ts' \
    ''; do
    if mp_path_in_class "$p"; then
      fail "policy paths: '$p' should be OUT of class but was accepted"
    fi
  done

  pass "policy paths: docs/** + README.md are in class; personas/dispatch/brief control surfaces, non-docs code, lookalike dirs (docs-internal/), traversal and absolute paths are all out"
}

test_policy_auto_merges_docs_only() {
  local pending="$MA_ROOT/merge-approvals/9601-policy-docs.pending.md"
  local merged="$MA_ROOT/merge-approvals/9601-policy-docs.merged.md"
  _mk_policy_pending 9601 policy-docs 911
  _seed_clean_chain 9601
  _write_policy_ghstub "auto/9601-policy-docs" "docs/ops-runbook.md
README.md" 42
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "policy auto-merge: in-class docs PR did not reach .merged.md"
  [ ! -f "$pending" ] || fail "policy auto-merge: pending file still present after auto-merge"
  [ ! -f "$MA_ROOT/merge-approvals/9601-policy-docs.approved.md" ] \
    || fail "policy auto-merge: an .approved.md was written — the loop must NEVER mint a human approval"
  grep -q "gh pr merge 911 --squash" "$GH_STUB_LOG" || fail "policy auto-merge: squash merge not invoked"
  grep -q "issue=9601 stage=scribe remote reason=auto-merge-policy" "$MA_ROOT/state.log" \
    || fail "policy auto-merge: no reason=auto-merge-policy audit line"
  grep -q "MERGED pr=911 via=auto-merge-policy" "$MA_ROOT/state.log" \
    || fail "policy auto-merge: merge not audited as policy-authorized"
  grep -qi "auto-merged under docs policy" "$NOTIFY_LOG" \
    || fail "policy auto-merge: no auto-merge notification"

  rm -f -- "$merged" "${pending}.reminded"
  pass "policy auto-merge: docs-only PR under the line cap with a clean first-pass chain -> .automerged.md -> squash-merged, audited reason=auto-merge-policy, human notified, no .approved.md ever minted"
}

# _assert_stays_pending <issue> <slug> <label>
# The shared shape of every negative case: the file is untouched, no merge was
# attempted, and the human gate still owns the decision.
_assert_stays_pending() {
  local issue="$1" slug="$2" label="$3"
  local base="$MA_ROOT/merge-approvals/${issue}-${slug}"
  [ -f "${base}.pending.md" ] || fail "$label: pending file was consumed — the human gate was bypassed"
  [ ! -f "${base}.merged.md" ] || fail "$label: PR was MERGED despite being out of class"
  [ ! -f "${base}.automerged.md" ] || fail "$label: PR was certified in-class when it is not"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "$label: a merge was attempted for an out-of-class PR"
  rm -f -- "${base}.pending.md" "${base}.pending.md.reminded"
}

test_policy_control_surface_stays_pending() {
  # A persona edit is a behavior change wearing a docs/ path.
  _mk_policy_pending 9602 policy-persona 912
  _seed_clean_chain 9602
  _write_policy_ghstub "auto/9602-policy-persona" "docs/merge-policy.md
docs/personas/scribe.md" 12
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9602 policy-persona "policy control-surface"
  pass "policy control-surface: a PR touching docs/personas/** stays pending for a human, even though every other path in it is in-class"
}

test_policy_size_cap_stays_pending() {
  # 101 changed lines: one over the cap, docs-only, clean chain. Still a human's.
  _mk_policy_pending 9603 policy-big 913
  _seed_clean_chain 9603
  _write_policy_ghstub "auto/9603-policy-big" "docs/ops-runbook.md" 101
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9603 policy-big "policy size cap"
  pass "policy size cap: a docs-only PR of 101 changed lines (one over the 100-line cap) stays pending"
}

test_policy_failed_chain_stays_pending() {
  # Docs-only and small, but the task failed somewhere on its way here.
  _mk_policy_pending 9604 policy-failed 914
  q_log 9604 builder ready claimed builder-loop 1
  q_log 9604 builder claimed failed null 1
  _write_policy_ghstub "auto/9604-policy-failed" "docs/x.md" 5
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9604 policy-failed "policy failed chain"
  pass "policy failed chain: a docs-only PR whose task recorded a ->failed transition stays pending"
}

test_policy_pass2_chain_stays_pending() {
  # Docs-only and small, but the Validator sent it back once. Rework means a human.
  _mk_policy_pending 9605 policy-pass2 915
  q_log 9605 builder ready claimed builder-loop 1
  q_log 9605 validator ready claimed validator-loop 2
  _write_policy_ghstub "auto/9605-policy-pass2" "docs/x.md" 5
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9605 policy-pass2 "policy pass-2 chain"
  pass "policy pass-2 chain: a docs-only PR that needed a second pass stays pending (clean first-pass chains only)"
}

test_policy_ignores_frontmatter_claim() {
  # THE property. A worker writes the pending file, so assume a worker that lies:
  # this one asserts, in its own frontmatter, that it is a tiny docs-only change
  # already approved under the policy. The live PR is a 500-line server change.
  # The loop must believe gh, not the file.
  _mk_policy_pending 9606 policy-liar 916 \
    'auto_approve: true' \
    'docs_only: true' \
    'policy: auto-merge-policy' \
    'eligible: true' \
    'changed_paths: docs/x.md' \
    'additions: 1' \
    'deletions: 0'
  _seed_clean_chain 9606
  _write_policy_ghstub "auto/9606-policy-liar" "server/src/index.ts
scripts/multi-agent/loop-lib.sh" 500
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9606 policy-liar "policy recomputation"
  pass "policy recomputation: a pending file whose frontmatter falsely claims docs-only/auto_approve/eligible is ignored — eligibility is recomputed from the live PR, so a worker cannot mint its own auto-approval"
}

test_policy_red_checks_no_merge() {
  # In-class, but the checks are red at current head. The class decides WHO
  # approves, never WHETHER the gates apply.
  local base="$MA_ROOT/merge-approvals/9607-policy-red"
  _mk_policy_pending 9607 policy-red 917
  _seed_clean_chain 9607
  _write_policy_ghstub "auto/9607-policy-red" "docs/x.md" 10 1
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ ! -f "${base}.merged.md" ] || fail "policy red checks: an in-class PR was merged with red checks"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "policy red checks: merge attempted despite red checks"
  [ -f "${base}.automerged.md" ] || fail "policy red checks: certified file vanished (should be retried next tick)"
  grep -qi "checks not green" "$NOTIFY_LOG" || fail "policy red checks: human not notified"

  rm -f -- "${base}.automerged.md" "${base}.pending.md.reminded"
  pass "policy red checks: an in-class PR with red checks at current head is NOT merged — auto-approval clears the same gates as a human approval"
}

test_policy_revokes_stale_certificate() {
  # Certified in-class on an earlier tick, then pushed to: the PR now touches a
  # persona file. Rather than merge on the stale certificate, hand it back to the
  # human gate. This is why eligibility is re-evaluated every tick, not cached.
  local base="$MA_ROOT/merge-approvals/9608-policy-stale"
  mkdir -p "$MA_ROOT/merge-approvals"
  rm -f -- "$MA_ROOT/.quota-deferred-until"
  cat >"${base}.automerged.md" <<'EOF'
---
issue: 9608
slug: policy-stale
pr: 918
branch: auto/9608-policy-stale
head_sha: approvedsha
---
Certified in-class by the loop on an earlier tick.
EOF
  _seed_clean_chain 9608
  _write_policy_ghstub "auto/9608-policy-stale" "docs/personas/builder.md" 8
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "${base}.pending.md" ] || fail "policy revoke: stale certificate was not returned to the human gate"
  [ ! -f "${base}.automerged.md" ] || fail "policy revoke: file still carries a certificate it no longer earns"
  [ ! -f "${base}.merged.md" ] || fail "policy revoke: PR merged on a STALE certificate after its head moved out of class"
  grep -q "gh pr merge" "$GH_STUB_LOG" && fail "policy revoke: merge attempted for a PR that left the class"
  grep -q "REVOKED pr=918" "$MA_ROOT/state.log" || fail "policy revoke: revocation not audited"
  grep -qi "returned to the human approval gate" "$NOTIFY_LOG" || fail "policy revoke: human not notified"

  rm -f -- "${base}.pending.md" "${base}.pending.md.reminded"
  pass "policy revoke: a PR certified in-class whose head then moves OUT of class is returned to the human gate, not merged on the stale certificate"
}

test_policy_gh_failure_fails_closed() {
  # gh unreachable. Every uncertainty must resolve toward the human, never toward
  # a merge.
  _mk_policy_pending 9609 policy-ghdown 919
  _seed_clean_chain 9609
  mkdir -p "$GH_STUB_DIR"
  cat >"$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_STUB_LOG"
exit 1
EOF
  chmod +x "$GH_STUB_DIR/gh"
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9609 policy-ghdown "policy gh failure"
  pass "policy gh failure: when gh cannot classify the PR, the policy fails CLOSED — the PR stays pending for a human"
}

test_policy_rename_into_docs_stays_pending() {
  # The rename hole. `git mv server/src/index.ts docs/index.ts` folds two paths
  # into one entry: --name-only reports ONLY the destination, and the API counts
  # the moved content as 0 additions + 0 deletions. So a PR that deletes a source
  # file from the tree presents to a --name-only-only policy as a zero-line,
  # docs-only change — defeating the path gate and the size gate with the same
  # construct. The source path must be read out of the patch.
  _mk_policy_pending 9610 policy-rename 920
  _seed_clean_chain 9610
  _write_policy_ghstub "auto/9610-policy-rename" "docs/index.ts" 0 0 0 \
'diff --git a/server/src/index.ts b/docs/index.ts
similarity index 100%
rename from server/src/index.ts
rename to docs/index.ts'
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9610 policy-rename "policy rename-in"
  pass "policy rename-in: a PR that renames server/src/index.ts into docs/ stays pending — the source path is invisible to --name-only and the move costs 0 changed lines, so the patch is what the policy classifies"
}

test_policy_in_class_rename_auto_merges() {
  # The other half of classifying both sides: a rename that stays wholly inside
  # the class is still in the class. A blanket rename ban would send this to a
  # human for no reason.
  local pending="$MA_ROOT/merge-approvals/9611-policy-docsmv.pending.md"
  local merged="$MA_ROOT/merge-approvals/9611-policy-docsmv.merged.md"
  _mk_policy_pending 9611 policy-docsmv 921
  _seed_clean_chain 9611
  _write_policy_ghstub "auto/9611-policy-docsmv" "docs/b.md" 0 0 0 \
'diff --git a/docs/a.md b/docs/b.md
similarity index 100%
rename from docs/a.md
rename to docs/b.md'
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "policy docs rename: an in-class docs/a.md -> docs/b.md rename did not auto-merge"
  grep -q "gh pr merge 921 --squash" "$GH_STUB_LOG" || fail "policy docs rename: squash merge not invoked"

  rm -f -- "$merged" "${pending}.reminded"
  pass "policy docs rename: a rename whose source AND destination are both in class (docs/a.md -> docs/b.md) still auto-merges — both sides are classified, renames are not banned outright"
}

test_policy_empty_patch_fails_closed() {
  # gh answers --name-only but returns no patch. The rename gate has no input, so
  # the source side of any rename would be unknown: ineligible, same as any other
  # uncertainty.
  _mk_policy_pending 9612 policy-nopatch 922
  _seed_clean_chain 9612
  _write_policy_ghstub "auto/9612-policy-nopatch" "docs/x.md" 5 0 0 ''
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9612 policy-nopatch "policy empty patch"
  pass "policy empty patch: an in-class-looking PR whose patch comes back empty fails CLOSED — with no patch the policy cannot see the source side of a rename, so it does not merge"
}

# --- the tests-only class ---------------------------------------------------

# _policy_tests_class_configured
# The tests-class twin of _policy_class_configured: asked of the policy itself,
# with a fixture of the shape the class is meant to hold. False in a fresh port.
_policy_tests_class_configured() {
  mp_path_in_tests_class 'server/tests/routes/example.test.ts' &&
    [ "$MP_TESTS_MAX_CHANGED_LINES" -ge 10 ]
}

test_merge_policy_tests_path_classification() {
  # The tests class boundary, path by path. Two properties are load-bearing here.
  #
  # First: only LEAF test files are in class. Shared plumbing — setup, fixtures,
  # helpers — is what a whole suite depends on, and none of it is named
  # *.test.ts, so it falls out by construction rather than by enumeration.
  #
  # Second: the security suite IS a set of leaf *.test.ts files, so the allow
  # rule alone would put it in class. Only the exclusion keeps it out. Those
  # tests are the gate; a PR that weakens one is the exact change that must not
  # merge on a size-and-path check.
  local p
  for p in \
    'server/tests/routes/auth.test.ts' \
    'server/tests/services/deeply/nested/thing.test.ts' \
    'client/src/hooks/useSession.test.ts' \
    'client/src/pages/SignupPage.captcha.test.tsx' \
    'client/src/test/browser/login.test.ts' \
    'client/src/test/vite-config.test.ts'; do
    mp_path_in_tests_class "$p" ||
      fail "policy tests paths: '$p' should be IN the tests class but was rejected"
  done

  for p in \
    'server/tests/security/pci-compliance.test.ts' \
    'server/tests/security/nested/x.test.ts' \
    'server/tests/setup.ts' \
    'server/tests/globalSetup.ts' \
    'server/tests/globalTeardown.ts' \
    'server/tests/fixtures/stripeEvents.ts' \
    'server/tests/fixtures/stripeEvents.test.ts' \
    'server/tests/README.md' \
    'client/src/test/setup.ts' \
    'client/src/test/browser/setup.ts' \
    'client/src/test/browser/helpers.ts' \
    'client/src/test/test-utils/stubLocation.ts' \
    'server/vitest.config.ts' \
    'server/vitest.integration.config.ts' \
    'client/tsconfig.json' \
    'tsconfig.json' \
    'playwright.config.ts' \
    'tests/e2e/login.spec.ts' \
    'package.json' \
    'package-lock.json' \
    'server/src/index.ts' \
    'client/src/hooks/useSession.ts' \
    'client/src/components/Button.tsx' \
    'docs/x.md' \
    'README.md' \
    'server/tests/routes/auth.spec.ts' \
    'server/testsx/foo.test.ts' \
    'client/srcx/foo.test.ts' \
    'server/tests' \
    '/etc/passwd' \
    '../../etc/passwd' \
    'server/tests/../src/index.test.ts' \
    ''; do
    if mp_path_in_tests_class "$p"; then
      fail "policy tests paths: '$p' should be OUT of the tests class but was accepted"
    fi
  done

  # The trap. A sloppy '*config*' exclusion would catch this ordinary leaf test
  # and silently shrink the class; a sloppy '*.test.ts' allow rule with no
  # security carve-out would swallow the security suite. Both directions pinned.
  mp_path_in_tests_class 'client/src/test/vite-config.test.ts' ||
    fail "policy tests paths: vite-config.test.ts is an ordinary leaf test whose NAME resembles a config — it must stay IN class"
  if mp_path_in_tests_class 'server/tests/security/pci-compliance.test.ts'; then
    fail "policy tests paths: the security suite must never be in the tests class"
  fi

  pass "policy tests paths: leaf *.test.ts(x) under server/tests/ and client/src/ are in class; the security suite, shared plumbing (setup/globalSetup/fixtures/helpers), configs, e2e specs, lockfiles, product source, docs, lookalike dirs (server/testsx/), traversal and absolute paths are all out — and vite-config.test.ts stays IN"
}

test_policy_auto_merges_tests_only() {
  # The class working. 150 changed lines is deliberately OVER the docs class's
  # 100-line cap and under the tests class's 200: the caps are per-class, and
  # this proves the tests PR is measured against its own.
  local pending="$MA_ROOT/merge-approvals/9620-policy-tests.pending.md"
  local merged="$MA_ROOT/merge-approvals/9620-policy-tests.merged.md"
  _mk_policy_pending 9620 policy-tests 930
  _seed_clean_chain 9620
  _write_policy_ghstub "auto/9620-policy-tests" "server/tests/routes/auth.test.ts
server/tests/services/commissionService.test.ts" 150
  : >"$GH_STUB_LOG"
  : >"$NOTIFY_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "policy tests auto-merge: in-class tests-only PR did not reach .merged.md"
  [ ! -f "$pending" ] || fail "policy tests auto-merge: pending file still present after auto-merge"
  [ ! -f "$MA_ROOT/merge-approvals/9620-policy-tests.approved.md" ] \
    || fail "policy tests auto-merge: an .approved.md was written — the loop must NEVER mint a human approval"
  grep -q "gh pr merge 930 --squash" "$GH_STUB_LOG" || fail "policy tests auto-merge: squash merge not invoked"
  grep -q "MERGED pr=930 via=auto-merge-policy" "$MA_ROOT/state.log" \
    || fail "policy tests auto-merge: merge not audited as policy-authorized"
  # The class discriminator. `via=` names the AUTHORIZATION (the policy, not a
  # human) and is identical for both classes; `detail=` is the only place an
  # auditor can see WHICH class merged this. If this assertion ever goes red, the
  # two classes have become indistinguishable in the audit log.
  grep -q "detail=tests-only:" "$MA_ROOT/state.log" \
    || fail "policy tests auto-merge: state.log carries no detail=tests-only — the class is not distinguishable in the audit trail"

  rm -f -- "$merged" "${pending}.reminded"
  pass "policy tests auto-merge: a leaf-test-only PR of 150 lines (over the docs cap, under the tests cap) with a clean first-pass chain auto-merges, audited via=auto-merge-policy detail=tests-only, no .approved.md ever minted"
}

test_policy_auto_merges_client_colocated_tests() {
  # The client stragglers. Two tests live next to the code they test rather than
  # under client/src/test/, which is why the client allow rule is anchored at
  # client/src/ — an anchor at client/src/test/ would silently miss these.
  local pending="$MA_ROOT/merge-approvals/9621-policy-cli.pending.md"
  local merged="$MA_ROOT/merge-approvals/9621-policy-cli.merged.md"
  _mk_policy_pending 9621 policy-cli 931
  _seed_clean_chain 9621
  _write_policy_ghstub "auto/9621-policy-cli" "client/src/hooks/useSession.test.ts
client/src/pages/SignupPage.captcha.test.tsx" 40
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "policy tests client: colocated client leaf tests (.test.ts and .test.tsx) did not auto-merge"
  rm -f -- "$merged" "${pending}.reminded"
  pass "policy tests client: colocated client leaf tests outside client/src/test/ (useSession.test.ts, SignupPage.captcha.test.tsx) are in class — the allow rule is anchored at client/src/, not client/src/test/"
}

test_policy_tests_config_lookalike_auto_merges() {
  # The regression trap, at the merge level. vite-config.test.ts is an ordinary
  # leaf test. If someone ever 'hardens' the config exclusion to a bare *config*
  # glob, this PR stops auto-merging and this test is what says so.
  local pending="$MA_ROOT/merge-approvals/9622-policy-lookalike.pending.md"
  local merged="$MA_ROOT/merge-approvals/9622-policy-lookalike.merged.md"
  _mk_policy_pending 9622 policy-lookalike 932
  _seed_clean_chain 9622
  _write_policy_ghstub "auto/9622-policy-lookalike" "client/src/test/vite-config.test.ts" 12
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  [ -f "$merged" ] || fail "policy tests lookalike: client/src/test/vite-config.test.ts is an ordinary leaf test and must auto-merge — a config-NAME lookalike is not a config"
  rm -f -- "$merged" "${pending}.reminded"
  pass "policy tests lookalike: client/src/test/vite-config.test.ts auto-merges — the config exclusions are anchored to real config names (vitest.config*), so a leaf test that merely looks like one stays in class"
}

test_policy_tests_security_stays_pending() {
  # THE negative proof. server/tests/security/pci-compliance.test.ts is a leaf
  # *.test.ts that the allow rule matches — only the exclusion keeps it out. It
  # is also the file a human personally reviewed. It must never auto-merge, alone
  # or smuggled in alongside otherwise-eligible tests.
  _mk_policy_pending 9623 policy-sec 933
  _seed_clean_chain 9623
  _write_policy_ghstub "auto/9623-policy-sec" "server/tests/security/pci-compliance.test.ts" 10
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  _assert_stays_pending 9623 policy-sec "policy tests security"

  # And again, hidden behind a legitimate in-class test.
  _mk_policy_pending 9624 policy-sec2 934
  _seed_clean_chain 9624
  _write_policy_ghstub "auto/9624-policy-sec2" "server/tests/routes/auth.test.ts
server/tests/security/pci-compliance.test.ts" 20
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  _assert_stays_pending 9624 policy-sec2 "policy tests security smuggled"

  pass "policy tests security: a PR touching server/tests/security/pci-compliance.test.ts stays pending — alone, and when smuggled alongside an otherwise-eligible leaf test. The security suite is the gate; it is never auto-merged"
}

test_policy_tests_plumbing_stays_pending() {
  # Every shared/plumbing file, each paired with a legitimate leaf test so the
  # PR is otherwise eligible: the plumbing file is the only thing stopping it.
  local f issue i=0
  for f in \
    'server/tests/setup.ts' \
    'server/tests/globalSetup.ts' \
    'server/tests/globalTeardown.ts' \
    'server/tests/fixtures/stripeEvents.ts' \
    'server/tests/fixtures/subscriptionScenarios.ts' \
    'server/tests/fixtures/stripeEvents.test.ts' \
    'server/tests/README.md' \
    'client/src/test/setup.ts' \
    'client/src/test/browser/setup.ts' \
    'client/src/test/browser/helpers.ts' \
    'client/src/test/test-utils/stubLocation.ts'; do
    i=$((i + 1))
    issue=$((9640 + i))
    _mk_policy_pending "$issue" policy-plumb 940
    _seed_clean_chain "$issue"
    _write_policy_ghstub "auto/${issue}-policy-plumb" "server/tests/routes/auth.test.ts
$f" 20
    : >"$GH_STUB_LOG"

    ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
    _assert_stays_pending "$issue" policy-plumb "policy tests plumbing ($f)"
  done
  pass "policy tests plumbing: each shared test file (setup, globalSetup, globalTeardown, fixtures, browser helpers, stubLocation, suite README) keeps the human gate even when the rest of the PR is in class — a change to what every suite depends on is not an ordinary test edit"
}

test_policy_tests_config_stays_pending() {
  # Config and e2e, each paired with a legitimate leaf test. These decide what
  # the safety net catches, so they keep the human.
  local f issue i=0
  for f in \
    'server/vitest.config.ts' \
    'server/vitest.integration.config.ts' \
    'client/tsconfig.json' \
    'tsconfig.json' \
    'playwright.config.ts' \
    'tests/e2e/login.spec.ts' \
    'package.json' \
    'package-lock.json'; do
    i=$((i + 1))
    issue=$((9660 + i))
    _mk_policy_pending "$issue" policy-cfg 950
    _seed_clean_chain "$issue"
    _write_policy_ghstub "auto/${issue}-policy-cfg" "server/tests/routes/auth.test.ts
$f" 20
    : >"$GH_STUB_LOG"

    ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
    _assert_stays_pending "$issue" policy-cfg "policy tests config ($f)"
  done
  pass "policy tests config: a runner config, a tsconfig, a playwright config, an e2e spec, package.json or a lockfile riding along with in-class tests keeps the human gate — those files decide what the tests catch and what code they run against"
}

test_policy_tests_size_cap_stays_pending() {
  # 201 changed lines: one over the tests cap.
  _mk_policy_pending 9631 policy-tbig 935
  _seed_clean_chain 9631
  _write_policy_ghstub "auto/9631-policy-tbig" "server/tests/routes/auth.test.ts" 201
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9631 policy-tbig "policy tests size cap"
  pass "policy tests size cap: a tests-only PR of 201 changed lines (one over the 200-line cap) stays pending"
}

test_policy_tests_deletion_stays_pending() {
  # Deleting a test shrinks the safety net WITHOUT turning any check red — the
  # suite passes more easily afterwards — and a small test file costs few enough
  # lines to sit under the cap. Nothing else in the policy would catch this, so
  # the patch's `deleted file mode` header is read directly.
  _mk_policy_pending 9632 policy-tdel 936
  _seed_clean_chain 9632
  _write_policy_ghstub "auto/9632-policy-tdel" "server/tests/routes/auth.test.ts
server/tests/routes/legacy.test.ts" 20 0 0 \
'diff --git a/server/tests/routes/auth.test.ts b/server/tests/routes/auth.test.ts
--- a/server/tests/routes/auth.test.ts
+++ b/server/tests/routes/auth.test.ts
@@ -1 +1 @@
-old
+new
diff --git a/server/tests/routes/legacy.test.ts b/server/tests/routes/legacy.test.ts
deleted file mode 100644
index 1234567..0000000
--- a/server/tests/routes/legacy.test.ts
+++ /dev/null
@@ -1,2 +0,0 @@
-describe("legacy", () => {
-});'
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9632 policy-tdel "policy tests deletion"
  pass "policy tests deletion: a tests-only PR that DELETES a test file stays pending even though every path is in class and the size is under the cap — removing coverage is a judgment call, and no check goes red to flag it"
}

test_policy_tests_rename_stays_pending() {
  # The deliberate asymmetry with the docs class. An in-class docs rename
  # auto-merges (see test_policy_in_class_rename_auto_merges); an in-class TEST
  # rename does not. Both sides here are leaf tests, so a both-sides-classified
  # rule like the docs class's would wave this through. Moving a test costs 0
  # changed lines and can quietly retire coverage by relocating it somewhere the
  # runner does not look.
  _mk_policy_pending 9633 policy-tmv 937
  _seed_clean_chain 9633
  _write_policy_ghstub "auto/9633-policy-tmv" "server/tests/routes/login.test.ts" 0 0 0 \
'diff --git a/server/tests/routes/auth.test.ts b/server/tests/routes/login.test.ts
similarity index 100%
rename from server/tests/routes/auth.test.ts
rename to server/tests/routes/login.test.ts'
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9633 policy-tmv "policy tests rename"
  pass "policy tests rename: a rename whose source AND destination are both leaf tests still stays pending — unlike the docs class, the tests class bans renames outright: a move costs 0 changed lines and can retire coverage without deleting it"
}

test_policy_tests_pass2_stays_pending() {
  _mk_policy_pending 9634 policy-tpass2 938
  q_log 9634 builder ready claimed builder-loop 1
  q_log 9634 validator ready claimed validator-loop 2
  _write_policy_ghstub "auto/9634-policy-tpass2" "server/tests/routes/auth.test.ts" 20
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )

  _assert_stays_pending 9634 policy-tpass2 "policy tests pass-2 chain"
  pass "policy tests pass-2 chain: a tests-only PR that needed a second Validator pass stays pending (clean first-pass chains only)"
}

test_policy_tests_mixed_stays_pending() {
  # Mixed with product source: the obvious smuggle.
  _mk_policy_pending 9635 policy-tmix 939
  _seed_clean_chain 9635
  _write_policy_ghstub "auto/9635-policy-tmix" "server/tests/routes/auth.test.ts
server/src/routes/auth.ts" 30
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  _assert_stays_pending 9635 policy-tmix "policy tests mixed with source"

  # Mixed ACROSS the two classes: every path is in *a* class, but no single cap
  # or rule set applies to the PR, so it fails closed rather than picking one.
  _mk_policy_pending 9636 policy-tmix2 941
  _seed_clean_chain 9636
  _write_policy_ghstub "auto/9636-policy-tmix2" "server/tests/routes/auth.test.ts
docs/testing.md" 30
  : >"$GH_STUB_LOG"

  ( PATH="$GH_STUB_DIR:$PATH"; ml_process_approvals "$FAKE_REPO" )
  _assert_stays_pending 9636 policy-tmix2 "policy tests mixed across classes"

  pass "policy tests mixed: a PR mixing tests with product source stays pending — and so does one mixing tests with docs, where every path is in SOME class but no single class (and so no single cap) covers the PR"
}

# --- export-kit.sh ----------------------------------------------------------

EXPORT_KIT="$SCRIPT_DIR/export-kit.sh"

# The repo the kit is generated FROM. Computed with the same expression
# export-kit.sh uses for its own REPO_ROOT (logical `pwd`, not `pwd -P`), because
# the manifest assertions below compare against the string the generator records.
EK_SOURCE_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The exact file set a port is entitled to. Asserted as a whole (not just
# spot-checked) in both directions: a file that silently stops being exported
# breaks the port, and a file that silently STARTS being exported is how this
# repo's state or its founder's merge authorization would leak into someone
# else's repo.
#
# Sorted under LC_ALL=C, and compared against a find that is sorted the same way:
# EXPORT-MANIFEST.md is the one uppercase name in the set, and the two locales
# available here disagree about where uppercase sorts. Pinning the collation is
# what keeps this assertion from passing on one machine and failing on the next.
EXPORT_FILE_SET="EXPORT-MANIFEST.md
docs/brief-template.md
docs/multi-agent-autonomy.md
docs/personas/builder.md
docs/personas/scribe.md
docs/personas/validator.md
docs/porting-guide.md
scripts/multi-agent/builder-loop.sh
scripts/multi-agent/git-push-guard.sh
scripts/multi-agent/install-loops.sh
scripts/multi-agent/loop-lib.sh
scripts/multi-agent/merge-policy.sh
scripts/multi-agent/queue.sh
scripts/multi-agent/reaper.sh
scripts/multi-agent/scribe-loop.sh
scripts/multi-agent/test-queue.sh
scripts/multi-agent/uninstall-loops.sh
scripts/multi-agent/validator-loop.sh
scripts/new-worktree.sh"

test_export_kit_file_set() {
  local target actual
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-fileset.XXXXXX")

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.fileset >/dev/null 2>&1 ||
    fail "export file set: export-kit.sh exited nonzero"

  actual=$( (cd "$target" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) )
  [ "$actual" = "$EXPORT_FILE_SET" ] || fail "export file set: exported file set does not match the expected set.
--- expected ---
$EXPORT_FILE_SET
--- actual ---
$actual"

  [ -x "$target/scripts/multi-agent/queue.sh" ] ||
    fail "export file set: exported scripts are not executable"

  rm -rf -- "$target"
  pass "export file set: the exported tree is exactly the portable subset — loop scripts, installers, brief template, design doc, porting guide, persona skeletons, placeholder policy, worktree wrapper, provenance manifest"
}

# The provenance manifest, in plain EXPORT mode. The deploy test below asserts
# the same file end-to-end against a real repo; this one pins that a plain export
# is self-identifying too, since that is the copy most likely to be found on a
# disk years later with no idea where it came from.
test_export_kit_manifest_provenance() {
  local target manifest source_commit listed
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-manifest.XXXXXX")

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.provenance >/dev/null 2>&1 ||
    fail "export manifest: export-kit.sh exited nonzero"

  manifest="$target/EXPORT-MANIFEST.md"
  [ -f "$manifest" ] || fail "export manifest: no EXPORT-MANIFEST.md was written"

  grep -q '^| Mode | export |$' "$manifest" ||
    fail "export manifest: the mode was not recorded as 'export'"
  grep -qF "$EK_SOURCE_REPO" "$manifest" ||
    fail "export manifest: the source repo path was not recorded"
  grep -q '^| launchd label prefix | com.example.provenance |$' "$manifest" ||
    fail "export manifest: the label prefix actually used was not recorded"
  # A real UTC timestamp from a real clock: this file is generated content and is
  # SUPPOSED to carry the wall-clock moment it was made.
  grep -qE '^\| Generated \(UTC\) \| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \|$' "$manifest" ||
    fail "export manifest: no ISO-8601 UTC generation timestamp"

  source_commit=$(git -C "$EK_SOURCE_REPO" rev-parse HEAD)
  grep -qF "$source_commit" "$manifest" ||
    fail "export manifest: the source commit ($source_commit) was not recorded"

  # Every delivered file is checksummed, and the manifest never lists itself (it
  # cannot contain its own hash).
  listed=$(grep -cE '^[0-9a-f]{64}  ' "$manifest")
  [ "$listed" -eq 18 ] ||
    fail "export manifest: expected 18 checksummed files (the file set minus the manifest itself), found $listed"
  grep -qE '^[0-9a-f]{64}  EXPORT-MANIFEST\.md$' "$manifest" &&
    fail "export manifest: the manifest lists itself — its own hash cannot be correct"

  rm -rf -- "$target"
  pass "export manifest: every copy self-identifies — source repo, source commit, UTC timestamp, label prefix, mode, and a SHA-256 for each of the 18 delivered files (never itself)"
}

test_export_kit_carries_no_state_or_policy() {
  local target
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-state.XXXXXX")

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.state >/dev/null 2>&1 ||
    fail "export state: export-kit.sh exited nonzero"

  # No queue state, ever: briefs, notes, approvals and logs are this repo's.
  [ ! -e "$target/multi-agent" ] ||
    fail "export state: multi-agent/ queue state was copied into the kit"
  find "$target" -name '*.claimed.md' -o -name '*.ready.md' -o -name '*.pending.md' |
    grep -q . && fail "export state: queue files leaked into the kit"

  # The merge class is a founder authorization about a specific repo. The kit
  # must ship a fail-closed placeholder, never the live values.
  local policy="$target/scripts/multi-agent/merge-policy.sh"
  grep -q 'FOUNDER DECISION REQUIRED' "$policy" ||
    fail "export state: placeholder policy has no FOUNDER-DECISION banner"
  grep -q '__UNCONFIGURED_AUTO_APPROVE_CLASS__' "$policy" ||
    fail "export state: placeholder policy did not get the fail-closed sentinel"
  grep -q "^MP_MAX_CHANGED_LINES=0$" "$policy" ||
    fail "export state: placeholder policy kept a nonzero line cap"
  grep -qE "^  'docs/\*\*'$" "$policy" &&
    fail "export state: the live allow list was copied into the placeholder policy"

  # The class is empty, so the placeholder must classify nothing as in-class —
  # and must do so WITHOUT crashing under bash 3.2 (see below).
  local classified
  classified=$(/bin/bash -c "set -uo pipefail; source '$policy'; if mp_path_in_class 'docs/x.md'; then printf 'IN'; else printf 'OUT'; fi" 2>&1)
  [ "$classified" = "OUT" ] ||
    fail "export state: placeholder policy did not fail closed on docs/x.md (got '$classified')"

  rm -rf -- "$target"
  pass "export state: no multi-agent/ state and no live merge class leave this repo — the kit's policy is a fail-closed placeholder that classifies nothing in-class"
}

test_export_kit_blanks_every_class() {
  # The hole this closes, stated plainly: _ek_write_policy blanks by exact
  # variable NAME, so a class added to merge-policy.sh without a matching awk
  # rule flows through LIVE. A port would then receive THIS repo's founder
  # authorization about THIS repo's tree — auto-merging against globs that mean
  # nothing there — under a banner promising that nothing auto-merges.
  #
  # The older assertions could not see that: they name the docs class
  # specifically, so they stay green while a second class leaks. This test is
  # written to be class-AGNOSTIC instead. It asks the generated policy to
  # classify the paths this repo's live classes WOULD auto-merge and requires the
  # answer to be "none of them", whatever classes exist now or later.
  local target policy classified entries arr p
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-classes.XXXXXX")

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.classes >/dev/null 2>&1 ||
    fail "export classes: export-kit.sh exited nonzero"
  policy="$target/scripts/multi-agent/merge-policy.sh"

  # Every class's cap is zeroed.
  grep -q "^MP_MAX_CHANGED_LINES=0$" "$policy" ||
    fail "export classes: the docs-class line cap was not zeroed"
  grep -q "^MP_TESTS_MAX_CHANGED_LINES=0$" "$policy" ||
    fail "export classes: the tests-class line cap was not zeroed"

  # Every class's allow list is the sentinel and nothing else. The arrays are
  # read out of the sourced file rather than grepped, because the EXCLUSION lists
  # are kept on purpose and legitimately mention real paths.
  for arr in MP_ALLOWED_PATHS MP_TESTS_ALLOWED_PATHS; do
    entries=$(/bin/bash -c "set -uo pipefail; source '$policy'; printf '%s\n' \"\${${arr}[@]}\"" 2>&1)
    [ "$entries" = '__UNCONFIGURED_AUTO_APPROVE_CLASS__/**' ] ||
      fail "export classes: $arr is not blanked to the sentinel alone — the source repo's live allow list leaked into the port.
--- got ---
$entries"
  done

  # The property that matters, asked of the policy itself: nothing this repo
  # auto-merges is in class over there.
  for p in \
    'docs/x.md' \
    'README.md' \
    'server/tests/routes/auth.test.ts' \
    'client/src/hooks/useSession.test.ts' \
    'client/src/test/vite-config.test.ts'; do
    classified=$(/bin/bash -c "set -uo pipefail; source '$policy'; c=\$(mp_class_of_path '$p'); printf '%s' \"\${c:-OUT}\"" 2>&1)
    [ "$classified" = "OUT" ] ||
      fail "export classes: the placeholder policy put '$p' in a class ('$classified') — a fresh port must auto-merge NOTHING until its own founder decides otherwise"
  done

  rm -rf -- "$target"
  pass "export classes: EVERY auto-approve class is blanked in the exported kit — both allow lists are the sentinel alone, both caps are 0, and the placeholder classifies none of the paths this repo would auto-merge (docs, README, server/client leaf tests). A class added without teaching _ek_write_policy to blank it fails this test instead of shipping live"
}

# _ek_fake_source — a scratch, MUTABLE copy of this repo's kit source.
#
# export-kit.sh reads the policy it blanks from $SCRIPT_DIR/merge-policy.sh and
# everything else it ships from $SCRIPT_DIR/../.., so a copy of scripts/ and
# docs/ is a complete source tree. The tests below have to add a class to
# merge-policy.sh and to edit _ek_write_policy itself, and neither may happen to
# the real files — hence the copy. Deliberately not a git checkout: the generator
# already handles that (the manifest records "source is not a git checkout"), and
# it keeps the fixture from reaching this repo's .git.
_ek_fake_source() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-src.XXXXXX")
  cp -R "$EK_SOURCE_REPO/scripts" "$root/scripts" || fail "fake source: could not copy scripts/"
  cp -R "$EK_SOURCE_REPO/docs" "$root/docs" || fail "fake source: could not copy docs/"
  printf '%s' "$root"
}

# _ek_add_third_class <fake-source-root> — append an auto-approve class the
# generator has never been taught about, in the same shape as the real two.
_ek_add_third_class() {
  cat >>"$1/scripts/multi-agent/merge-policy.sh" <<'CLASS'

MP_INTEG_ALLOWED_PATHS=(
  'server/tests/integration/**/*.test.ts'
)
MP_INTEG_MAX_CHANGED_LINES=500
CLASS
}

# _ek_export_status <fake-source-root> <target-out-var> — run THAT tree's
# generator into a fresh target; print its exit status. The target path is echoed
# on the second line so a caller that cares can inspect what shipped.
_ek_export_status() {
  local root="$1" target status=0
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-mut.XXXXXX")
  bash "$root/scripts/multi-agent/export-kit.sh" "$target" \
    --label-prefix com.example.mutation >/dev/null 2>&1 || status=$?
  printf '%s\n%s\n' "$status" "$target"
}

test_export_kit_guard_trips_on_unblanked_class() {
  # The mutation this pins, and why the suite could not already see it.
  #
  # Every assertion in _ek_write_policy — and test_export_kit_blanks_every_class
  # above — runs against THIS repo's two classes, so all of them are blind to a
  # class that does not exist yet. The failure mode that matters is ADDITIVE:
  # someone adds MP_<X>_ALLOWED_PATHS to merge-policy.sh, does not teach
  # _ek_write_policy to blank it, and the export succeeds while shipping this
  # repo's live founder authorization into someone else's repo, under a banner
  # promising that nothing auto-merges. A suite that only ever runs the real
  # 2-class source cannot know what a 3-class source would do, so the source is
  # mutated here.
  #
  # Three cases, because a guard that only ever trips is as useless as one that
  # never does: it must trip on the class it was NOT taught, stay quiet on the
  # class it WAS, and still catch a blanking rule going missing.
  local root out status target entries cap ins

  # --- 1. a class the generator was never taught → the export must DIE --------
  root=$(_ek_fake_source)
  _ek_add_third_class "$root"
  out=$(_ek_export_status "$root")
  status=$(printf '%s' "$out" | sed -n 1p)
  target=$(printf '%s' "$out" | sed -n 2p)
  [ "$status" -ne 0 ] ||
    fail "export guard: merge-policy.sh grew a third auto-approve class that _ek_write_policy does not blank, and the export SUCCEEDED — the source repo's live allow list just shipped to a port that was promised the opposite"
  rm -rf -- "$root" "$target"

  # --- 2. the same class, blanked → the export must SUCCEED ------------------
  # Without this case the guard could be satisfied by anything that always dies
  # on a third class, which would make the policy unextendable rather than safe.
  root=$(_ek_fake_source)
  _ek_add_third_class "$root"
  ins=$(mktemp "${TMPDIR:-/tmp}/ma-export-ins.XXXXXX")
  cat >"$ins" <<'RULES'
    /^MP_INTEG_ALLOWED_PATHS=\(/ {
      print "MP_INTEG_ALLOWED_PATHS=("
      print "  '\''__UNCONFIGURED_AUTO_APPROVE_CLASS__/**'\''"
      skip = 1
      next
    }
    /^MP_INTEG_MAX_CHANGED_LINES=/ {
      print "MP_INTEG_MAX_CHANGED_LINES=0"
      next
    }
RULES
  # Inserted at the top of the awk program, which is where rule order does not
  # matter — each rule matches a distinct anchored variable name.
  sed -e "/^  awk '$/r $ins" "$root/scripts/multi-agent/export-kit.sh" >"$root/ek.tmp" ||
    fail "export guard: could not stage the taught-generator mutation"
  mv "$root/ek.tmp" "$root/scripts/multi-agent/export-kit.sh"
  out=$(_ek_export_status "$root")
  status=$(printf '%s' "$out" | sed -n 1p)
  target=$(printf '%s' "$out" | sed -n 2p)
  [ "$status" -eq 0 ] ||
    fail "export guard: a third class that IS blanked was refused (exit $status) — the guard is counting rather than checking, and the policy cannot be extended without editing the guard"
  # ...and it must have shipped blanked, not merely been counted.
  entries=$(/bin/bash -c "set -uo pipefail; source '$target/scripts/multi-agent/merge-policy.sh'; printf '%s\n' \"\${MP_INTEG_ALLOWED_PATHS[@]}\"" 2>&1)
  [ "$entries" = '__UNCONFIGURED_AUTO_APPROVE_CLASS__/**' ] ||
    fail "export guard: the taught third class passed the guard but did not come out blanked.
--- got ---
$entries"
  cap=$(grep -c '^MP_INTEG_MAX_CHANGED_LINES=0$' "$target/scripts/multi-agent/merge-policy.sh")
  [ "$cap" -eq 1 ] ||
    fail "export guard: the taught third class kept a live line cap"
  rm -f -- "$ins"
  rm -rf -- "$root" "$target"

  # --- 3. an existing blanking rule removed → the export must DIE ------------
  # The subtractive mutation. It is the one that was checked by hand before, and
  # it stays checked: the source keeps both classes, the generator loses the
  # tests-class rule, so the tests class flows through live.
  root=$(_ek_fake_source)
  awk 'index($0, "/^MP_TESTS_ALLOWED_PATHS=\\(/ {") { drop = 1; next }
       drop && $0 == "    }" { drop = 0; next }
       !drop' "$EK_SOURCE_REPO/scripts/multi-agent/export-kit.sh" >"$root/ek.tmp" ||
    fail "export guard: could not stage the removed-rule mutation"
  grep -q 'MP_TESTS_ALLOWED_PATHS=(' "$root/ek.tmp" &&
    fail "export guard: the removed-rule mutation did not actually remove the rule — the case below would pass for the wrong reason"
  mv "$root/ek.tmp" "$root/scripts/multi-agent/export-kit.sh"
  chmod +x "$root/scripts/multi-agent/export-kit.sh"
  out=$(_ek_export_status "$root")
  status=$(printf '%s' "$out" | sed -n 1p)
  target=$(printf '%s' "$out" | sed -n 2p)
  [ "$status" -ne 0 ] ||
    fail "export guard: _ek_write_policy lost its tests-class blanking rule and the export SUCCEEDED — the tests class shipped live"
  rm -rf -- "$root" "$target"

  pass "export guard: the export dies when merge-policy.sh declares a class _ek_write_policy does not blank (the ADDITIVE mutation — a hardcoded sentinel count cannot see it, because an unblanked class contributes no sentinel), succeeds once that class IS blanked, and still dies when an existing blanking rule is removed"
}

test_export_kit_policy_survives_bash32() {
  # Why the placeholder uses a sentinel path instead of an empty array: on macOS
  # bash 3.2, expanding an empty array under `set -u` ("${arr[@]}") is a FATAL
  # unbound-variable error. A blanked-to-empty MP_ALLOWED_PATHS would therefore
  # make the policy CRASH mid-tick rather than fail closed — the one failure mode
  # a safety default must not have. This pins that, in the shell the launchd
  # agents actually run (/bin/bash), with the real gate function.
  local target policy status
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-bash32.XXXXXX")
  bash "$EXPORT_KIT" "$target" --label-prefix com.example.bash32 >/dev/null 2>&1 ||
    fail "export bash32: export-kit.sh exited nonzero"
  policy="$target/scripts/multi-agent/merge-policy.sh"

  status=0
  /bin/bash -c "set -uo pipefail; source '$policy'; mp_path_in_class 'docs/x.md'; mp_path_in_class 'README.md'" >/dev/null 2>&1 || status=$?
  # 1 = classified out of class (correct). 127/2 = unbound variable / syntax
  # death, which is what an empty-array blank would produce.
  [ "$status" -eq 1 ] ||
    fail "export bash32: the placeholder policy did not cleanly return 'out of class' under bash 3.2 set -u (exit $status)"

  rm -rf -- "$target"
  pass "export bash32: the placeholder merge policy fails CLOSED (not fatal) under /bin/bash 3.2 with set -u — the empty-array trap is avoided"
}

test_export_kit_persona_skeletons() {
  local target persona
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-personas.XXXXXX")

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.personas >/dev/null 2>&1 ||
    fail "export personas: export-kit.sh exited nonzero"

  for persona in builder validator scribe; do
    local file="$target/docs/personas/$persona.md"
    # The bolded form is what a collapsed gate emits; the skeleton banner also
    # mentions <<PROJECT GATE ...>> in prose and would satisfy a looser match
    # even if nothing had been collapsed.
    grep -q '\*\*<<PROJECT GATE' "$file" ||
      fail "export personas: $persona.md has no <<PROJECT GATE>> placeholder — this repo's gates would ship as if universal"
    grep -q 'ma:gate' "$file" &&
      fail "export personas: $persona.md still carries raw ma:gate markers"

    # The invariant contract must survive the generation. These are the rules
    # that make the loop safe regardless of repo: they are never placeholders.
    grep -q 'Renaming the claimed file to a state-suffixed name' "$file" ||
      fail "export personas: $persona.md lost the claimed-file contract"
    grep -q 'pm_approved_pass' "$file" ||
      fail "export personas: $persona.md lost the pm_approved_pass prohibition"
  done

  # The project gates must be GONE, not carried over as if they were universal.
  grep -q 'db:generate' "$target/docs/personas/builder.md" &&
    fail "export personas: builder.md still names this repo's bootstrap command"
  grep -q 'sfw npm' "$target/docs/personas/builder.md" &&
    fail "export personas: builder.md still names this repo's package-manager wrapper"
  grep -q 'db:generate' "$target/docs/personas/validator.md" &&
    fail "export personas: validator.md still names this repo's bootstrap command"

  # Remote fencing is contract, not gate: the Builder/Validator no-remotes rule
  # and the Scribe's never-merge rule must both survive verbatim.
  grep -q 'Never touch remotes' "$target/docs/personas/builder.md" ||
    fail "export personas: builder.md lost the no-remotes rule"
  grep -q 'You NEVER merge' "$target/docs/personas/scribe.md" ||
    fail "export personas: scribe.md lost the never-merge rule"
  grep -q 'git-push-guard.sh' "$target/docs/personas/scribe.md" ||
    fail "export personas: scribe.md lost the push-guard rule"

  rm -rf -- "$target"
  pass "export personas: skeletons keep the invariant contract (claimed-file, pm_approved_pass, no-remotes, never-merge, push-guard) and replace every project gate (bootstrap, type-check, package manager, review tooling) with a loud placeholder"
}

test_export_kit_prefix_applied() {
  local target f source_default
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-prefix.XXXXXX")
  # Read from the constant, never written as a literal: this file is itself one
  # of the exported files, so a hardcoded source prefix here would appear in the
  # export and fail the very assertion it is used for.
  source_default="$MA_DEFAULT_LABEL_PREFIX"

  bash "$EXPORT_KIT" "$target" --label-prefix com.example.ported >/dev/null 2>&1 ||
    fail "export prefix: export-kit.sh exited nonzero"

  # All three files that carry the prefix must be rewritten together — an
  # installer and a test suite that disagree is exactly the drift the single
  # anchored line exists to prevent.
  for f in install-loops.sh uninstall-loops.sh test-queue.sh; do
    grep -q '^MA_DEFAULT_LABEL_PREFIX="com.example.ported"$' "$target/scripts/multi-agent/$f" ||
      fail "export prefix: $f did not get the ported label prefix"
    grep -qF "$source_default" "$target/scripts/multi-agent/$f" &&
      fail "export prefix: $f still carries the source repo's label prefix"
  done

  # And the ported installer must actually USE it.
  local agents_dir count
  agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-agents.XXXXXX")
  MA_LAUNCH_AGENTS_DIR="$agents_dir" bash "$target/scripts/multi-agent/install-loops.sh" >/dev/null 2>&1 ||
    fail "export prefix: the ported install-loops.sh exited nonzero"
  count=$(find "$agents_dir" -name 'com.example.ported.*.plist' | grep -c .)
  [ "$count" -eq 4 ] ||
    fail "export prefix: the ported installer wrote $count com.example.ported.* plists, expected 4"

  rm -rf -- "$target" "$agents_dir"
  pass "export prefix: --label-prefix rewrites the installers AND the test suite together, and the ported installer writes plists under the new prefix by default"
}

test_export_kit_refuses_nonempty_target() {
  local target status
  target=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-nonempty.XXXXXX")
  printf 'a persona someone already filled in\n' >"$target/precious.md"

  status=0
  bash "$EXPORT_KIT" "$target" --label-prefix com.example.nonempty >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "export nonempty: a non-empty target was accepted without --force"
  [ ! -d "$target/scripts" ] || fail "export nonempty: the refused export still wrote files"
  [ -f "$target/precious.md" ] || fail "export nonempty: the refused export destroyed existing content"

  # --force is the deliberate opt-in.
  bash "$EXPORT_KIT" "$target" --label-prefix com.example.nonempty --force >/dev/null 2>&1 ||
    fail "export nonempty: --force did not allow the export"
  [ -f "$target/scripts/multi-agent/queue.sh" ] || fail "export nonempty: --force did not export the kit"

  # An invalid prefix is refused at export time, not deferred to install time.
  # The multiline prefix is here for the same reason as in the installer test:
  # a per-line grep match would accept it and bake a newline into every plist
  # filename the ported installer writes.
  local bad badtarget
  for bad in 'not-reverse-dns' $'com.foo\ncom.bar'; do
    badtarget=$(mktemp -d "${TMPDIR:-/tmp}/ma-export-badpfx.XXXXXX")
    status=0
    bash "$EXPORT_KIT" "$badtarget" --label-prefix "$bad" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] ||
      fail "export nonempty: an invalid --label-prefix was accepted at export time: '$bad'"
    [ ! -d "$badtarget/scripts" ] ||
      fail "export nonempty: the refused export still wrote a kit for '$bad'"
    rm -rf -- "$badtarget"
  done

  rm -rf -- "$target"
  pass "export nonempty: a non-empty target is refused (existing content untouched) unless --force; an invalid --label-prefix is refused at export time"
}

# --- export-kit.sh --deploy -------------------------------------------------

# A throwaway git repo with one commit and a pre-existing .gitignore, printed as
# a PHYSICAL path: on macOS /tmp is a symlink to /private/tmp, and export-kit
# compares its target against git's idea of the repo root, which is always
# physical. A logical path here would make the deploy refuse its own fixture.
_ek_scratch_repo() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")
  git -C "$dir" init -q
  printf 'node_modules/\n' >"$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=test@example.com -c user.name=test commit -qm 'init' >/dev/null
  (cd "$dir" && pwd -P)
}

# _ek_manifest_verifies <kit-root> — do the manifest's SHA-256 lines still match
# the files on disk? Run from the kit root, exactly as the manifest tells a human
# to run it.
_ek_manifest_verifies() {
  (cd "$1" && grep -E '^[0-9a-f]{64}  ' EXPORT-MANIFEST.md | shasum -a 256 -c --status -)
}

test_deploy_sets_up_target() {
  local repo agents_dir manifest log d plists
  repo=$(_ek_scratch_repo ma-deploy-target)
  # If deploy ever installed a launchd agent, it would land here — and this test
  # would see it. Activation is the human's, and this is how that stays true.
  agents_dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-deploy-agents.XXXXXX")

  MA_LAUNCH_AGENTS_DIR="$agents_dir" bash "$EXPORT_KIT" "$repo" --deploy \
    --label-prefix com.example.deployed >/dev/null 2>&1 ||
    fail "deploy: --deploy exited nonzero against a clean git repo root"

  [ -x "$repo/scripts/multi-agent/queue.sh" ] ||
    fail "deploy: the kit itself was not written into the target"

  # The queue is gitignored, ANCHORED, and the operator's existing rules survive.
  grep -q '^/multi-agent/$' "$repo/.gitignore" ||
    fail "deploy: /multi-agent/ was not appended to the target's .gitignore"
  grep -q '^node_modules/$' "$repo/.gitignore" ||
    fail "deploy: the target's pre-existing .gitignore content was destroyed"

  # Ask git, not the file: an UNANCHORED `multi-agent/` rule would also ignore
  # scripts/multi-agent/ — the kit that was just deployed — and the operator
  # would commit a repo with the loop system silently missing from it.
  git -C "$repo" check-ignore -q multi-agent/builder-tasks ||
    fail "deploy: git does not actually ignore the queue directory"
  git -C "$repo" check-ignore -q scripts/multi-agent/queue.sh &&
    fail "deploy: the ignore rule also swallowed scripts/multi-agent/ — the deployed kit could never be committed"

  for d in builder-tasks validator-notes scribe-notes merge-approvals logs archive; do
    [ -d "$repo/multi-agent/$d" ] ||
      fail "deploy: queue directory multi-agent/$d was not created"
  done

  # The KIT'S OWN suite ran INSIDE the target and passed. The log is the artifact
  # that proves it happened; the SKIP line proves it was the TARGET's copy that
  # ran (a port has no export-kit.sh, so it skips these very tests) rather than
  # this source repo's suite being re-run in place.
  log="$repo/multi-agent/logs/deploy-selftest.log"
  [ -f "$log" ] ||
    fail "deploy: no target-side test run happened — deploy-selftest.log is absent"
  grep -q '^ALL TESTS PASSED$' "$log" ||
    fail "deploy: the target-side suite did not end with ALL TESTS PASSED"
  grep -q 'SKIP: export-kit tests' "$log" ||
    fail "deploy: the suite that ran was not the TARGET's copy (a ported kit has no export-kit.sh and must skip those tests)"

  # Deploy NEVER activates. No plist, ever.
  plists=$(find "$agents_dir" -name '*.plist' | grep -c .)
  [ "$plists" -eq 0 ] ||
    fail "deploy: $plists launchd plists were written — deploy must never install or load an agent"

  # Provenance, end to end against a real repo.
  manifest="$repo/EXPORT-MANIFEST.md"
  grep -q '^| Mode | deploy |$' "$manifest" ||
    fail "deploy: the manifest did not record mode=deploy"
  grep -qF "$repo" "$manifest" ||
    fail "deploy: the manifest did not record the kit root"
  _ek_manifest_verifies "$repo" ||
    fail "deploy: the manifest's SHA-256 lines do not verify against the delivered files"

  # And the checksums are real, not decorative: edit one delivered byte and the
  # manifest must notice.
  printf '\n# edited after deploy\n' >>"$repo/scripts/multi-agent/queue.sh"
  _ek_manifest_verifies "$repo" &&
    fail "deploy: an edited kit file still verified against the manifest — the checksums are decorative"

  rm -rf -- "$repo" "$agents_dir"
  pass "deploy: a clean repo root gets the kit, an ANCHORED /multi-agent/ ignore rule (git agrees, and the kit itself stays committable), the six queue directories, a green run of the TARGET's own suite, and a SHA-verifiable manifest that detects a single edited byte — and not one launchd plist"
}

# The failure this pins is the quiet one: a target that ALREADY carries a bare
# `multi-agent/` rule. Bare means unanchored, and unanchored matches that
# directory name at every depth — scripts/multi-agent/, the deployed kit,
# included. Deploy used to read such a rule as "already ignored", leave the
# .gitignore alone and exit 0; its own target-side suite passed, because that
# suite runs the files from disk and git's opinion of them never comes up. The
# operator committed a repo with no loop system in it.
#
# Both halves assert against `git check-ignore`, never against the text of
# .gitignore — the text is what fooled the old check.
test_deploy_bare_ignore_rule() {
  local repo out status=0 rules
  repo=$(_ek_scratch_repo ma-deploy-bare-ignore)
  printf 'node_modules/\nmulti-agent/\n' >"$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=test@example.com -c user.name=test commit -qm 'bare ignore' >/dev/null

  # Precondition holds in the fixture: git really would swallow the kit here.
  git -C "$repo" check-ignore -q --no-index scripts/multi-agent/queue.sh ||
    fail "deploy bare ignore: the fixture is wrong — a bare multi-agent/ rule does not ignore scripts/multi-agent/, so this test proves nothing"

  out=$(bash "$EXPORT_KIT" "$repo" --deploy --label-prefix com.example.bare 2>&1) || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy bare ignore: a target whose .gitignore already swallows scripts/multi-agent/ was deployed into and reported success — the operator would commit a repo with the loop system missing from it"
  printf '%s' "$out" | grep -q 'scripts/multi-agent/' ||
    fail "deploy bare ignore: the deploy failed, but not with the ignore refusal — the operator is not told the rule they already have is what stopped it"

  # Refused BEFORE the first byte: same property every other deploy refusal holds.
  [ ! -d "$repo/scripts" ] || fail "deploy bare ignore: the refused deploy still wrote the kit"
  [ ! -d "$repo/multi-agent" ] || fail "deploy bare ignore: the refused deploy still created a queue"
  [ ! -f "$repo/EXPORT-MANIFEST.md" ] || fail "deploy bare ignore: the refused deploy still wrote a manifest"
  grep -q '^multi-agent/$' "$repo/.gitignore" ||
    fail "deploy bare ignore: the refused deploy rewrote the operator's .gitignore behind their back — a refusal must leave the target exactly as it was"

  # The other direction: the operator does what the refusal told them to and
  # anchors the rule. Deploy now accepts it, leaves their .gitignore alone (the
  # rule is already correct), and the contract holds in git: queue ignored, kit
  # committable.
  printf 'node_modules/\n/multi-agent/\n' >"$repo/.gitignore"
  bash "$EXPORT_KIT" "$repo" --deploy --label-prefix com.example.anchored >/dev/null 2>&1 ||
    fail "deploy bare ignore: a target whose .gitignore already carries the ANCHORED rule was refused — anchoring is exactly what the refusal asked for"

  git -C "$repo" check-ignore -q multi-agent/builder-tasks ||
    fail "deploy bare ignore: the queue is not ignored after deploying into a repo that already had the anchored rule"
  git -C "$repo" check-ignore -q scripts/multi-agent/queue.sh &&
    fail "deploy bare ignore: the kit is ignored after deploy — the invariant is broken on the pre-existing-rule path"

  rules=$(grep -c 'multi-agent' "$repo/.gitignore")
  [ "$rules" -eq 1 ] ||
    fail "deploy bare ignore: deploy appended to a .gitignore that already had a correct anchored rule ($rules multi-agent lines now)"

  rm -rf -- "$repo"
  pass "deploy bare ignore: a pre-existing UNANCHORED multi-agent/ rule (which also swallows scripts/multi-agent/) is refused before anything is written, and the operator's .gitignore survives; once anchored, the same repo deploys and git agrees the queue is ignored and the kit is not"
}

test_deploy_refuses_nonrepo_target() {
  local dir status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/ma-deploy-nonrepo.XXXXXX")

  bash "$EXPORT_KIT" "$dir" --deploy --label-prefix com.example.nonrepo >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy nonrepo: a directory that is not a git repo was accepted as a deploy target"
  [ ! -d "$dir/scripts" ] || fail "deploy nonrepo: the refused deploy still wrote the kit"
  [ ! -d "$dir/multi-agent" ] || fail "deploy nonrepo: the refused deploy still created a queue"
  [ ! -f "$dir/EXPORT-MANIFEST.md" ] || fail "deploy nonrepo: the refused deploy still wrote a manifest"

  # A SUBDIRECTORY of a repo is refused too: the queue ignore rule and the kit's
  # paths are both repo-root-relative, so a kit deployed one level down is a kit
  # whose queue is not ignored and whose scripts are not where anything looks.
  local repo
  repo=$(_ek_scratch_repo ma-deploy-subdir)
  mkdir -p "$repo/packages/web"
  status=0
  bash "$EXPORT_KIT" "$repo/packages/web" --deploy --label-prefix com.example.subdir >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy nonrepo: a subdirectory of a repo was accepted as a deploy target — the queue ignore rule would not cover it"
  [ ! -d "$repo/packages/web/scripts" ] ||
    fail "deploy nonrepo: the refused subdirectory deploy still wrote the kit"

  rm -rf -- "$dir" "$repo"
  pass "deploy nonrepo: a non-repo directory and a repo SUBDIRECTORY are both refused, and a refused deploy writes nothing at all — no kit, no queue, no manifest"
}

test_deploy_refuses_source_repo() {
  local status=0
  bash "$EXPORT_KIT" "$EK_SOURCE_REPO" --deploy --label-prefix com.example.self >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy self: export-kit deployed into its OWN source repo — that overwrites the live personas with skeletons generated from themselves and blanks the live merge policy"
  [ ! -f "$EK_SOURCE_REPO/EXPORT-MANIFEST.md" ] ||
    fail "deploy self: the refused self-deploy still wrote a manifest into the source repo"

  pass "deploy self: deploying into the source repo is refused — it would overwrite the live personas with their own skeletons and blank the live merge policy"
}

test_deploy_refuses_shared_git_dir() {
  # The path comparison alone is not enough. A git WORKTREE of the source repo
  # has a DIFFERENT path but is the SAME repository: a deploy there writes
  # skeleton personas and a blanked policy into a checkout of the very repo the
  # kit is generated from, ready to be committed back over the live files. The
  # refusal is therefore on the shared git directory, not just the path.
  #
  # Staged with a scratch repo and a copy of the generator, so the fixture never
  # touches this repo's real .git.
  local repo wt status=0
  repo=$(_ek_scratch_repo ma-deploy-shared)
  wt="$repo-worktree"

  git -C "$repo" worktree add -q --detach "$wt" >/dev/null 2>&1 ||
    fail "deploy shared: could not create the worktree fixture"
  mkdir -p "$repo/scripts/multi-agent"
  cp "$EXPORT_KIT" "$repo/scripts/multi-agent/export-kit.sh"

  bash "$repo/scripts/multi-agent/export-kit.sh" "$wt" --deploy \
    --label-prefix com.example.shared >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy shared: deploying into a WORKTREE of the source repo was accepted — a different path, but the same repository"
  [ ! -f "$wt/EXPORT-MANIFEST.md" ] ||
    fail "deploy shared: the refused deploy still wrote into the worktree"

  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf -- "$repo" "$wt"
  pass "deploy shared: a git worktree of the source repo — different path, same git directory — is refused as a deploy target, which a path comparison alone would have waved through"
}

test_deploy_refuses_redeploy_without_force() {
  local repo persona status=0
  repo=$(_ek_scratch_repo ma-deploy-redeploy)

  bash "$EXPORT_KIT" "$repo" --deploy --label-prefix com.example.first >/dev/null 2>&1 ||
    fail "deploy redeploy: the first deploy failed"

  # The operator does the work the deploy told them to: they fill in a persona.
  persona="$repo/docs/personas/builder.md"
  printf 'THE OPERATOR FILLED THIS IN\n' >>"$persona"

  bash "$EXPORT_KIT" "$repo" --deploy --label-prefix com.example.second >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] ||
    fail "deploy redeploy: a second deploy into an already-deployed repo was accepted without --force — it would silently replace the filled-in personas with placeholders again"
  grep -q 'THE OPERATOR FILLED THIS IN' "$persona" ||
    fail "deploy redeploy: the refused re-deploy destroyed the operator's filled-in persona"
  grep -q '^| launchd label prefix | com.example.first |$' "$repo/EXPORT-MANIFEST.md" ||
    fail "deploy redeploy: the refused re-deploy rewrote the manifest"

  # --force is the deliberate opt-in, and it does exactly what its refusal
  # message warns: the filled-in persona goes back to being a skeleton.
  bash "$EXPORT_KIT" "$repo" --deploy --label-prefix com.example.second --force >/dev/null 2>&1 ||
    fail "deploy redeploy: --force did not allow the re-deploy"
  grep -q 'THE OPERATOR FILLED THIS IN' "$persona" &&
    fail "deploy redeploy: --force claimed to overwrite but left the old persona in place"
  grep -q '^| launchd label prefix | com.example.second |$' "$repo/EXPORT-MANIFEST.md" ||
    fail "deploy redeploy: --force did not refresh the manifest"

  rm -rf -- "$repo"
  pass "deploy redeploy: a second deploy over an already-deployed repo is refused (the operator's filled-in persona and the manifest both survive) unless --force, which then overwrites exactly as its warning says"
}

test_ref_targets_main_positive
test_ref_targets_main_negative
test_guarded_push_refuses_main
test_guarded_push_allows_branch
test_scribe_approval_green_merges
test_scribe_approval_red_no_merge
test_scribe_approval_head_mismatch_no_merge
test_scribe_approval_from_nonrepo_cwd_merges
test_scribe_approval_gh_unavailable
test_scribe_approval_refusals_audited
test_scribe_rejected_untouched
test_scribe_reminder_fires
test_scribe_pending_written
test_scribe_push_main_fails
test_scribe_push_violation_not_softened_by_findings
# Defined with the other STOP fail-back tests, but registered here: it drives
# the scribe lane, and $SCRIBE_LOOP is not assigned until this section.
test_stop_failback_blocks_scribe
test_scribe_pending_opens_in_textmate
test_scribe_reminder_reopens_pending
test_scribe_reminder_inside_interval_no_reopen
test_scribe_reminder_fresh_pending_no_reopen
test_scribe_rejected_reminder_no_reopen
test_scribe_open_failure_harmless
test_scribe_raise_failure_harmless
test_open_pending_absent_noop
test_worktree_path_distinct_by_slug
test_worktree_closeout_removes_only_own
test_run_worker_exports_ma_root_for_guard
test_pending_footer_abspath
# export-kit.sh is deliberately NOT part of the kit it generates: it builds the
# persona skeletons from the ma:gate markers in the live personas, and the
# exported skeletons have those markers stripped, so a ported copy could not
# regenerate anything. A port therefore has no export-kit.sh and nothing for
# these tests to assert — they run in the repo that OWNS the kit, and skip in a
# repo that merely received one. (This is a real skip, not a shrug: run the suite
# in the source repo before you export.)
#
# The --deploy tests each stand up a scratch git repo and deploy into it, and a
# deploy runs the deployed kit's whole suite inside that repo. So this block is
# the slow part of this file (tens of seconds, not tenths) — it is buying the
# guarantee that a port is verified in the target before anyone loads an agent
# against it, which is exactly the thing that must not be taken on trust.
if [ -f "$EXPORT_KIT" ]; then
  test_export_kit_file_set
  test_export_kit_manifest_provenance
  test_export_kit_carries_no_state_or_policy
  test_export_kit_policy_survives_bash32
  test_export_kit_persona_skeletons
  test_export_kit_blanks_every_class
  test_export_kit_guard_trips_on_unblanked_class
  test_export_kit_prefix_applied
  test_export_kit_refuses_nonempty_target
  test_deploy_sets_up_target
  test_deploy_bare_ignore_rule
  test_deploy_refuses_nonrepo_target
  test_deploy_refuses_source_repo
  test_deploy_refuses_shared_git_dir
  test_deploy_refuses_redeploy_without_force
else
  printf 'SKIP: export-kit tests — no export-kit.sh present. Expected in a ported repo:\n'
  printf '      the generator stays with the source repo. See docs/porting-guide.md.\n'
fi

test_policy_unconfigured_class_never_merges

# The tests below assert the behavior of a CONFIGURED auto-approve class, using
# docs/*.md fixtures. A fresh port has no class — export-kit.sh ships a
# fail-closed placeholder, because the class is a founder authorization about a
# specific repo and never travels — so there is nothing for them to assert
# there, and they are skipped rather than failing red. The property that holds
# in BOTH configurations is asserted unconditionally by
# test_policy_unconfigured_class_never_merges above.
#
# In THIS repo the class is configured (docs/** under a 100-line cap), so every
# one of them runs. The suite asks the policy itself whether its own fixtures are
# in class rather than assuming: if someone ever empties this repo's class, these
# tests correctly become vacuous instead of silently asserting a dead policy.
if _policy_class_configured; then
  test_merge_policy_path_classification
  test_policy_auto_merges_docs_only
  test_policy_control_surface_stays_pending
  test_policy_size_cap_stays_pending
  test_policy_failed_chain_stays_pending
  test_policy_pass2_chain_stays_pending
  test_policy_ignores_frontmatter_claim
  test_policy_red_checks_no_merge
  test_policy_revokes_stale_certificate
  test_policy_gh_failure_fails_closed
  test_policy_rename_into_docs_stays_pending
  test_policy_in_class_rename_auto_merges
  test_policy_empty_patch_fails_closed
else
  printf 'SKIP: auto-approve-class tests — no class is configured (MP_ALLOWED_PATHS matches\n'
  printf '      nothing, or the line cap is below the fixtures). Nothing auto-merges; every\n'
  printf '      PR keeps its human merge gate. This is the expected state of a fresh port:\n'
  printf '      see docs/porting-guide.md, "Tier 2 — the merge policy".\n'
fi

# The tests-only class, gated the same way and for the same reason: a fresh port
# has no tests class either, and these fixtures would have nothing to assert
# there. The two classes are gated independently, so a repo that configures one
# and not the other still runs the half it has.
if _policy_tests_class_configured; then
  test_merge_policy_tests_path_classification
  test_policy_auto_merges_tests_only
  test_policy_auto_merges_client_colocated_tests
  test_policy_tests_config_lookalike_auto_merges
  test_policy_tests_security_stays_pending
  test_policy_tests_plumbing_stays_pending
  test_policy_tests_config_stays_pending
  test_policy_tests_size_cap_stays_pending
  test_policy_tests_deletion_stays_pending
  test_policy_tests_rename_stays_pending
  test_policy_tests_pass2_stays_pending
  test_policy_tests_mixed_stays_pending
else
  printf 'SKIP: tests-only-class tests — no tests class is configured\n'
  printf '      (MP_TESTS_ALLOWED_PATHS matches nothing, or the cap is below the fixtures).\n'
  printf '      Nothing auto-merges; every PR keeps its human merge gate. This is the\n'
  printf '      expected state of a fresh port: see docs/porting-guide.md.\n'
fi


# ---------------------------------------------------------------------------
# #1055 — reused-worktree base staleness.
#
# These build a REAL git origin + clone + worktree rather than stubbing git,
# because the whole defect lives in what git actually reports for
# `origin/main..HEAD` and `HEAD..origin/main`. A stub that answers those
# questions is a stub of the thing under test.
# ---------------------------------------------------------------------------

# _mk_drift_fixture <name>  -> prints "<repo_root> <worktree_dir>"
# origin has 2 commits; the clone's worktree branch sits on the 1st, so it is
# exactly 1 behind with no work of its own.
_mk_drift_fixture() {
  local name="$1" base origin repo wt
  base="$TMP_ROOT/drift-$name"
  origin="$base/origin.git"
  repo="$base/repo"
  wt="$repo/.worktrees/900-$name"

  mkdir -p "$base"
  git init --quiet --bare -b main "$origin"
  git clone --quiet "$origin" "$repo" 2>/dev/null
  (
    cd "$repo"
    git config user.email t@t; git config user.name t
    echo one > file.txt; git add file.txt; git commit --quiet -m one
    git push --quiet origin main 2>/dev/null
    git rev-parse HEAD > "$base/first.sha"
    echo two >> file.txt; git commit --quiet -am two
    git push --quiet origin main 2>/dev/null
    git fetch --quiet origin main
    # worktree pinned to the FIRST commit => 1 behind origin/main
    git worktree add --quiet -b "auto/900-$name" "$wt" "$(cat "$base/first.sha")" 2>/dev/null
  )
  printf '%s %s\n' "$repo" "$wt"
}

test_drift_clean_worktree_fast_forwards() {
  local repo wt
  read -r repo wt <<< "$(_mk_drift_fixture ff)"

  [ "$(git -C "$wt" rev-list --count HEAD..origin/main)" -eq 1 ] \
    || fail "drift ff: fixture should start 1 behind"

  _ml_refresh_worktree_base "$wt" 900 ff 2>/dev/null

  [ "$(git -C "$wt" rev-list --count HEAD..origin/main)" -eq 0 ] \
    || fail "drift ff: worktree with no work and a clean tree was NOT advanced to origin/main"
  pass "drift: reused worktree with no own commits and a clean tree is fast-forwarded to origin/main"
}

test_drift_worktree_with_commits_is_left_alone() {
  local repo wt head_before
  read -r repo wt <<< "$(_mk_drift_fixture own)"

  ( cd "$wt"; git config user.email t@t; git config user.name t
    echo work > own.txt; git add own.txt; git commit --quiet -m "pass-1 work" )
  head_before=$(git -C "$wt" rev-parse HEAD)

  : >"$NOTIFY_LOG"
  _ml_refresh_worktree_base "$wt" 900 own 2>/dev/null

  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "drift own: worktree carrying a commit was re-pointed — work would be lost"
  [ "$(git -C "$wt" rev-list --count origin/main..HEAD)" -ge 1 ] \
    || fail "drift own: the worktree's own commit is gone"
  grep -q "behind origin/main" "$NOTIFY_LOG" \
    || fail "drift own: drift was not surfaced via ma_notify"
  pass "drift: reused worktree carrying its own commit is NOT advanced, work intact, drift notified"
}

test_drift_dirty_worktree_is_left_alone() {
  local repo wt head_before
  read -r repo wt <<< "$(_mk_drift_fixture dirty)"

  echo "uncommitted" > "$wt/scratch.txt"
  head_before=$(git -C "$wt" rev-parse HEAD)

  : >"$NOTIFY_LOG"
  _ml_refresh_worktree_base "$wt" 900 dirty 2>/dev/null

  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "drift dirty: worktree with uncommitted changes was re-pointed"
  [ -f "$wt/scratch.txt" ] \
    || fail "drift dirty: uncommitted file was destroyed"
  grep -q "behind origin/main" "$NOTIFY_LOG" \
    || fail "drift dirty: drift was not surfaced via ma_notify"
  pass "drift: reused worktree with an uncommitted edit is NOT advanced (a dirty tree is work too), file intact, drift notified"
}

test_drift_current_worktree_is_a_noop() {
  local repo wt head_before
  read -r repo wt <<< "$(_mk_drift_fixture noop)"
  git -C "$wt" merge --ff-only origin/main >/dev/null 2>&1
  head_before=$(git -C "$wt" rev-parse HEAD)

  : >"$NOTIFY_LOG"
  _ml_refresh_worktree_base "$wt" 900 noop 2>/dev/null

  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "drift noop: HEAD moved on an up-to-date worktree"
  [ ! -s "$NOTIFY_LOG" ] || fail "drift noop: an up-to-date worktree should notify nothing"
  pass "drift: an already-current worktree is a silent no-op — no move, no notification"
}

test_drift_clean_worktree_fast_forwards
test_drift_worktree_with_commits_is_left_alone
test_drift_dirty_worktree_is_left_alone
test_drift_current_worktree_is_a_noop

printf 'ALL TESTS PASSED\n'
