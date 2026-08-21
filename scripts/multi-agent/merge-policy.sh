#!/usr/bin/env bash
#
# =============================================================================
# FOUNDER DECISION REQUIRED — THIS IS A BLANKED PLACEHOLDER, NOT A POLICY.
#
# BOTH auto-approve classes below — docs-only and tests-only — are empty by
# construction: each allowed-path sentinel matches nothing and each line cap is
# 0. Nothing auto-merges. Every PR keeps its human merge gate. That is the
# correct default for a fresh port, and it is safe to leave exactly as it is.
#
# The source repo's classes were ITS founder's authorization about ITS repo.
# That authorization does not travel. Do not copy it over. If you want an
# auto-approve class here, decide it for THIS repo and write it below — this
# file, not any prose, is what actually gates a merge.
#
# The exclusion lists ARE kept, deliberately. An exclusion can only ever shrink
# a class, never widen one, and they show the discipline the source repo applied
# (its security suite is carved out of the very class it would otherwise match).
# Treat them as a worked example, not as a description of your repo.
#
# While a class is unconfigured, test-queue.sh skips that class's tests (there
# is no class to assert) and the loops run fully human-gated.
# See docs/porting-guide.md, "Tier 2 — the merge policy".
# =============================================================================
# merge-policy.sh - the ENFORCED definition of the auto-approve classes.
#
# This file is the source of truth. docs/merge-policy.md describes the classes
# for humans, but only what is written here is executed: if the two ever
# disagree, this file is what actually gates a merge.
#
# There are two classes, and a PR is in AT MOST one of them:
#
#   docs-only  — pure documentation changes (docs/**, README.md).
#   tests-only — ordinary leaf test files, and nothing else.
#
# Both are deliberately narrow. They exist so that the PRs where a human
# approval adds latency but no judgment merge without a human, while EVERYTHING
# else keeps the human gate exactly as it is today. A PR that mixes the two
# classes is in NEITHER: each class's cap and rules were authorized for that
# class's blast radius, and a mixed PR has no single answer to "which cap
# applies", so it fails closed to the human gate.
#
# Two properties make this safe, and both must survive any future edit:
#
#   1. Cannot-mint. The DECISION INPUTS are RECOMPUTED at process time from
#      GitHub and from state.log: changed paths (`gh pr diff --name-only`, plus
#      the rename/copy sources read out of the raw patch — see _mp_rename_paths),
#      size (`gh pr view --json additions,deletions`), and chain history
#      (state.log). A pending approval file may claim anything it likes in its
#      frontmatter — docs_only, eligible, approved — and every such claim is
#      ignored.
#
#      Stated precisely, because the imprecise version is what a future reader
#      will rely on when deciding whether some new field is safe to read: the
#      SUBJECT of the decision (which PR — the `pr`, `issue` and `slug` args) is
#      read from the worker-written file by _ml_policy_pass. What makes that safe
#      is not this file but the identity gates in _ml_process_one_approval, which
#      force the file's `branch` and the PR's live head to equal
#      auto/<issue>-<slug>. So a worker cannot point the policy at PR A and merge
#      PR B, and it cannot key the chain scan to a foreign issue without naming
#      its branch after that issue end to end. What a worker writes selects the
#      subject, pinned; it never supplies an answer.
#
#   2. Fail-closed. Every uncertainty — gh unavailable, unparseable output, an
#      empty diff, an empty patch, a missing state.log, a path we cannot classify
#      — resolves to INELIGIBLE, which means the PR simply stays pending for a
#      human. A bug in this file can therefore cost a human an approval click; it
#      cannot cost an unreviewed merge.
#
#      This is why no path may reach the class through a source that can HIDE a
#      path. `gh pr diff --name-only` folds a rename into its destination alone,
#      so it is never the only input: the patch is scanned for both sides of
#      every rename and copy. A gate that cannot see a path cannot fail closed on
#      it.
#
# Widening the class (adding an allowed path, raising the line cap, dropping an
# exclusion) is itself a reviewed, human-approved change — and, by construction,
# a PR that edits this file is not in the class it defines, so it cannot
# auto-approve its own widening.

# --- The class (founder-authorized) ---------------------------------------

# Paths whose changes are in-class. A trailing /** means "anything beneath this
# directory"; any other entry is an exact repo-relative path.
MP_ALLOWED_PATHS=(
  # FOUNDER DECISION REQUIRED. This sentinel matches no real path, so the
  # class is empty and nothing auto-merges. Replace it with the paths YOU
  # authorize a machine to merge with no human in the loop, or delete this
  # file and the auto-approve pass with it and keep every merge human-gated.
  '__UNCONFIGURED_AUTO_APPROVE_CLASS__/**'
)

# Control surfaces carved OUT of the class. These live under docs/ but are not
# documentation in the "prose a human reads" sense: they are the instructions
# that steer the agent loops and the personas. A change to one of them changes
# how the system behaves, so it keeps the human gate. Exclusions are checked
# first and always win over MP_ALLOWED_PATHS.
MP_EXCLUDED_PATHS=(
  # KEEP THESE. They are the loop system's own control surfaces: the prompts
  # that steer the agents and the brief contract they answer to. Add your
  # own exclusions below; do not remove these two.
  'docs/personas/**'
  'docs/brief-template.md'
)

# Total changed lines (additions + deletions) a PR may carry and stay in-class.
# A docs change larger than this is a rewrite, not an edit, and gets a human.
# FOUNDER DECISION REQUIRED. 0 means every PR exceeds the cap: a second,
# independent reason nothing auto-merges until you have decided the class.
MP_MAX_CHANGED_LINES=0

# --- The tests-only class (founder-authorized) -----------------------------

# LEAF TEST FILES ONLY. Every entry is <prefix>/**/<basename-glob>: a file
# directly under the prefix, at any depth, whose NAME matches the glob.
#
# The leaf-only shape is the safety property, not a stylistic choice. Shared test
# plumbing — setup.ts, globalSetup.ts, fixtures/*, helpers — is what a whole
# suite depends on, so a change to it can silently alter what every other test
# asserts. None of those files are named *.test.ts, so this allow list excludes
# them BY CONSTRUCTION: a fixture added tomorrow is out of class automatically,
# where an enumerated denylist would have to be remembered and updated. The
# explicit plumbing entries in MP_TESTS_EXCLUDED_PATHS below are belt-and-braces
# on top of that, not the mechanism.
#
# Client tests are anchored at client/src/ rather than client/src/test/ because
# two colocated tests live outside that directory. No *.spec.* file exists under
# client/src/ — the .spec.ts files in this repo are Playwright specs under the
# root tests/e2e/, which is excluded — so no .spec pattern is listed here. A
# pattern that matches nothing is a claim a future reader has to re-verify.
MP_TESTS_ALLOWED_PATHS=(
  # FOUNDER DECISION REQUIRED. The same sentinel, for the second class: the
  # source repo authorized ITS OWN test-file layout, which says nothing about
  # where your tests live or which of them are load-bearing. Empty until you
  # decide otherwise; nothing auto-merges.
  '__UNCONFIGURED_AUTO_APPROVE_CLASS__/**'
)

# Carved OUT of the tests class. Exclusions are checked first and always win.
#
# The security suite is the reason this list exists. server/tests/security/** IS
# a set of leaf *.test.ts files, so the allow list above would otherwise put it
# in class — and those tests are the gate: a PR that weakens one of them is the
# exact change that must not merge on a size-and-path check alone. The same logic
# covers config files and e2e specs: they decide what the safety net catches, so
# they keep the human.
#
# A '**/'-prefixed entry matches by basename at any depth. Note that these config
# globs are deliberately anchored to real config NAMES (vitest.config*, not
# *config*): a file like client/src/test/vite-config.test.ts is an ordinary leaf
# test whose name merely resembles a config, and it must stay IN class.
MP_TESTS_EXCLUDED_PATHS=(
  # The gate itself.
  'server/tests/security/**'
  # Shared plumbing, server tree. Most of these are excluded by construction too
  # (they are not *.test.ts); they are listed anyway so the intent survives a
  # future edit to the allow rules.
  #
  # fixtures/** is the one that does real work: the fixtures directory contains a
  # leaf test of its own (a test OF a fixture), so it matches the allow rule and
  # only this entry keeps it out. That is deliberate and conservative — the
  # fixtures are shared, so anything in that directory keeps a human — and it
  # costs one approval click on a file that changes rarely.
  'server/tests/setup.ts'
  'server/tests/globalSetup.ts'
  'server/tests/globalTeardown.ts'
  'server/tests/fixtures/**'
  'server/tests/README.md'
  # Shared plumbing, client tree (likewise).
  'client/src/test/setup.ts'
  'client/src/test/browser/setup.ts'
  'client/src/test/browser/helpers.ts'
  'client/src/test/test-utils/stubLocation.ts'
  # Runner and compiler configuration, anywhere in the tree.
  '**/vitest.config*'
  '**/vitest.*.config*'
  '**/tsconfig*'
  '**/playwright*'
  # End-to-end specs, and the dependency surface.
  'tests/e2e/**'
  '**/package.json'
  '**/package-lock.json'
)

# Total changed lines (additions + deletions) a tests-only PR may carry. Higher
# than the docs cap because a test file carries more lines per unit of meaning
# (setup, cases, teardown) and because the blast radius is smaller: a bad test
# change breaks CI, it does not ship to a user.
# FOUNDER DECISION REQUIRED. 0 for the same reason, for the tests class.
MP_TESTS_MAX_CHANGED_LINES=0

# --- Matching --------------------------------------------------------------

# _mp_matches <pattern> <path>
# True (0) iff <path> is matched by <pattern>. Four pattern forms, checked most
# specific first:
#
#   **/<glob>            <path>'s BASENAME matches <glob>, at any depth,
#                        including the repo root ('**/tsconfig*').
#   <dir>/**/<glob>      <path> is under <dir>/ at any depth AND its basename
#                        matches <glob> ('server/tests/**/*.test.ts').
#   <dir>/**             anything under <dir>/ ('docs/**').
#   <exact/path>         an exact repo-relative path ('README.md').
#
# Prefix matching is anchored with the trailing slash included ('docs/**' yields
# the prefix 'docs/'), so a sibling like 'docs-internal/x.md' cannot match
# 'docs/**' by string prefix alone. The same holds for the <dir>/**/<glob> form.
#
# Only the basename is glob-matched in the two <glob> forms — never the whole
# path — so a glob can never eat a '/' and reach across a directory boundary.
_mp_matches() {
  local pattern="$1" path="$2"
  case "$pattern" in
    '**/'*)
      local glob="${pattern#'**/'}"
      case "${path##*/}" in
        $glob) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *'/**/'*)
      # server/tests/**/*.test.ts -> prefix 'server/tests/', glob '*.test.ts'
      local prefix="${pattern%%'/**/'*}/" glob="${pattern##*'/**/'}"
      case "$path" in
        "$prefix"?*) ;;
        *) return 1 ;;
      esac
      case "${path##*/}" in
        $glob) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    */'**')
      local prefix="${pattern%'**'}" # keeps the trailing slash: docs/** -> docs/
      case "$path" in
        "$prefix"?*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      [ "$path" = "$pattern" ]
      ;;
  esac
}

# mp_path_in_class <path>
# True (0) iff a single changed path is in the auto-approve class: it matches an
# allowed pattern AND no exclusion. Anything unusual — an empty path, an
# absolute path, or one containing a .. segment — is rejected rather than
# classified, so a surprising diff can never be waved through.
mp_path_in_class() {
  local path="$1" pattern

  [ -n "$path" ] || return 1
  case "$path" in
    /* | *'..'*) return 1 ;;
  esac

  for pattern in "${MP_EXCLUDED_PATHS[@]}"; do
    if _mp_matches "$pattern" "$path"; then
      return 1
    fi
  done

  for pattern in "${MP_ALLOWED_PATHS[@]}"; do
    if _mp_matches "$pattern" "$path"; then
      return 0
    fi
  done

  return 1
}

# mp_path_in_tests_class <path>
# True (0) iff a single changed path is in the tests-only class. Same shape and
# same fail-closed rejections as mp_path_in_class above: exclusions are checked
# before the allow list and always win, and an empty, absolute or ..-bearing path
# is rejected before any glob runs rather than classified.
mp_path_in_tests_class() {
  local path="$1" pattern

  [ -n "$path" ] || return 1
  case "$path" in
    /* | *'..'*) return 1 ;;
  esac

  for pattern in "${MP_TESTS_EXCLUDED_PATHS[@]}"; do
    if _mp_matches "$pattern" "$path"; then
      return 1
    fi
  done

  for pattern in "${MP_TESTS_ALLOWED_PATHS[@]}"; do
    if _mp_matches "$pattern" "$path"; then
      return 0
    fi
  done

  return 1
}

# mp_class_of_path <path>
# Prints the name of the class <path> is in — 'docs' or 'tests' — or nothing at
# all if it is in neither. The classes are disjoint by their values; if a future
# edit ever makes them overlap, docs wins here, and mp_eligible's mixed-class
# check below is what keeps that from widening either cap.
mp_class_of_path() {
  local path="$1"
  if mp_path_in_class "$path"; then
    printf 'docs'
  elif mp_path_in_tests_class "$path"; then
    printf 'tests'
  fi
}

# --- Renames ---------------------------------------------------------------

# _mp_rename_paths
# Reads a raw patch on stdin and prints the paths that `gh pr diff --name-only`
# does not report on their own: both sides of every rename and every copy.
#
# Git folds a rename into a SINGLE entry named for its destination. A PR that
# does `git mv server/src/index.ts docs/index.ts` therefore reports
# `docs/index.ts` as its only changed path, and — because the content moved
# rather than changed — 0 additions and 0 deletions. The source path is not
# merely misclassified, it is invisible, so both the path gate and the size gate
# are defeated by the same construct. The `rename from` / `copy from` headers in
# the patch are the only place that path appears.
#
# These headers are preferred over the `diff --git a/<old> b/<new>` header, which
# cannot be split unambiguously when a path contains a space. Destination paths
# are printed too; they are already in the --name-only set, but reading them from
# the same source keeps this correct even if --name-only's behavior changes.
#
# Only a real extended header can match: every content line in a unified diff is
# prefixed with '+', '-' or ' ', so a docs file whose text happens to contain the
# words "rename from" cannot forge one at column 0.
#
# A path git chose to C-quote (non-ASCII, control characters) is printed with its
# quotes intact. It matches no allowed pattern, so it lands as INELIGIBLE — the
# fail-closed direction.
_mp_rename_paths() {
  sed -n \
    -e 's/^rename from //p' \
    -e 's/^rename to //p' \
    -e 's/^copy from //p' \
    -e 's/^copy to //p'
}

# --- Deletions -------------------------------------------------------------

# _mp_patch_has_deletion
# Reads a raw patch on stdin. True (0) iff the PR DELETES a file.
#
# Only the tests-only class asks this, and it is the rule that class most needs.
# Deleting a test silently shrinks the safety net: the suite still passes — it
# passes more easily — so no check goes red to flag it, and a small test file
# costs few enough lines to sit comfortably under the cap. "The tests are green"
# is worth nothing if the missing test is the one that would have been red.
# Removing coverage is a judgment call about risk, which is the definition of
# what keeps a human.
#
# `deleted file mode` is an extended header at column 0. Every content line in a
# unified diff is prefixed with '+', '-' or ' ', so a test file whose own text
# contains those words cannot forge one.
_mp_patch_has_deletion() {
  grep -q '^deleted file mode '
}

# --- Chain history ---------------------------------------------------------

# _mp_chain_clean <issue> <state-log>
# True (0) iff this task's run through the queue was clean and first-pass:
# state.log records at least one transition for the issue, none of them into
# .failed or .blocked, and none at pass > 1 (i.e. the Validator cleared it on
# pass 1 — no rework cycle). A task that needed a second pass, or that failed
# anywhere on the way, is not one we auto-merge on a size-and-path check alone.
#
# state.log lines carry `issue=<n>` but no slug, so the scan is keyed by issue.
# Where an issue has two concurrent slugs, a sibling's failure makes this issue
# ineligible too. That is the fail-closed direction: the cost is a human
# approval click, never an unreviewed merge.
#
# Fields are matched whole (`$i == "issue=870"`), so issue 870 is never
# confused with 8700, and a reason= string that happens to contain the word
# "blocked" is not mistaken for a transition into .blocked.md (only the
# `from->to` field is read for that).
_mp_chain_clean() {
  local issue="$1" log="$2"
  [ -f "$log" ] || return 1
  awk -v want="issue=$issue" '
    {
      seen_issue = 0
      for (i = 1; i <= NF; i++) {
        if ($i == want) { seen_issue = 1 }
      }
      if (!seen_issue) { next }
      seen = 1
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-z]+->(failed|blocked)$/) { bad = 1 }
        if ($i ~ /^pass=[0-9]+$/) {
          if (substr($i, 6) + 0 > 1) { bad = 1 }
        }
      }
    }
    END { exit((seen && !bad) ? 0 : 1) }
  ' "$log"
}

# --- Eligibility -----------------------------------------------------------

# mp_eligible <pr> <base> <repo-root>
# The whole policy, in one call. Prints a one-line reason (why it is or is not
# in the class) and returns 0 for ELIGIBLE, 1 for INELIGIBLE.
#
# <base> is the task's <issue>-<slug> stem; only its issue part is used, to key
# the state.log scan. <repo-root> is required because gh resolves its target
# repo from the working directory's git remotes — under launchd the tick shell's
# cwd is `/`, where every gh call fails. Each gh call therefore runs in a
# `( cd "$repo_root" && ... )` subshell, matching the merge path.
#
# NOTHING here reads the approval file. That is the point: the only inputs are
# the live PR (via gh) and the queue's own audit log.
mp_eligible() {
  local pr="$1" base="$2" repo_root="$3"

  case "$pr" in
    '' | *[!0-9]*)
      printf 'ineligible: no usable PR number (pr=%s)\n' "$pr"
      return 1
      ;;
  esac

  local issue="${base%%-*}"
  case "$issue" in
    '' | *[!0-9]*)
      printf 'ineligible: unparseable task base (base=%s)\n' "$base"
      return 1
      ;;
  esac

  # Changed paths, straight from GitHub.
  local paths gh_status=0
  paths=$(cd "$repo_root" && gh pr diff "$pr" --name-only 2>/dev/null) || gh_status=$?
  if [ "$gh_status" -ne 0 ]; then
    printf 'ineligible: gh pr diff failed (exit %s) — cannot classify the change\n' "$gh_status"
    return 1
  fi
  if [ -z "$paths" ]; then
    printf 'ineligible: gh reported no changed paths — cannot classify the change\n'
    return 1
  fi

  # Which class is this PR in? Every path must be in the SAME one. A path in no
  # class ends it immediately; so does the first path that disagrees with the
  # class its predecessors established. There is no "mostly docs" or "mostly
  # tests" — a mixed PR fails closed to the human gate.
  local path class='' path_class
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path_class=$(mp_class_of_path "$path")
    if [ -z "$path_class" ]; then
      printf 'ineligible: out-of-class path (%s)\n' "$path"
      return 1
    fi
    if [ -z "$class" ]; then
      class="$path_class"
    elif [ "$class" != "$path_class" ]; then
      printf 'ineligible: mixed classes — %s is %s-class but earlier paths are %s-class; no single cap applies\n' \
        "$path" "$path_class" "$class"
      return 1
    fi
  done <<<"$paths"

  if [ -z "$class" ]; then
    printf 'ineligible: no classifiable changed path — cannot classify the change\n'
    return 1
  fi

  local cap
  case "$class" in
    docs) cap="$MP_MAX_CHANGED_LINES" ;;
    tests) cap="$MP_TESTS_MAX_CHANGED_LINES" ;;
    *)
      printf 'ineligible: unknown class (%s)\n' "$class"
      return 1
      ;;
  esac

  # The raw patch, straight from GitHub. --name-only names a rename only by its
  # destination, so it cannot be the sole input: it is paired here with a scan of
  # the patch for the source side of every rename and copy. The two together
  # cannot hide a path.
  local patch
  gh_status=0
  patch=$(cd "$repo_root" && gh pr diff "$pr" 2>/dev/null) || gh_status=$?
  if [ "$gh_status" -ne 0 ]; then
    printf 'ineligible: gh pr diff (patch) failed (exit %s) — cannot see the source side of a rename\n' "$gh_status"
    return 1
  fi
  if [ -z "$patch" ]; then
    printf 'ineligible: gh returned an empty patch — cannot see the source side of a rename\n'
    return 1
  fi

  local moved
  moved=$(printf '%s\n' "$patch" | _mp_rename_paths)

  if [ "$class" = tests ]; then
    # The tests class bans renames and copies OUTRIGHT rather than classifying
    # both sides the way docs does. Moving a test file is a reorganization of the
    # suite, not an edit to a case: it costs 0 changed lines (so the cap sees
    # nothing) and it is exactly the operation that can quietly retire coverage
    # by moving it somewhere the runner does not look.
    if [ -n "$moved" ]; then
      printf 'ineligible: tests-only PRs may not rename or copy files (%s)\n' \
        "$(printf '%s' "$moved" | tr '\n' ' ')"
      return 1
    fi
    if printf '%s\n' "$patch" | _mp_patch_has_deletion; then
      printf 'ineligible: tests-only PRs may not delete files — removing a test shrinks the safety net without turning any check red\n'
      return 1
    fi
  else
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if ! mp_path_in_class "$path"; then
        printf 'ineligible: out-of-class rename/copy path (%s) — a moved path is not reported by --name-only\n' "$path"
        return 1
      fi
    done <<<"$moved"
  fi

  # Size, straight from GitHub.
  local total
  gh_status=0
  total=$(cd "$repo_root" && gh pr view "$pr" --json additions,deletions \
    --jq '(.additions // 0) + (.deletions // 0)' 2>/dev/null) || gh_status=$?
  if [ "$gh_status" -ne 0 ]; then
    printf 'ineligible: gh pr view failed (exit %s) — cannot size the change\n' "$gh_status"
    return 1
  fi
  case "$total" in
    '' | *[!0-9]*)
      printf 'ineligible: unparseable change size (%s)\n' "$total"
      return 1
      ;;
  esac
  if [ "$total" -gt "$cap" ]; then
    printf 'ineligible: %s changed lines exceeds the %s-line cap for the %s-only class\n' \
      "$total" "$cap" "$class"
    return 1
  fi

  # Chain history, from the queue's own audit log.
  if ! _mp_chain_clean "$issue" "$MA_ROOT/state.log"; then
    printf 'ineligible: chain not clean/first-pass for issue %s (a failed/blocked transition, a pass>1 cycle, or no recorded history)\n' "$issue"
    return 1
  fi

  # This string reaches state.log as `detail=<class>-only: ...` (loop-lib's
  # _ml_policy_pass), and `detail=` is how an auditor tells the two classes
  # apart: the `via=` token is auto-merge-policy for both, because it names the
  # authorization (the policy, not a human), not the class.
  printf '%s-only: %s changed lines, all paths in class, clean first-pass chain\n' "$class" "$total"
  return 0
}
