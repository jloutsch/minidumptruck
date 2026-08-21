# Porting the multi-agent loop system to another repo

This is the operator's guide to standing up the poll-based PM / Builder / Validator / Scribe
loop in a different repository. It assumes you have read `docs/multi-agent-autonomy.md` (the
design) at least once; this document is about what travels, what does not, and what will hurt
you if you copy it without thinking.

The port is **generated, not hand-copied**. Deploy it straight into the target repo:

```bash
./scripts/multi-agent/export-kit.sh ~/code/other-repo --deploy --label-prefix com.example.other-repo
```

`--deploy` writes the portable subset into the target repo (label prefix applied, merge policy
blanked, personas reduced to skeletons whose project gates are `<<PROJECT GATE: replace — ...>>`
placeholders) **and** does the mechanical setup that follows: it gitignores the queue, creates
the queue directories, and runs the deployed kit's own test suite inside the target so a broken
port is caught there and then. A red suite aborts the deploy. It finishes by printing the human
steps that remain, with real paths filled in.

What `--deploy` deliberately does **not** do is install or load a single launchd agent.
Activation stays a deliberate human act, from a human's own terminal. It refuses to deploy into
a directory that is not a git repository root, and it refuses to deploy into *this* repo — both
by path and by shared git directory, so a worktree of the source repo is refused too.

Without `--deploy` the same command is an **export**: it writes the kit into a directory and
stops, setting nothing up. That is the mode for a target you intend to publish or share rather
than run — an artifact repo, a tarball, a copy for someone else to deploy. Two rules for an
exported copy: it is generated content, so **regenerate it, never hand-edit it** (re-run the
export against a changed source repo), and if you later want to *run* it, deploy into the real
repo rather than moving the exported files across by hand.

Either way, the copy self-identifies. Every export and deploy writes `EXPORT-MANIFEST.md` at
the kit root recording the source repo, the source commit, the generation timestamp, the label
prefix, the mode, and a SHA-256 for every delivered file. To check a kit you found on a disk
somewhere against what was actually shipped, run this from the kit root:

```bash
grep -E '^[0-9a-f]{64}  ' EXPORT-MANIFEST.md | shasum -a 256 -c -
```

Anything but `OK` on every line means the copy has been edited since it was generated. The
manifest does not list itself (it cannot contain its own hash), and if the source repo was dirty
at generation time the manifest says so, because then the commit hash does not fully describe
the bytes you were given.

The one-sentence version of everything below: **the machinery ports cleanly; the gates do
not, and a persona with the wrong gates fails silently rather than loudly.**

---

## 1. Prerequisites

- **macOS.** The polling engine is launchd LaunchAgents. There is no Linux/systemd path
  today. The Mac must be **awake and logged in** for agents to fire — these are LaunchAgents
  (per-user session), not LaunchDaemons.
- **`claude` CLI, authenticated.** Each worker is a headless `claude -p` invocation
  (`loop-lib.sh` → `_ml_run_worker`). Authenticate it interactively once, as the same user
  the agents run as.
- **`gh` CLI, authenticated.** The Scribe lane pushes, opens PRs, and reads checks through
  `gh`. Without it, the Builder and Validator lanes still work; the Scribe lane does not.
- **The repo is on GitHub**, with a remote named `origin`.
- **A GitHub free / private repo has no branch protection.** Say this out loud, because the
  system's safety story depends on it: on a free plan, nothing server-side stops a push to
  your default branch. The protection is entirely local and mechanical — the push guard
  (`git-push-guard.sh`, which refuses any push resolving to main) plus the human merge gate
  (the loop merges only a `.pending.md` file that a **human** renamed to `.approved.md`; no
  loop or worker code path writes `.approved.md`). If you port those two pieces and weaken
  either, you have an agent with unreviewed write access to your default branch.

---

## 2. Tier 1 — copy verbatim

These files carry nothing about the source repo. Every one of them derives its paths from
its own location on disk (`BASH_SOURCE` → `SCRIPT_DIR` → repo root), so they work from any
checkout, any worktree, and under launchd's bare environment without edits:

| File | What it is |
|------|------------|
| `scripts/multi-agent/queue.sh` | The state machine: atomic claim, state-suffix transitions, frontmatter round-trip, brief lint |
| `scripts/multi-agent/builder-loop.sh` | Builder tick |
| `scripts/multi-agent/validator-loop.sh` | Validator tick |
| `scripts/multi-agent/scribe-loop.sh` | Scribe tick (worker pass + approval pass) |
| `scripts/multi-agent/reaper.sh` | Requeues stale claims, dead-letters after retries |
| `scripts/multi-agent/git-push-guard.sh` | The Scribe's only sanctioned push path |
| `docs/brief-template.md` | The brief contract the queue lint enforces |
| `docs/multi-agent-autonomy.md` | The design doc (reference; its examples are from the source repo) |

`export-kit.sh` copies these unchanged.

**One caveat inside Tier 1, and it is load-bearing:** the push guard's idea of a protected
branch is the literal string `main` (`loop-lib.sh` → `_ml_token_is_main`). If your default
branch is `master`, `develop`, or anything else, **the guard protects nothing** — it will
happily let an agent push to your default branch while reporting that it refuses pushes to
main. If your default branch is not named `main`, change that resolver before you enable a
single loop.

---

## 3. Tier 2 — parametrize

### 3.1 The launchd label prefix (mandatory for a second repo on one Mac)

launchd labels are per-**user**, not per-repo. Two checkouts of this system installed under
the same prefix write the same four plists, and the survivor polls the loser's queue. So a
second repo on the same Mac must have its own prefix:

```bash
./scripts/multi-agent/install-loops.sh   --label-prefix com.example.other-repo
./scripts/multi-agent/uninstall-loops.sh --label-prefix com.example.other-repo
```

Without the flag, behavior is unchanged (the default prefix stays whatever
`MA_DEFAULT_LABEL_PREFIX` says at the top of each installer). The prefix must be
reverse-DNS-shaped — two or more dot-separated segments of letters, digits and hyphens — and
anything else is refused loudly, because the prefix is spliced into both a launchd `Label`
and a plist **filename**.

`export-kit.sh --label-prefix` rewrites the anchored `MA_DEFAULT_LABEL_PREFIX` line in
`install-loops.sh`, `uninstall-loops.sh` **and** `test-queue.sh` together, so the installers
and the suite that checks them cannot drift apart. **Uninstall with the same prefix you
installed with** — the prefix is the only thing that names the agents, so the wrong one
removes nothing and reports success.

### 3.2 The merge policy — a founder decision, never a copy

`merge-policy.sh` defines the auto-approve classes: the narrow sets of PRs the loop may merge
with **no human in the loop**. In the source repo there are two — docs-only changes and
tests-only changes, each under its own line cap, with the agent control surfaces (personas,
brief template) and the security test suite carved out.

That is one founder's authorization about one repo. **It does not transfer, and the kit does
not copy it.** What `export-kit.sh` emits instead is a fail-closed placeholder: **every**
class's allowed-path list is a sentinel that matches nothing and **every** cap is 0, so
nothing is ever in class and **every PR keeps its human merge gate**. That is a correct,
safe, permanent state — you can leave it exactly as it is and the system works, just with a
human clicking approve on every merge.

If you do want an auto-approve class, decide it for *your* repo and write it into
`merge-policy.sh`, which is the enforced source of truth. Two properties must survive any
edit you make, and both are explained in the file's own header: the decision inputs are
**recomputed** from the live PR (a worker cannot mint its own approval by writing a claim in
a file), and every uncertainty **fails closed**.

While a class is unconfigured, `test-queue.sh` skips that class's tests — there is no class
to assert — and prints a SKIP line saying so. That is expected in a fresh port, not a broken
suite. The two classes are gated separately, so configuring one and not the other runs the
half you have. The property that holds either way (an unconfigured class merges nothing) is
asserted unconditionally.

**The exclusion lists are kept, not blanked, and you should read them.** An exclusion can
only ever shrink a class, never widen one, so a stale one is harmless — the worst it can do
is keep a human gate you did not need. Two are pre-filled for the docs class and you should
keep them: `docs/personas/**` and `docs/brief-template.md`. Those are not project policy —
they are this system's own control surfaces. If an agent can auto-merge a change to the
prompts that steer the agents, the gate is decorative. The tests-class exclusions name the
source repo's paths (`server/tests/security/**` and its shared fixtures), so they will not
match your tree. Treat them as a **worked example** rather than a description: the point they
make is that a security suite is made of ordinary-looking test files, and it takes a
deliberate carve-out to keep the tests that *are* the gate from merging themselves.

**If you add a class of your own, teach `_ek_write_policy` to blank it.** The generator in
`export-kit.sh` neutralizes each class by matching its exact variable names
(`MP_ALLOWED_PATHS`, `MP_TESTS_ALLOWED_PATHS`, and the caps). A class it does not know about
flows through **live** — your authorization about your repo, auto-merging in whatever repo
you export to next, under a banner promising the opposite. So the generator does not take
your word for it: it counts the classes declared in `merge-policy.sh`, counts the ones it
actually blanked, and refuses to export unless every class it found came out blanked. A class
it has not been taught about fails loudly at export time rather than quietly at merge time.

### 3.3 `loop-lib.sh` and `new-worktree.sh` — copied, but NOT portable as-is

The kit copies both, because nothing runs without them. They are the two files that still
hold source-repo assumptions, and they are where a careless port breaks. Fix these before you
load anything:

| Where | What it assumes | What to do |
|-------|-----------------|------------|
| `loop-lib.sh` → `_ml_bootstrap_worktree` | `npm install && npm run db:generate` | Replace with your repo's bootstrap. If a fresh checkout of your repo needs no bootstrap, make it a no-op |
| `loop-lib.sh` → `_ml_ensure_worktree` | Creates worktrees via `./scripts/new-worktree.sh`, branching from `main` | Fix the base-branch name if yours differs |
| `loop-lib.sh` → `_ml_token_is_main` | The protected branch is literally `main` | See the Tier-1 caveat above |
| `scripts/new-worktree.sh` | `npx husky` installs the pre-push hook | Rewrite for your hook system, or reduce it to `git worktree add` if you have no hooks |
| `loop-lib.sh` → `_ml_open_pending` | Opens the pending approval file in TextMate | Best-effort and already degrades safely if TextMate is absent — change the editor or drop it |

The `claude -p` invocation in `_ml_run_worker`, including the `--allowedTools` /
`--disallowedTools` fencing that denies Builder and Validator any remote command and denies
the Scribe `gh pr merge`, ports as-is. Do not loosen it: that fencing is what makes the
personas' no-remotes rules real instead of advisory.

---

## 4. Tier 3 — rewrite the personas

**This is the step that deserves the hour.** Everything above either works or fails loudly. A
persona with the wrong gates does neither: it produces confident, plausible, wrong work, and
the loop dutifully carries it downstream.

Each persona file is two things braided together:

**The invariant CONTRACT — keep it verbatim.** It is what makes the loop safe in any repo:

- The claimed-file contract: the claimed file is the only briefing; the worker never renames
  its own file; outcome is signaled purely by exit code.
- Stop-on-breakage: findings appended to the claimed file **and** a nonzero exit — both,
  always. Same for a stale premise (the work is already done → stop, do not report it as
  yours).
- Absolute-path discipline: handoffs are written under the **parent** checkout's
  `multi-agent/`, never into the worktree.
- Handoff naming: the exact downstream file each persona must write, with complete
  frontmatter. The loop verifies this postcondition — a persona that writes the wrong path
  fails its task.
- Remote fencing: Builder and Validator never touch a remote. Scribe is the only persona
  allowed remote operations, and even then: pushes only through the guard, and it **never**
  merges.
- The `pm_approved_pass` prohibition: no worker may ever write that field. It is the only
  mechanism that sanctions a pass beyond the max-pass ceiling, and it is a human's to write.
  A worker that could emit it could authorize its own escalation past the anti-runaway cap.
- Read-only-the-claimed-file: workers never read other tasks' notes. That is how a worker
  ends up following a stale process from someone else's task.

**The PROJECT GATES — substitute every one.** In the exported skeletons these are already
replaced with `<<PROJECT GATE: replace — ...>>` placeholders, generated from markers in the
live persona files. Each hint tells you what belongs there:

| Persona | Gate |
|---------|------|
| Builder | Fresh-worktree bootstrap (the exact commands, in order, and what breaks if one is skipped) |
| Builder | The static-analysis gate that must be clean before handoff (type-check / lint / build) |
| Builder | Package-manager policy, if any |
| Builder | Test conventions — what a worker must write and run to prove a change |
| Validator | Review tooling to invoke at pass start |
| Validator | When to run the full suite instead of the targeted tests |
| Validator | The recurring findings your reviewers actually raise |
| Validator | The same bootstrap gate as the Builder — copy it verbatim from there |
| Scribe | PR conventions: issue-linking rules, body format, required sections |
| Scribe | Your CI checks, and which failures are known non-blockers |

Two of these are worth extra care:

- **The bootstrap gate must be identical in the Builder and Validator personas.** If they
  disagree, the Validator re-runs a different environment than the Builder built in, and you
  get failures that reproduce nowhere.
- **Start the "recurring findings" and "known non-blockers" lists EMPTY.** Those are earned
  from your own review cycles. Copying another repo's list teaches your Validator to hunt for
  patterns your code does not have while ignoring the ones it does.

Search the filled personas for any remaining `<<PROJECT GATE` before you use them. A contract
rule can also name a source-repo situation directly rather than through a placeholder — the
Scribe's "never push to main" rule cites this repo's *free-plan, no branch protection* setup as
the reason the rule exists. Swap that specific for your own, keep the rule.

---

## 5. Setup checklist

Run in order. Do not skip ahead to `launchctl load`.

### Step 0 — deploy (the machine's half)

```bash
./scripts/multi-agent/export-kit.sh /path/to/target-repo --deploy --label-prefix com.example.your-repo
```

That one command does everything that can be done mechanically, and nothing that cannot:

- writes the kit, with the label prefix applied to the installers **and** the test suite together;
- appends an **anchored** `/multi-agent/` rule to the target's `.gitignore` if git does not already
  ignore the queue (anchored so it does not also swallow your tracked `scripts/multi-agent/` — an
  unanchored `multi-agent/` matches that directory name at every depth, so it would ignore the kit
  itself, and you would commit a repo with no loop system in it). Before it writes anything, deploy
  asks git whether the target already ignores `scripts/multi-agent/`, and **refuses if it does** —
  naming the rule. That is the case where a repo already carries a bare `multi-agent/` line: fix it
  by anchoring the rule you have (`/multi-agent/`), then deploy again. Deploy will not rewrite that
  line for you — it is yours, and a rule that silently changes meaning is worse than one that stops
  you. After setup it re-checks both directions against git: the queue must be ignored, the kit must
  be committable, or the deploy aborts as unverified;
- creates `multi-agent/{builder-tasks,validator-notes,scribe-notes,merge-approvals,logs,archive}`;
- runs the **deployed** kit's own `test-queue.sh` inside the target and **aborts loudly if it is
  red**, leaving the log at `multi-agent/logs/deploy-selftest.log`. A SKIP line for the
  auto-approve-class tests and one for the export-kit tests are both expected in a fresh port
  (there is no class yet, and the generator stays with the source repo);
- writes `EXPORT-MANIFEST.md` — the provenance record described at the top of this guide.

It refuses a target that is not a git repository **root**, it refuses this repo (by path *and* by
shared git directory, so a worktree of it is refused too), it refuses a repo whose existing ignore
rules would swallow the kit, and it refuses a repo the kit is already deployed into unless you pass
`--force`. Re-deploying with `--force` overwrites the personas you
filled in and blanks your merge policy back to the placeholder — that is what the refusal is
protecting.

Also add `.worktrees/` to the target's `.gitignore` if the loops will create worktrees there. The
deploy does not do this for you: where your worktrees live is your call, not the kit's.

### The human half — none of it can be automated

1. **Fill every placeholder.** The personas (Tier 3), then the two files in §3.3, then decide
   whether you want a merge policy at all (§3.2 — "no" is a valid, safe answer).
   ```bash
   grep -rn '<<PROJECT GATE' docs/personas/    # must come back empty
   ```

2. **Re-run the suite after you edit anything.** The deploy ran it against the kit as generated;
   you have since changed the personas, `loop-lib.sh` and possibly the policy.
   ```bash
   bash scripts/multi-agent/test-queue.sh    # must end with: ALL TESTS PASSED
   ```
   It runs entirely in a temp sandbox and never touches your real queue or your real
   `~/Library/LaunchAgents`. Anything red here means the loop would misbehave against your
   repo — fix it now, while nothing is running.

3. **Install from an interactive terminal.** This matters: launchd agents run with a minimal
   `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) where `git`, `node`, `npm` and `claude` do not
   resolve. `install-loops.sh` bakes **the installing shell's PATH** into each plist, so it
   must be run from a terminal whose PATH is the real one — not from a stripped environment,
   and not from the deploy (which is why the deploy does not run it for you).
   ```bash
   ./scripts/multi-agent/install-loops.sh --label-prefix com.example.your-repo
   ```
   It writes the four plists and **never loads them**. Nothing is running yet.

4. **Load the agents — the deliberate, manual step.** The installer prints the exact commands.
   ```bash
   launchctl load ~/Library/LaunchAgents/com.example.your-repo.builder-loop.plist
   # ...and validator-loop, scribe-loop, reaper
   ```
   To stop: `launchctl unload <plist>` pauses only until your next login (the plists reload at
   login). To stop persistently, use `launchctl unload -w <plist>` or run
   `uninstall-loops.sh --label-prefix <yours>`.

5. **Supervise the first task, end to end.** Write one small, real brief — something whose
   correct outcome you can recognize on sight — drop it in as `builder-tasks/<issue>-<slug>.ready.md`,
   and then actually watch it: the state file moving `.ready` → `.claimed` → `.done`, the
   handoff appearing in the next inbox, `multi-agent/logs/` and `multi-agent/state.log`.
   The first run is where you find out that your bootstrap command was wrong, or your gate
   command exits 0 on failure. Find that out on a task you chose, not on one you cared about.

### If you exported instead of deploying

An export sets nothing up: no queue ignore rule, no queue directories, no verification run in the
target. If you are holding an exported copy and want to run it, deploy into the real repo. If you
must proceed from the export by hand, you owe the target the three things the deploy would have
done — the anchored `/multi-agent/` ignore rule, the six queue directories, and a green
`test-queue.sh` **run in the target** — before step 3 above.

---

## 6. Constraints that travel with the system

- **One lane per repo, one plan quota across all repos.** Each repo's loops serialize their
  own work (one claimed task at a time). But every worker in every repo is a `claude -p`
  invocation billed to the same subscription, so a second repo does not get a second budget.
  In practice this means more quota-deferred ticks, not corruption: the loops already detect a
  quota failure, back off, and resume. Expect the machinery to cope and the throughput to
  drop.
- **The Mac must be awake and logged in.** LaunchAgents do not fire on a sleeping or
  logged-out machine. A missed tick costs at most one interval — the next tick resumes from
  the file's on-disk state — but a closed laptop makes no progress at all.
- **The background-environment problem is the recurring scar.** Nearly every "the loop did
  nothing / the loop half-worked" incident traces to the agent's environment differing from
  your terminal's: the minimal `PATH` (why the installer bakes yours in), a `claude` or `gh`
  credential that is not readable from a background session, and `MA_ROOT` resolving to the
  wrong `multi-agent/` when a script is sourced by a relative path from a worktree. The
  design doc's launchd and worker sections (`docs/multi-agent-autonomy.md`, §5–§6) record why
  each of those defenses exists. Keep them. When something silently does nothing, suspect the
  environment before the logic, and read `multi-agent/logs/launchd-*.err.log` first.

---

## 7. What NOT to port

- **`multi-agent/` contents.** The queue is per-repo runtime state: briefs, notes, approvals,
  logs, `state.log`. Copying another repo's queue means claiming another repo's tasks. The kit
  exports none of it, and `test-queue.sh` asserts that.
- **The merge policy's values.** Covered in §3.2. The class is a founder authorization about a
  specific repo; the kit ships a fail-closed blank on purpose.
- **The source repo's brief archive** and its `validator-notes` / `scribe-notes` history.
  Those are that project's scratch, and reading them is precisely what the personas'
  read-only-the-claimed-file rule exists to prevent.
- **The recurring-findings and known-non-blocker lists** inside the personas (§4). Earn your
  own.
