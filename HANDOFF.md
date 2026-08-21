# Handoff — Linux port, state as of 2026-08-18

`main` @ `ca1b4ee`. Lane idle: nothing queued, nothing parked, nothing pending.

---

## Where the port actually is

**The Linux CLI is done and verified.** Not inferred from macOS — measured on
Linux.

| | |
|---|---|
| `MiniDumpTruckCore` + CLI | build clean on Linux |
| Test suite | **854/854 passing**, exit 0 |
| CI | Ubuntu job is a **required, gating** check |
| CLI | exercised every PR against a real dump |
| Artifact | 87MB static-stdlib binary + SHA-256 |
| Runtime dependency | **`libcurl4`** only — documented in `CLI.md` |

The 854-vs-856 gap is fully accounted for: exactly two `@Test` declarations are
Darwin-only, and both are legitimately so.

```
SymbolLogTests.swift          #if canImport(os)        "default backend is the os.Logger backend on Apple platforms"
SymbolServerTrustTests.swift  #if canImport(Security)  pinCertificateSessionHasDelegate()
```

**Do not treat a Linux CI failure as informational any more.** Before #92 the job
reported success by construction; that masking is gone. Green means Linux works.

### Merged this round

`#78` `#79` `#74` `#76` `#73` `#91` `#75` `#95` `#86` `#97` `#98` `#80` `#92`
— plus `#82` (tracked pre-push hook).

---

## Open work

### #81 — Linux GUI (the only large piece left)

**Architecture is decided — do not re-litigate.** SwiftUI stays on macOS.
Linux gets SwiftCrossUI. **Sharing happens below the UI, not at it.** Full
reasoning is in the issue comment dated 2026-08-17; the short version:

- The macOS GUI is a *document-based app*, not just views — `DocumentGroup ×5`,
  `NSDocumentController ×6`, `FileDocument`, `onDrop`. That is Open Recent,
  Finder double-click, "Open With", drag-to-Dock, with real bug-fix history
  behind it (#46, #23, #6). SwiftCrossUI has no document architecture.
- Asymmetry that settles it: SwiftCrossUI **on Linux** is strictly better than
  nothing. **On macOS** it replaces working native code with a pre-1.0,
  largely single-maintainer dependency pulling a heavy transitive C tree
  (417 build steps, libwebp).
- Share presentation *logic* in Core instead — section ordering, blame
  attribution, formatted rows, verdict states. `SummaryView` (541) and
  `CrashAnalysisView` (483) are already report-shaped over `TextReporter` and
  `CrashAnalyzer`. The Linux UI should land well under the 4,108-line figure.

**Spike target changed: `HexView`, not `SummaryView`.** #70 picked the largest
view; largest ≠ hardest. `SummaryView` renders data Core already assembles — the
easiest screen, proves the least. `HexView` is virtualised scrolling with
selection over gigabyte memory regions. If a cross-platform toolkit fails, it
fails there.

**Prerequisite: an Ubuntu VM with a desktop** (UTM runs arm64 Ubuntu natively on
Apple Silicon). Containers are headless — that is the whole reason display
bridging kept coming up. A VM removes the question: the app opens in a real GNOME
session. Keep containers for build/test.

Toolkit survey, measured:

```
SwiftCrossUI    v0.8.0   pushed 2026-08-16   1709 stars   resolve exits 0 on Swift 6.1 Linux
adwaita-swift   0.2.6    pushed 2024-10-17   DORMANT (~22 months)
SwiftGtk forks  none     2023                dead
```

#70 calls adwaita-swift "more mature". **That is no longer true** and should not
anchor the evaluation.

### #88 — three more `localizedDescription` sinks

`InputPipeline.swift` ×2 → `.zipParseFailed` → user alert with **no** sanitiser
(its sibling branches call `sanitizedDetail`); `JSONExporter.swift` → exported
file. Plus `OpenError.sanitizedDetail`, which strips control characters and
truncates but **never removes paths** — it defends against injection, not
disclosure. Small, self-contained, unblocked, needs no decisions.

### #71 / #5 — packaging and macOS signing

Pre-existing. #71 should consume #80's Linux artifact; `libcurl4` is what a
future `.deb` would declare.

---

## Working practices earned the hard way

**Verify Linux facts in a container before briefing.** This is the single biggest
change. Setup: `container system start`, `container system kernel set
--recommended` (the interactive prompt fails under automation — that flag is the
way through), `container image pull swift:6.1-noble`. Then:

```bash
container run --rm -v "$PWD:/src" -w /src/App swift:6.1-noble bash -lc 'swift test'
```

Boots in ~4s. `--arch amd64` gives x86_64 if architecture parity matters.

Three of the PM's hypotheses were **disproved** this way before a Builder saw
them: `st_birthtime` unavailability, an "empty `localizedDescription`" on Linux,
and `--static-swift-stdlib` producing a portable binary. The last would have
shipped an artifact that refuses to start on a clean Ubuntu.

**Never sequence two briefs that touch the same file.** #80 pass 1 blocked
because #92 merged **29 seconds** after its brief was stamped, rewriting the same
`ci.yml` job. Earlier pairs (#91→#75, #95→#98) were sequenced correctly; this one
was not.

**Beware `PIPESTATUS`.** `cmd | head` reports `head`'s status. This produced
false results at least three times: a bogus "0 warnings" baseline, a phantom
35-failure Linux run, and a meaningless `BUILD_EXIT=0`. Capture exit codes
directly.

**Measure baselines cold.** `swift build` on a warm tree is a no-op emitting
nothing, so warning counts read 0 regardless. Use
`--scratch-path "$(mktemp -d)"` and `sort -u` — the same warning repeats once per
compilation unit.

**Verify against `origin/main`, not the working checkout.** A stale checkout
produced wrong line numbers in a brief and made a container run disagree with CI.

**Test-only changes need a break-and-revert gate.** Temporarily break the code
under test, confirm the test fails, revert, paste both. Rewriting a test to make
it pass removes the usual signal that it works.

---

## Lane notes

- **Keyword chain is fixed.** Builder carries the brief's `Keyword:` line into
  its handoff; Validator passes it through rather than substituting `Refs`. Both
  persona rules were added after four issues merged without auto-closing.
  Confirmed working on #92 and #80.
- **Lane is clean.** The superseded `.blocked.md` files for #73, #74, and #80
  were archived to `multi-agent/archive/` on 2026-08-18. Their findings are worth
  reading if similar failures recur — #74's traced a misread `git ls-files`
  output, #80's caught a 29-second base race and the missing `gh` in
  `swift:6.1-noble`. An inbox sweep now correctly reports nothing outstanding.
- **`network-deferred` stalls overnight work.** Hit twice (#74, #80). The Scribe
  correctly releases the task rather than failing, but it then sits until the
  loops resume. Machine-sleep artifact, not a lane defect.
- **Merge gate is now commit-scoped. FIXED 2026-08-18.** It used to verify PR
  identity, branch, and checks but **not `head_sha`**, though the pending file
  recorded one — so any later push to an approved branch merged under the old
  approval. This nearly bit us; an approval was withdrawn deliberately because of
  it.

  `_ml_merge_approved` now runs **identity gate 3**: it reads `head_sha` from the
  approval file, compares it against the live `headRefOid`, and refuses on a
  mismatch (`SKIPPED-head-sha-moved`) or when the field is absent
  (`SKIPPED-no-head-sha`, fail-closed — every Scribe-written file carries one, so
  an approval without it is hand-made or pre-gate). A gh failure is separated
  from a genuine mismatch, same as gate 2, so a network blip does not read as
  tampering.

  Two tests in `test-queue.sh` cover it, and both were confirmed to fail with the
  gate removed. The gh stubs are field-aware now — gate 2 asks `headRefName` and
  gate 3 asks `headRefOid` through the same `gh pr view`, so a stub answering
  both with the branch name would make the SHA gate untestable.
- **Auto-approve classes are still unconfigured** (`merge-policy.sh`) — both
  sentinels, both 0-line caps, fail-closed. Founder decision. Recommendation:
  docs-only is safe; **tests-only is not** — #97/#98 were test-only and needed
  break-and-revert gates precisely because a weakened test merges green and
  silent. The `head_sha` precondition that used to block this is now satisfied.

---

## Suggested next round

1. **#88** — small, unblocked, no decisions needed.
2. **Ubuntu VM** — prerequisite for #81 and the thing that makes GUI work
   ordinary rather than awkward.
3. **#81 spike** — one screen (`HexView`) under SwiftCrossUI + GTK, run in the
   VM, reporting on virtualised scrolling, selection, keyboard navigation, a
   `NavigationSplitView` equivalent, and packaging cost on Ubuntu and Kali.

Phrase goals to end where the agent's authority ends — *"drive X to the approval
gate"*, not *"close out X"*. Merges require a human rename by design, so a goal
demanding a closed issue will loop.
