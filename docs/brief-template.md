# PM builder-brief template

The standard shape for a PM-authored implementation brief handed to Builder
through `multi-agent/builder-tasks/<issue>-<slug>.ready.md`.

The four bold-lined markers below — the **Premise verification** line, and the
`## Gates`, `## Authorizations roster`, and `## Handoff` sections — are enforced
at claim time by the enqueue lint in `scripts/multi-agent/queue.sh`. The lint
gates **original first-pass PM briefs only**: a `stage: builder` ready file with
`pass: 1` and no `origin:` field that is missing any marker is parked as
`.blocked.md` with the missing section named. Two classes are exempt because
they trace to an already-linted parent brief — pass `> 1` re-scope/fail-back
briefs, and any brief carrying `origin:`. The lint checks presence only;
semantic quality of each section stays a PM/Validator discipline.

Copy the block below, fill it in, delete the parenthetical guidance.

---

## This repo in one block

Everything a brief asserts about the toolchain should match this. Re-measure
rather than trusting it if it looks stale.

| | |
|---|---|
| Build | `cd App && swift build` — one command, ~12s cold, no install, no codegen |
| Manifest | `App/Package.swift` — **all commands run from `App/`**, not the repo root |
| Tests | `cd App && swift test` — Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), not XCTest. **Both platforms**; see the Linux leg under `## Gates`. |
| Suite baseline | **macOS 865 tests in 118 suites, 0 skipped** / **Linux 863** @ `b3a4c57`, measured cold on both, 2026-08-18. The −2 is the two Darwin-only `@Test`s (`#if canImport(os)`, `#if canImport(Security)`) — expected, not a regression. |
| Warning baseline | **2 pre-existing**, both `result of 'try?' is unused` — `Services/SymbolicationService.swift:127`, `Services/SymbolServer.swift:148`. They emit **10 raw lines** before `sort -u`. |
| Linter | none (no SwiftLint/SwiftFormat). The compiler is the gate. |
| Workflow lint | `actionlint` 1.7.12, mandatory on any `.github/workflows/*.yml` change |
| Package manager | SPM only. No npm, no `package.json`, no Node. |
| Database | none. There is no integration-gate class in this repo. |
| Merges | squash — pre-merge SHAs do not survive |
| Test fixtures | `App/TestData/*.dmp` **are tracked** (`.gitignore` ignores `*.dmp`, then re-includes them) |

## Frontmatter

```markdown
---
issue: <number>            # the anchor GitHub issue
slug: <kebab-case-slug>    # short handle; combines with issue for the filename
stage: builder
pass: 1                    # bump on each re-scope/fail-back pass
retries: 0
owner: null                # stamped by the queue on claim
updated: <UTC ISO-8601, e.g. 2026-08-13T00:00:00Z>
---
```

Optional frontmatter fields:

- `pm_approved_pass: <N>` — the PM's sole mechanism to sanction a claim past the
  max-pass ceiling (pass ≥ 3). Only a human-authored brief may carry it, and it
  must equal the file's own `pass`. No worker or loop code path writes it. Omit
  it on ordinary briefs.
- `origin: <source>` — marks a worker- or scribe-authored fail-back (e.g.
  `origin: scribe-post-review-fix`). A brief carrying `origin:` is **exempt**
  from the enqueue lint, because it traces to an already-linted parent brief.
  Do not add `origin:` to an original PM brief for new work.

## The `Keyword:` line

Every brief carries exactly one, and it is an instruction, not a menu —
`Keyword: Closes #N` or `Keyword: Refs #N`, never "your call". If the work
leaves any part of the issue open, it is `Refs`.

**Never put a closing keyword on an umbrella/tracker issue.** #70 (Linux
compatibility) and #71 (installers) are multi-phase trackers with many PRs each;
a `Closes #70` on a phase-1 PR shuts the whole effort on merge. When a brief
implements a child of a tracker, the line is `Closes #<child>` and the tracker is
referenced separately as `Refs #<tracker>`.

## `**Premise verification (PM, <date>):**`

A same-day evidence block proving the brief's premise still holds. Write it as a
**bullet list, one bullet per load-bearing claim**, and give every bullet all
three parts:

1. **the claim** — the specific thing the brief depends on being true;
2. **the command** — one command the Builder can paste verbatim;
3. **the observed result** — what that command actually printed, quoted.

A bullet missing part 2 or part 3 is an assertion, not verification. The point is
not that the PM looked once; it is that the Builder can **re-run** the check and
compare against what you saw. Conclusions-only prose satisfies the enqueue lint
(which is presence-only, by design) and still sends a worker to build against a
premise whose stated mechanism is false — every path the brief cites exists, so
nothing downstream catches it. Each bullet is what makes that failure cheap.

> **Premise verification (PM, 2026-08-13, against `main` @ `15a2b33`):**
>
> - The unguarded call site is still present:
>   `git grep -c 'compression_decode_buffer' App/MiniDumpTruck/Utilities/ZipReader.swift` → **`1`**
> - Nothing has touched the file since the commit that introduced it:
>   `git log --oneline -1 -- App/MiniDumpTruck/Utilities/ZipReader.swift` → **`b1d7351 ...`**
> - The size guard the fix must preserve is still there:
>   `git grep -c 'uncompressedSize' App/MiniDumpTruck/Utilities/ZipReader.swift` → **`4`**

**Prefer positionally stable output.** Quote a count (`grep -c`) or the matched
text itself rather than `grep -n` output, whose line number an unrelated commit
above the match can shift while the claim stays perfectly true. The Builder
compares substance and not bytes, so a moved line number is not a false premise
(builder persona rule 11) — but a bullet that cannot drift never puts that
judgment call in play.

**Verify the dependent element, not just the file.** Grep for the exact symbol,
string, or block the bullet's claim acts on. A bullet showing only that the
enclosing file exists proves nothing about the thing being changed inside it.

**Search by symbol, not by the issue's own wording.** Issue text is the least
reliable input you have. #70 named two files for its `FoundationNetworking`
blocker; a symbol-based repo-wide grep found five, because the three test files
used `URLProtocol` rather than `URLSession`. It also listed `NSWorkspace` in three
`Services/` files that turned out to contain only doc comments. Derive the roster
from the code every time.

**Prefer bootstrap-free commands.** `git grep`, `git log`, `git show`, `test -f`,
and plain file reads all work in a fresh worktree with nothing built, which is
what lets the Builder re-run the whole block in seconds before building
(builder persona rule 11). Bootstrap here is cheap — `cd App && swift build`,
about 12s — so the saving is small; the reason to check first is correctness, not
time. Mark any bullet that genuinely needs a built product:

> - *(post-bootstrap: needs `swift build`)* the CLI exposes the new subcommand:
>   `cd App && ./.build/debug/minidumptruck-cli --help | grep -c 'export'` → **`1`**

**Merged-dependency checks:** when the premise depends on an upstream PR already
being merged, verify it by **content** (grep the base for the expected symbol) or
by **PR state** (`gh pr view <n> --json state -q .state` → `MERGED`) — **never**
by `git merge-base --is-ancestor <sha> <base>`. This repo squash-merges, so the
pre-merge commit SHA is not preserved and `is-ancestor` on it always returns false
even when the change is in `main` — a false "dependency unmet". A brief must not
instruct the Builder to run an is-ancestor SHA check (the Builder is
remote-fenced and verifies by content anyway; see builder persona rule 15).

## Artifact-gate rule

Any literal artifact the brief hands Builder to paste verbatim — a shell command,
a GitHub Actions expression, a regex, a YAML snippet, a Swift directive — must
either:

1. name a gate that exercises it in its **real interpreter** (e.g. "validate with
   `actionlint`", "run under `sh -n`", "`swift build` parses `#if` blocks even on
   the branch it does not take"), so a wrong artifact fails loudly at Builder's
   gate rather than silently shipping; or
2. be downgraded to intended semantics only: *"intended semantics: X; Builder
   derives the exact form and validates it with Y."*

Never hand over a hand-written artifact in a language the brief author did not
run, with no gate.

**Say so explicitly when a gate cannot reach the artifact.** A `#if os(Linux)`
branch compiles on macOS only as far as syntax; its body is never type-checked by
the macOS build. **The container leg in the standard gate set is what reaches it**
— name that leg as the gate for any such block rather than declaring it
ungateable. A brief may only claim "macOS unaffected and nothing more" if it also
says why the Linux leg could not run, and its handoff must not claim Linux
verification in that case.

The genuinely ungateable case is narrower than it looks: an artifact whose real
interpreter exists on neither platform here — a GitHub Actions expression
(`actionlint` is the gate), a runner-only shell path, or a release workflow step.
`release.yml` has never executed, which is why #103 moved its packaging into
`scripts/build-app.sh`: shell that lives only inside a workflow step cannot be run
locally and would ship unproven.

## Falsification line

Every fix brief states the condition under which its diagnosis is wrong, and
instructs Builder to check it **before** implementing:

> **This diagnosis is wrong if …** — before writing any code, verify <X>; if it
> does not hold, STOP and hand back.

**Make the command repo-wide and symbol-based.** A falsification command that
greps a guessed list of two paths can return "nothing found" and argue for the
opposite of the truth. Grep the repository for the symbol, then compare the
result set against the roster the brief states.

A diagnosis that is plausible but unconfirmed is labelled *"hypothesis; confirm
before implementing."*

## `**PM decision (do not re-litigate)**`

Mark founder/PM design choices that are settled, to separate them from the
latitude Builder actually has. Everything not marked this way is Builder's call
within the roster.

> **PM decision (do not re-litigate):** `canImport(FoundationNetworking)`, not
> `#if os(Linux)` — it stays correct on any future platform with the same
> Foundation split. Builder implements; does not reopen the form debate.

## Gates

The exact verification Builder must run before writing the handoff, each with the
**verbatim output required in the handoff** — not "tests pass" but the command
and its actual tail. State any env-var prefixes inline so the Validator re-runs
them verbatim. All commands run from `App/`.

The standard set for this repo:

```bash
cd App && swift build                       # bootstrap; must exit 0
cd App && swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -E '^/.*warning:' | sort -u
cd App && swift test                        # full suite, macOS
# from the REPO ROOT, not App/ — the Linux leg:
container run --rm -v "$PWD:/src" -w /src/App swift:6.1-noble bash -lc 'swift test'
```

- **The Linux leg is part of the standard set, not an extra.** A macOS-only
  `swift test` does not cover this repo. #88 proved it twice: pass 2 passed every
  macOS gate, cleared Validator review, and then failed the Ubuntu job on four
  tests, because Foundation words file errors differently per platform (macOS
  quotes the filename, Linux does not) and the tests asserted on that wording.
  Nothing on the macOS side could have caught it. Since #92 the Ubuntu job is a
  **required, gating** check, so a brief whose gates stop at macOS is briefing
  work that cannot merge.
  - Setup, once per machine: `container system start`, then
    `container image pull swift:6.1-noble`. If `container system kernel set
    --recommended` reports the kernel already exists, that is benign.
  - Boots in ~4s. Add `--arch amd64` when architecture parity matters.
  - **The Validator re-runs this leg itself** rather than accepting the Builder's
    pasted output — that is how pass 3 of #88 was confirmed.
  - If the container runtime is genuinely unavailable, the brief must say so and
    the handoff must **not** claim Linux verification. Do not substitute a macOS
    run and call the Linux leg covered.
- **Expect a lower count on Linux than macOS**, and do not treat the difference as
  a failure. Two `@Test` declarations are Darwin-only and legitimately so:
  `SymbolLogTests.swift` (`#if canImport(os)`) and
  `SymbolServerTrustTests.swift` (`#if canImport(Security)`,
  `pinCertificateSessionHasDelegate`). macOS N ⇒ Linux N−2. State both numbers in
  the brief so a Builder does not "fix" a phantom regression.
- **Capture exit codes directly, never through a pipe.** `cmd | head` reports
  `head`'s status. That has produced false results in this repo at least three
  times: a bogus "0 warnings" baseline, a phantom 35-failure Linux run, and a
  meaningless `BUILD_EXIT=0`.
- **The warning gate's `--scratch-path` and `sort -u` are load-bearing.** A plain
  `swift build` re-run on a built tree is a no-op that emits nothing, so counting
  warnings from it returns 0 regardless of the code — it measures the build cache.
  The fresh scratch path forces a real compile. The compiler re-emits each warning
  once per compilation unit, so the 2 baseline warnings appear on 10 raw lines.
- **Phrase test and warning gates differentially against the baseline**, never as
  "all tests pass" or "zero warnings". State: same skip count (0), pass count up
  only by tests added, and the warning **set** compared against the 2 known ones.
  Name those two in the brief so the Builder does not adopt them as its own — and
  so that "fixing" them without authorization reads as the out-of-scope change it
  is.
- Add the change-specific checks: the new test, `actionlint` on any workflow
  change, an interpreter run for any handed-over artifact.
- Atomic-commit expectations, imperative mood, why-not-what. No `#NNN` issue
  references in code comments.
- **Run every gate to completion inline; never background-and-yield.** Do not
  start a long-running gate and then yield the turn to await a monitor — in the
  loop harness that ends the worker's run before it commits or writes the
  handoff, and the reaper records it as `.failed` (exit 0, no handoff), orphaning
  work that actually succeeded. Block on each gate in-turn; write the handoff
  only after the last one returns.
- **NEVER touch remotes** — push/PR/merge belong to the human-gated Scribe phase.

## Authorizations roster

An explicit allowlist and denylist, with the STOP contract stated inline:

- **AUTHORIZED:** every file/path/command Builder may touch, plus any scoped read
  exceptions and the worktree.
- **NOT authorized:** everything deliberately out of scope — other files, other
  issues' blockers, workflows, remotes, and always `docs/personas/**`,
  `scripts/multi-agent/**`, `multi-agent/**`. Those last three are the loop
  system's own control surfaces and process scratch; they are attended work, never
  lane work, and `multi-agent/` is gitignored so nothing there may be staged.
- **STOP contract:** if the work reveals the brief's approach is wrong, or the
  premise is stale, or something is broken beyond scope — append findings to the
  claimed file's body **and exit nonzero**, always both. Exiting 0 without a
  downstream handoff is a contract violation, not an alternate success.

## Handoff

The exact downstream filename Builder must write before any summary output:

`<REPO ROOT>/multi-agent/validator-notes/<issue>-<slug>.ready.md`

with full frontmatter (`issue`, `slug`, `stage: validator`, `pass` carried over
unchanged, `retries: 0`, `owner: null`, `updated`) and a body covering what
changed, how it was verified (exact commands + results), the premise re-run with
its real output, known risks, the branch/worktree, and a **"Why safe here"**
rationale. Add any Validator-specific instructions here.

The filename base must equal the frontmatter `<issue>-<slug>` — the
name-integrity lint blocks the file otherwise, with no exemptions.

### "Why safe here" (required in every handoff)

Beyond "build clean, tests pass," state the **system-specific reason the change
is correct** — the invariant, constraint, or prior incident it respects. Green
gates measure output, not comprehension; an AI-assisted diff can pass tests while
nobody has internalized why it is safe for *this* system's scars. A handoff whose
only justification is the green gates is **fix-required**, same as a bot flag.

One or two sentences, concrete:

> **Why safe here:** `canImport(FoundationNetworking)` is false on Darwin, so the
> guarded import compiles out entirely and the macOS build is unchanged by
> construction — confirmed by an unchanged 846/117 suite. The change cannot arm
> anything on the platform we ship today.

> **Why safe here:** preserves the `produced != uncompressedSize` check, which is
> the zip-bomb and truncation guard rather than a sanity assertion — the shim
> enforces the declared size before returning, same as the framework call did.

When a review catches a regression tied to a past incident, promote that
reasoning to a durable note (this template, a persona, or a memory), not just a
PR comment.

---

## Per-class checklists (append the ones that apply)

Short appendix sections. Include only the classes the brief touches.

### Untrusted dump input

Anything parsing a `.dmp`, a zip, or a symbol-server response is handling an
attacker-controllable file. The class rules, each earned from a closed issue:

- **Overflow-safe arithmetic** on every value read from the file — RVAs, sizes,
  counts. `BinaryReader` uses overflow-safe forms; a new call site doing plain
  `+`/`*` on file-supplied values is a defect (#21).
- **Sanitize at the output boundary**, not at the source — CSV, HTML, JSON, and
  terminal sinks each need their own escaping, and `NSError` descriptions leak
  absolute user paths (#49, #40, #22). Confirm
  `App/MiniDumpTruck/Utilities/ErrorSanitization.swift` is actually on the path a
  new sink uses.
- **Preserve existing guards** when refactoring: the zip size-mismatch check,
  invalid-UTF-8 filename rejection, WinZip AES rejection (#19, #20, #21).
- **Path identity on macOS** — symlinks and case-insensitivity. A string prefix
  check is not a containment check (#31).

### CI / workflow change

`actionlint` is mandatory on any changed `.github/workflows/*.yml`. GitHub Actions
expressions have a narrow grammar with no arithmetic, and the failures that matter
— an undefined `needs:` reference, a nonexistent `runs-on`, an injection through
an untrusted `${{ }}`, an unresolvable `uses:` pin — are all valid YAML. Validate
in the real linter, never by eye or by a YAML parser.

### SwiftUI / view change

- Keyboard navigation: a tappable row that is not a `NavigationLink` loses it
  (#32).
- `onChange(of:)` does not fire when the value is unchanged — a separate trigger
  counter is the workaround.
- `@State` cached in a view needs `onChange(of: key)` to refresh when the parent
  passes new data.
- Only one branch of an `if/else` may render; do not show an empty list beside an
  empty state.

### Dependency change

`App/Package.swift` pins every dependency with `exact:` (#11). A brief that
authorizes a new dependency names the package and the exact version; the Builder
must not choose `from:`, `.upToNextMajor`, or a branch/revision pin, and must not
add an unauthorized dependency at all — that is a scope change and a STOP.

### Deletion / retirement

Repo-wide consumer sweep before deleting. There is no type-checker here that will
catch a dangling reference for you: grep the whole repository for the symbol,
including tests, shell scripts under `scripts/`, workflow files, and docs — not
just the source tree.

### Cross-platform (Linux) work

**This section used to say the gates run on macOS only and that Linux work was
#80's scope. That is obsolete** — #80, #92 and #102 landed, the Ubuntu job is a
required gating check, and the container leg is now part of the standard gate set
above. A brief that still says "gates prove macOS invariance and nothing more" is
briefing work that cannot merge.

What still holds for this class:

- **Verify Linux facts in a container before briefing them.** Not after. Three of
  the PM's hypotheses were disproved this way before a Builder ever saw them:
  `st_birthtime` unavailability, an "empty `localizedDescription`" on Linux, and
  `--static-swift-stdlib` producing a portable binary. The last would have shipped
  an artifact that refuses to start on a clean Ubuntu.
- **A premise bullet about Linux behaviour needs Linux output**, quoted, from the
  pinned image — not reasoning from macOS. A short probe file run through
  `container run … swift:6.1-noble` costs seconds and is the difference between a
  verified premise and a plausible one.
- **`#if os(Linux)` branches are not type-checked by a macOS build.** The compiler
  parses the syntax of the branch it does not take and nothing more. A brief
  handing over such a block must say the macOS gates prove only that it parses,
  and the Linux leg is what proves it compiles.
- **Foundation is not uniform across platforms.** swift-corelibs-foundation
  differs from Apple Foundation in error wording, error codes, and available
  APIs — `Data(contentsOf:)` on a missing file renders the filename on macOS and
  not on Linux, and `FileHandle` throws `NSFileNoSuchFileError` (4) there versus
  `NSFileReadNoSuchFileError` (260) here. A test that asserts on a Foundation
  string is a portability bug waiting for CI. Assert on **our** behaviour, and
  construct the input rather than provoking it from the OS when the assertion
  depends on the input's exact text.
