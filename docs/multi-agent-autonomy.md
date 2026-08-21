# Multi-Agent Autonomy — Poll-Based Handoff Loop

Status: as-built for Phase 3 (2026-07-08) — see #808, #835
Scope: Builder, Validator, and Scribe run autonomously off handoff files via launchd polling loops (installed unloaded; enabling is a manual step). Scribe is the first persona authorized for remote operations, and is mechanically fenced: it pushes only through a main-refusing push guard, opens and monitors the PR, and writes a merge-approval pending file — but never merges. A merge happens only after a HUMAN renames the pending file `.pending.md` -> `.approved.md`, and is then performed by the loop after re-verifying the PR and its checks at current head. PM stays human.

## 1. Goal

Before this design, the whole PM / Builder / Validator / Scribe flow was driven by a human moving work between personas. As of Phases 1+2, the PM and Scribe stages remain human-driven, while Builder and Validator advance work autonomously off handoff files. Each persona communicates through files in known directories:

- `multi-agent/builder-tasks/<issue>-<slug>.md` — brief for Builder
- `multi-agent/validator-notes/<issue>-<slug>[-passN].md` — Validator findings
- `multi-agent/scribe-notes/<issue>-<slug>.md` — Scribe orchestration spec

These directories are local-only and gitignored (per PR #435). They are now **inbox queues** with a small state machine, so a persona's loop can poll for new work and advance it without a human relaying files between personas (Builder and Validator today; Scribe deferred — see #808).

The chosen engine is **scheduled tasks** (recurring poll every few minutes), not a long-lived watcher daemon. Rationale: no process lifecycle to own, crash-resilient for free (the next tick resumes), and trivial to pause by disabling the task. The tradeoff — up to one poll interval of latency — is acceptable for this workflow.

## 2. Core idea: the handoff files are the queue

The handoff file a persona writes is simultaneously that persona's output and the trigger for the next persona. A worker polls its inbox, atomically claims a ready file, does the work, and writes the downstream persona's handoff — which the downstream worker's next poll picks up. No separate message bus is needed; the filesystem is the queue.

## 3. State model

State lives entirely in the filename suffix — `.ready.md`, `.claimed.md`, `.done.md`, `.failed.md`, `.blocked.md`. Frontmatter carries metadata only, not state:

```yaml
---
issue: 634
slug: totp-backup-codes
stage: builder            # builder | validator | scribe
pass: 1                   # increments each validator round-trip
retries: 0                # claim attempts, for dead-lettering
owner: null               # worker/run id, set on claim
updated: 2026-07-05T14:03:00Z
---
```

An earlier draft of this design also carried a `status:` field in frontmatter, duplicating what the filename suffix already says. That was dropped: recording the same state in two places lets them drift out of sync (a crash between the rename and the frontmatter write leaves them disagreeing), so the filename suffix is the single source of truth and nothing else records state.

Lifecycle (a ring with fail-back edges):

```
PM (human)
   │  writes builder-tasks/<issue>-<slug>.ready.md
   ▼
BUILDER ──► validator-notes/<issue>-<slug>.ready.md
   ▲                                   │
   │ (validator fail: pass++)          ▼
   └────────────────────────────── VALIDATOR
                                       │ (pass)
                                       ▼
                            scribe-notes/<issue>-<slug>.ready.md
                                       │
                                       ▼
                    SCRIBE (human, deferred automation — see #808) ──► push / PR / merge (gated)
                                       │
                                       └─ (PR review comments) ──► back to BUILDER
```

As of Phase 3 the SCRIBE stage IS a poll loop (scribe-loop, 5 min), with two halves per tick: it advances any human-approved merges (the merge-approval gate, §7) and runs the standard claim/worker tick over `scribe-notes/*.ready.md`. The worker pushes, opens/monitors the PR, and writes a merge-approval pending file — it does not merge (§7).

## 4. Concurrency: claim before work

The single rule that makes polling safe is **atomic claiming** so two ticks never grab the same file. Claim by hardlinking, not by `mv -n`:

```bash
# Only one racer wins the hardlink; losers skip and move on.
claimed="${f%.ready.md}.claimed.md"
ln "$f" "$claimed" 2>/dev/null || continue
rm -f -- "$f"
```

`mv -n` was the first draft's claim mechanism and was dropped: both BSD and GNU `mv -n` exit 0 when they skip an existing target, so a lost race is silent — a second worker has no way to tell it lost. `ln` fails if the target already exists, so the loser's `ln` call fails and only the winner proceeds to remove the `.ready.md` original. This relies on `multi-agent/` living on a single filesystem (hardlinks don't cross filesystem boundaries), which holds for this project.

On claim: stamp `owner` and `updated`. On success: write the downstream `*.ready.md` and rename this file to `*.done.md`. On error: rename to `*.failed.md` with the reason appended to the body.

**Reaper.** A file stuck in `*.claimed.md` past a per-stage timeout (a worker crashed mid-task) is requeued to `*.ready.md` with `retries++`. Timeouts as built: 90 min for builder and validator claims, 30 min for scribe claims. After 3 retries it is moved to `*.failed.md` (dead-letter) and a human is notified (`ma_notify`) rather than looped forever.

## 5. The polling engine — launchd LaunchAgents

As built, the poll loops are four launchd LaunchAgents, written (but not loaded) by `scripts/multi-agent/install-loops.sh`: builder-loop, validator-loop, and scribe-loop each fire every 300s (5 min); the reaper fires every 900s (15 min). `install-loops.sh` writes each plist with `RunAtLoad` false and never calls `launchctl load` itself — enabling the agents is a deliberate, manual step a founder runs afterward (`launchctl load ~/Library/LaunchAgents/com.birthday-assist.<name>.plist`). Plist labels: `com.birthday-assist.builder-loop`, `com.birthday-assist.validator-loop`, `com.birthday-assist.scribe-loop`, `com.birthday-assist.reaper`.

Each builder/validator tick:

1. Check the global lane (§10): if any inbox has a `*.claimed.md` file anywhere, exit quietly.
2. Scan the persona's inbox for `*.ready.md`, oldest by mtime first. If none, exit quietly.
3. (Validator only) enforce the max-pass gate: `pass >= 3` moves the file straight to `*.blocked.md` and notifies a human, without claiming it.
4. Atomically claim one (section 4).
5. Ensure/bootstrap the issue's worktree and run the persona worker (section 6).
6. Write the downstream handoff, mark this file `done`/`failed`, exit.

Inbox-to-task mapping:

| Task | Watches | Produces |
|------|---------|----------|
| builder-loop | `multi-agent/builder-tasks/*.ready.md` | `validator-notes/*.ready.md` |
| validator-loop | `multi-agent/validator-notes/*.ready.md` | `scribe-notes/*.ready.md` (pass) or `builder-tasks/*.ready.md` (fail, pass++), or blocks at pass>=3 |
| scribe-loop | `multi-agent/scribe-notes/*.ready.md` (worker) + `multi-agent/merge-approvals/*.approved.md` (merge) | `merge-approvals/*.pending.md` (worker); a squash-merge + branch delete + `.merged.md` (on a human-approved file) |
| reaper | all three inboxes, including `scribe-notes` (30 min timeout) | requeues stale `*.claimed.md`, dead-letters after 3 retries |

Because each tick is short-lived and stateless, a missed or crashed run costs at most one interval — the next tick resumes from the file's on-disk status.

## 6. The worker: headless Claude with a persona prompt

Each persona is a non-interactive `claude -p` invocation, pinned to that role and the specific claimed file, run **on the host** — the container convention cited in the first draft doesn't exist in this project, and Phases 1+2 don't introduce one. Scan and claim (§4-§5) are plain shell; a Claude worker process is only started after a claim has already succeeded. Builder and Validator each run from a fresh or reused git worktree.

```bash
# Fresh worktree via the wrapper so husky pre-push hooks fire (CLAUDE.md #622).
./scripts/new-worktree.sh ".worktrees/${issue}" -b "auto/${issue}-${slug}" main
cd ".worktrees/${issue}"

# HARD-REQUIRED bootstrap gate before any type-check (CLAUDE.md fresh-worktree bootstrap).
npm install
npm run db:generate     # populates node_modules/.prisma/client; without it type-check fails TS2305

prompt="$(cat "${repo_root}/docs/personas/${persona}.md")

CLAIMED FILE: ${claimed_file}
REPO ROOT: ${repo_root}"

claude -p "$prompt" --allowedTools "Read,Edit,Write,Bash,Grep,Glob"
```

The prompt is the full contents of `docs/personas/builder.md` or `docs/personas/validator.md`, followed by the claimed-file path and repo root — there is no inline prompt string. Note there is no `--dangerously-skip-permissions`: the worker runs under the ordinary permission model, constrained to the `--allowedTools` list above. Wrap the invocation so a nonzero exit writes `*.failed.md` rather than silently dropping the task. Note the CLAUDE.md prohibition: `npm run db:generate` here is the **initial bootstrap step** (correct and required), not self-remediation at a blocked gate. If a worker hits a blocked pre-push gate on `TS2305` errors, the correct response is to fail back for a human, not to re-run `db:generate` mid-gate.

Persona prompts differ by role:

- **Builder** — implement brief, run type-check + tests, write validator handoff. Never renames its own claimed file; signals outcome purely via exit code and, on failure, findings appended to the claimed file's body.
- **Validator** — check out Builder's branch, run the full gate (type-check both server+client, tests, targeted E2E where enabled), write findings to `validator-notes/<issue>-<slug>-pass<N>.md` on every pass. On clear, emit a scribe handoff (a signal for a human Scribe — see §7, deferred automation #808); on fail, emit a builder handoff with `pass++` and quoted findings.
- **Scribe** (as of Phase 3) — push the branch (only through `git-push-guard.sh`, which refuses main in any spelling), open and monitor the PR, and write `merge-approvals/<issue>-<slug>.pending.md`. It NEVER merges. The scribe worker runs under a persona-specific tool policy: unlike Builder/Validator it is allowed `gh` and pushes-via-guard, but is denied direct `git push` (forcing every push through the guard) and denied `gh pr merge` outright (a merge is the loop's job, §7). Its persona is `docs/personas/scribe.md`. See `docs/personas/scribe.md` for the full disciplines (PR-body umbrella-label check, no-closing-keywords-when-PM-closes, no parent pull, never write `pm_approved_pass`).

## 7. Human gates and loop termination

Two deliberate stops keep the loop from running away:

1. **PM-in is human.** Briefs enter `builder-tasks/` by a person (or a separate, explicitly-invoked PM step). The autonomous loop never authors its own work.
2. **Scribe merge is human-gated (Phase 3, as-built).** The scribe worker prepares the branch, opens the PR, and monitors checks autonomously, then writes `merge-approvals/<issue>-<slug>.pending.md` — and stops. A merge requires a HUMAN to review that file and rename it `.pending.md` -> `.approved.md`. Only that suffix authorizes a merge; **no loop or worker code path ever writes `.approved.md`** (grep the tree — the suffix appears only on the read side of `ml_process_approvals`), so the loop can never authorize its own merge. On the next scribe-loop tick, `ml_process_approvals` picks up the `.approved.md` file, re-verifies at current head that (a) the PR's head branch is still the expected `auto/<issue>-<slug>` and (b) `gh pr checks` is green, then squash-merges, posts an audit comment, deletes the remote branch, removes the worktree, and renames the approval `.merged.md`. A red or mismatched re-verification leaves the `.approved.md` intact and notifies a human; anything other than `.approved.md` (a `.rejected.md`, a hand-edit, a still-`.pending.md`) is left untouched with a low-frequency reminder.

   **Mechanical main-protection (the free-plan answer).** The repo is private on the GitHub free plan, so there is no branch protection to lean on — protection is mechanical in these scripts. Three layers: (a) the scribe worker is denied direct `git push` and can only push through `scripts/multi-agent/git-push-guard.sh`, which calls `ml_guarded_push`; that refuses any push resolving to main in any spelling (`main`, `heads/main`, `refs/heads/main`, `HEAD:main`, `:main`, `+main`, force, and a bare push while HEAD is main) via the pure resolver `_ml_ref_targets_main`, recording a per-task violation marker and a LOUD notification without contacting the remote; (b) if a violation marker is present at postcondition time, the loop fails the task rather than recording success; (c) merges happen exclusively through `gh pr merge`, gated on the human-renamed approval file. Every remote action (push, pr-open, merge) is logged to `state.log` via `q_log_remote` (`reason=push|pr-open|merge`), so `state.log` is a complete remote-ops audit trail in the absence of server-side branch-protection records.

Builder and Validator cycle fully autonomously, including the Validator→Builder fail-back loop, capped by a **max-pass counter of 3**. validator-loop enforces this before claiming a file: at `pass >= 3` the file is moved straight to `*.blocked.md` (state lives in the filename suffix, not a `status:` field — see §3) and a human is notified via `ma_notify`, instead of being claimed and looping again. Pass-counter convention: PM briefs start at `pass: 1`; validator-loop blocks at `pass >= 3`, i.e. at most two autonomous fail-back rounds per issue before a human is pulled in.

## 8. Observability and audit

As built, every state transition (`q_log` in `scripts/multi-agent/queue.sh`) appends one line to `multi-agent/state.log`, in the format:

```
2026-07-05T14:03:00Z issue=634 stage=builder ready->claimed owner=builder-loop-12345 pass=0
```

When one of those lines (or a silent queue) does not mean what you expect, [`docs/multi-agent-troubleshooting.md`](./multi-agent-troubleshooting.md) is the symptom-indexed troubleshooting guide: grep the exact error or log text you are looking at and it gives the cause, the remedy commands, and the ticket it was first seen in.

This gives a live "where is issue 634 right now" view without grepping inboxes, and a replayable audit trail. The persistent, authoritative audit for a merged PR still lives where CLAUDE.md specifies — Validator-quoted findings in commit messages and the Scribe-posted PR audit comment; `state.log` is operational scratch and is gitignored (the `.gitignore` pattern is anchored to `/multi-agent/` at the repo root, so it excludes the runtime directory without touching the tracked `scripts/multi-agent/` scripts).

## 9. Summary

Filename-suffix state (no `status:` field) as inbox queues + atomic hardlink claiming + three active launchd poll loops (builder, validator, scribe) plus a reaper + headless per-persona Claude workers on the host (no container) + human gates at PM-in and at Scribe merge-approval (a human renames `.pending.md` -> `.approved.md`; the loop merges only after re-verifying the PR at current head). Main is protected mechanically (no branch protection on the free plan): the scribe worker pushes only through a main-refusing guard, and the loop fails any task that attempted a main-push. Poll interval is 5 min for builder/validator/scribe, 15 min for the reaper. No long-lived daemon, no external queue, and every failure mode resolves to either an automatic retry, a dead-letter, or a human escalation.

## 10. Open questions

Resolved in Phases 1+2:

- **Poll interval:** 5 min (300s) for builder-loop and validator-loop; 15 min (900s) for the reaper.
- **Per-stage reaper timeouts:** yes — 90 min for builder and validator claims, 30 min for scribe claims (`MA_REAP_BUILDER_MIN` / `MA_REAP_VALIDATOR_MIN` / `MA_REAP_SCRIBE_MIN` in `reaper.sh`).
- **Single lane:** yes, but a single **global** lane, not per-issue. `_ml_lane_busy` in `loop-lib.sh` checks all three inboxes for any `*.claimed.md` file; if one exists anywhere, both builder-loop and validator-loop skip their tick. That means exactly one issue is in flight, total, across the whole queue — stricter than the original framing of "avoid two issues touching the same files concurrently."

Still open:

- Where do PR review comments re-enter — always Builder, or Validator first for re-triage? The Scribe loop now exists and monitors the PR, but a mechanical route back from post-open review comments into a fresh builder brief is not yet automated: today a human reads the PR and, if a fix is needed, files the follow-up brief. Automating that hand-off is the remaining Phase-3+ question.
