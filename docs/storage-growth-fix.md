# Runwell storage growth — diagnosis and fix plan

**Status:** diagnosed, not yet fixed
**Written:** 2026-09-09, after a full-day real-usage baseline test
**Verdict: yes, all of it is fixable.** No feature is lost, no honesty guarantee is
weakened. The largest fix is a data-model decision, not a rewrite.

---

## 1. What the baseline test measured

The history database was cleared at 00:15 on 2026-09-09 and the machine used
normally for a working day — coding, music, iOS/Android simulators, charge cycles.

| | Baseline 00:15 | After 17.1 h | Growth |
|---|---|---|---|
| File size | 790 KB | **56,979,456 B (54.3 MB)** | ×72 |
| `bucket` rows | 2,077 | **167,212** | ×80 |
| `app_group` rows | 298 | **698** | ×2.3 |
| `insight_event` rows | 1 | 50 | — |

**Rate: ~76 MB/day.**

Projected steady state under the current `RetentionPolicy.default`
(`minuteBucketDays: 7`, `quarterHourBucketDays: 90`):

- 1m tier, 7 days ≈ 534 MB
- 15m tier, 90 days ≈ 810 MB
- **≈ 1.3 GB steady state**

For a menu-bar battery monitor. This also accrues on the machine of the one other
person using Runwell.

### Correcting an earlier assumption

A previous session saw 24.5 MB in 6 hours and attributed it to dev
rebuild/relaunch cycles inflating `app_group` (494 entries), filing it as
unrepresentative of normal use. **That explanation was wrong.** This run was a
clean baseline with no dev-loop noise and grew *faster* per hour. The cause is
structural and always present.

### Where the bytes are (`dbstat`)

| Object | Size | Share |
|---|---|---|
| `bucket` table | 33.6 MB | 62% |
| `sqlite_autoindex_bucket_1` (PK) | 17.3 MB | 32% |
| `bucket_lookup` index | 2.9 MB | 5% |
| everything else | < 0.5 MB | < 1% |

**`bucket` and its PK index are 94% of the file.** `battery_sample` (0.27 MB),
`app_group` (0.12 MB) and `insight_event` (0.01 MB) are all irrelevant to growth.
`raw_sample` is empty — the 2-hour retention works correctly.

---

## 2. Root causes

Three independent multipliers. They compound: cause A sets the row count, B doubles
it, C sets the cost of each row.

### Cause A — every process is written every tick, active or not

`HistoryStore.record()` (`Sources/RunwellKit/Persistence/HistoryStore.swift:161`):

```swift
for group in snapshot.groups {
    // upsert app_group, insert bucket
}
```

`snapshot.groups` comes from `grouper.group(metrics:workspace:)`
(`SamplerService.swift:221`) — **every live process on the machine**. There is no
filter of any kind. The only guard in the whole path is
`guard !snapshot.isFirstSample` at line 99, which exists for interval correctness,
not volume.

Measured consequence:

- Mean **312 app groups per minute slot**; peak 548.
- 149,536 of the 1m rows exist; 67,289 (**45%**) have zero energy, zero CPU and
  zero disk.
- **318 of 698 groups** used < 1% cumulative CPU across the entire day, yet
  produced 47,433 rows.
- `adb`, `crashpad_handler`, `BTLEServerAgent`, `tipsd`, `pboard`, `pkd`,
  `transparencyd` and ~40 similar daemons each hold **all 479 minute slots**,
  recording that nothing happened.

This was never a decision. The write path was designed around "record this sample
truthfully" — visible in the care of the `CASE WHEN ?13` clauses that stop an
unavailable metric contaminating a sum with a zero. The question *should this row
exist at all* was simply never asked.

### Cause B — 1m and 15m are both written on every tick

Lines 193–211 loop `for (start, granularity) in [(minute, "1m"), (quarterHour, "15m")]`
and issue the same upsert twice. The 15m tier is not rolled up from 1m; it is
independently accumulated. Every tick therefore costs two row-touches, and the 15m
tier — retained **90 days**, 13× longer than the 1m tier — carries the same 312
groups per interval.

The 15m tier is currently 17,676 rows against 55 slots — i.e. it too is storing
one row per idle daemon per quarter hour, and it is the dominant term in the
long-run projection (810 MB of the 1.3 GB).

### Cause C — the primary key is a filesystem path, stored twice

`ApplicationGroupID.storageKey` (`Domain/ProcessIdentity.swift:74`) is
`"\(kind.rawValue):\(value)"`, where for the `.executable` kind
`value = identity.signingIdentifier ?? identity.redactedPath` (line 69). When a
binary has no signing identifier, **the full path becomes the key**.

- Average key length **across stored bucket rows: 76.7 chars**
- Longest key: **331 chars**
- Because it is the PRIMARY KEY, SQLite stores it in the table *and* again in
  `sqlite_autoindex_bucket_1` — **~229 bytes of text per row**, against a numeric
  payload under 80 bytes.
- Actual cost: **319 bytes/row** for `bucket` + its PK index.

Worst offender, the iOS simulator runtime, which alone created **230 app groups**:

```
executable:/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/
CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/
System/Library/PrivateFrameworks/MobileAssetDaemon.framework/XPCServices/
com.apple.MobileAsset.DownloadService.Builtin.xpc/com.apple.MobileAsset.DownloadService.Builtin
```

`session_id` (a 36-char UUID string) is stored per row as well, also twice where
indexed.

---

## 3. The constraint any fix must respect

Appendix F — *unknown is not zero* — is load-bearing throughout the codebase, and
finding #7 in the 2026-09-08 review was exactly this bug in the value dimension.
Dropping rows naively relocates the same lie into the row's *existence*: a missing
row would ambiguously mean "idle" or "Runwell wasn't running".

### A measurement that decides the design

Every one of the 67,289 apparently-zero rows carries a **real memory reading**:

```
truly_empty (incl. memory)          = 0
no_readable_metric (all counts = 0) = 0
memory-only rows                    = 67,687
```

So these rows are **not empty** — they are idle-but-resident processes whose memory
was genuinely measured. A filter of "drop rows where everything is zero" would
therefore match **nothing** and save **nothing**. This is the single most important
finding in this document, and it rules out the obvious fix.

The correct framing: the row is not empty, it is **not interesting** — and the
memory figure it exists to preserve has **no consumer**.

### Verified: historical memory is never displayed

- `BucketRow.peakMemoryBytes` (`HistoryStore.swift:260`) is populated by
  `topEnergyConsumers`.
- The only non-test caller chain is `HistoryView.load()` → `energyBreakdown()` →
  `topEnergyConsumers()` (`Sources/Runwell/UI/History/HistoryView.swift:87`).
- `grep peakMemory Sources/Runwell/UI/History/HistoryView.swift` → **no match**.
- `grep -rn 'peakMemory\|memory_bytes_max' Sources/Runwell/UI/` → **no match**.

Live memory in the process list comes from the current snapshot, not from history.
**No UI reads historical memory at all.** Retaining 67,687 rows per day to preserve
a number nothing displays is the whole of the waste.

### Read paths are aggregate-only — verified safe

Both bucket readers are `SUM`/`MAX`/`GROUP BY` over a time window
(`HistoryStore.swift:441–452, 492–494`). A row contributing `0` to a `SUM`
is indistinguishable from an absent row. Confirmed against live data:

```
total energy, all rows           = 18732.323 J
total energy, idle rows excluded = 18732.323 J   (identical)
```

Dropping idle rows changes **no** currently displayed number.

---

## 4. The fix

Four changes, ordered by payoff per unit of risk. Fix 1 alone resolves the problem;
2–4 make it durable.

### Fix 1 — Don't write a bucket row for an idle process *(≈45% of rows)*

Define "idle" **positively and explicitly**, so a missing row has exactly one
meaning:

> A bucket row is omitted when the process was successfully measured and did no
> attributable work: energy, CPU and disk are all zero **and** each of those
> metrics was genuinely readable (`*_sample_count > 0` for the tick). Memory
> residency alone never justifies a row.

The distinction the schema already supports and this preserves:

| Situation | Today | After |
|---|---|---|
| Measured, genuinely idle | row of zeros | **no row** — means idle |
| Unreadable metric | row, count = 0 | **row still written** — means unknown |
| Any real activity | row | row |

Unreadable-but-present processes must **keep** writing rows; that is the case
Appendix F exists for, and it is rare (`inaccessible_process_count` is already
tracked per battery sample).

For this to be unambiguous, the reader must know which minutes Runwell was actually
running. **`battery_sample` already provides exactly this spine** — it writes once
per tick, independently of the bucket loop, and stays small (0.27 MB/day). Document
it as the coverage record; no new table is needed.

Implementation: a guard at the top of the `for group in snapshot.groups` body
(`HistoryStore.swift:161`), plus a one-line comment stating the semantics of an
absent row. Roughly 10 lines.

### Fix 2 — Stop storing paths in the primary key *(≈2–3× on what remains)*

Replace the raw string key with a fixed-width digest, keeping the human-readable
value in `app_group` where it is stored **once** rather than per row.

- Add `app_group.storage_key TEXT` preserving today's value for display/debugging.
- Make `app_group.id` a short digest (e.g. the first 16 hex chars of SHA-256 of the
  current `storageKey`) — 16 bytes replacing an average of 77, in both the table and
  the PK index.
- `ApplicationGroupID.storageKey` keeps its current meaning; only the *persisted*
  key changes, so grouping logic and `bundleIdentifier` are untouched.

This is a migration (migration 4) with a mechanical `UPDATE ... SET id = <digest>`
over existing rows; the FK is `ON DELETE CASCADE` from `app_group`, so it must be
done in the established migration style used for migrations 2 and 3.

Optionally, `session_id` can move to a small `session` table with an INTEGER FK,
removing another 36 bytes/row. Lower priority.

### Fix 3 — Derive the 15m tier from 1m instead of double-writing

Roll 15m up from completed 1m buckets during the existing hourly prune task rather
than writing both tiers on every tick (lines 193–211). This halves write volume,
and — because the 15m tier is retained 13× longer than the 1m tier — removes the
dominant term in the long-run projection.

Sequencing note: with Fix 1 in place, the rollup must sum only rows that exist,
which is already the correct behaviour for aggregates.

### Fix 4 — Make retention defensible, and bound it

`RetentionPolicy.default` keeps 15m buckets for **90 days**. Combined with ~312
groups per interval that is the 810 MB term. Recommended:

- Reduce `quarterHourBucketDays` from 90 to **30**.
- Add a **size ceiling** checked in the hourly prune (`AppEnvironment.swift:216`):
  if the file exceeds a bound (e.g. 200 MB), drop the oldest 1m buckets first and
  surface it honestly in Settings rather than silently growing.
- `prune()` currently never `VACUUM`s — only `deleteAllHistory()` does
  (`HistoryStore.swift:617`). Deleted pages are reused but the file never shrinks.
  Add a periodic `VACUUM` (or `PRAGMA auto_vacuum=INCREMENTAL` at creation).

### Projected result

| Stage | Steady state |
|---|---|
| Today | ~1.3 GB |
| + Fix 1 | ~700 MB |
| + Fix 2 | ~250 MB |
| + Fix 3 | ~150 MB |
| + Fix 4 | **~50 MB, hard-bounded** |

---

## 5. Verification plan

Per the established practice on this project — **prove each test fails without its
fix**, and check claims against the running app, not just the source.

1. **Before touching anything**, write characterization tests pinning current
   read-path output (`topEnergyConsumers`, `energyBreakdown`) against a fixture
   containing active, idle and unreadable groups. These must produce identical
   values after every fix.
2. **Fix 1:** a test asserting an unreadable-metric group still writes a row while a
   measured-idle group does not. Revert the guard, confirm the test fails, restore.
3. **Fix 2:** a migration test on a copy of the real 57 MB database — every
   `app_group` resolves, no orphaned buckets, `topEnergyConsumers` output byte-identical
   before and after.
4. **Fix 3:** assert a 15m bucket rolled up from 1m equals what direct accumulation
   produced for the same window.
5. **End to end:** clear history, run a normal day, confirm growth is ~1–3 MB/day
   rather than 76 MB — and re-confirm the History view shows the same apps and
   numbers as it does today.
6. Full `swift test` and a `-warnings-as-errors` build must stay clean.

---

## 6. Notes from the same test run — not storage bugs

- **`sleepPrevention` works.** Fired 5× overnight against `AddressBookSourceSync`
  holding a power assertion while the screen was off (01:22, 03:30, 04:07, 05:04,
  09:01). This is the feature's first trustworthy real-world confirmation.
- **The `wakeupStorm` foreground fix (`6235147`) holds.** All 12 firings are
  plausible (Chrome peaking at 2,198 wakeups/sec) with no repeat of the
  actively-watched-YouTube false positive.
- **`memoryPressure` deserves an audit.** 23 firings between 10:12 and 16:50 — the
  highest of any rule — and it has never been checked for the "fires on the app
  you are actively using" bug that affected `wakeupStorm`.
- **Unchanged blockers:** no app-layer test coverage (`AppEnvironment`,
  `BackgroundService`, `NotificationService`), and the build has still never run on
  hardware other than this machine.

---

# Part 2 — Data-correctness audit

Part 1 asked *how much* is stored. This part asks whether what is stored is
**true**. Same 17-hour dataset. Two of these are more serious than the size problem.

## 7. Attributed energy is ~10× too low, and nothing says so

Cross-checked against physical ground truth rather than against the code.

Battery fell **94% → 86% between 11:00 and 13:00**, on battery power, not charging.
For a 70–100 Wh pack that is **2.8–4.0 W** of actual system draw. Over the identical
window Runwell attributed:

```
11:00–13:00   3,082 J   =  0.43 W
```

**Runwell accounts for roughly 11–15% of the energy the machine actually used.**
Across the whole day: 18,732 J over 17 h = **0.31 W average**, for a laptop running
Xcode, iOS/Android simulators, Chrome video and Teams.

Per-app figures are correspondingly implausible:

| App | Attributed | Reality |
|---|---|---|
| Google Chrome | 0.4 W | playing video; realistically several W |
| Xcode | 0.03 W | ran builds |
| Code | 0.06 W | — |
| Microsoft Teams | 0.02 W | — |

### Cause: ~217 processes per sample are invisible, and the gap is never disclosed

`battery_sample.inaccessible_process_count` averages **217.5** (min 178, max 267)
against 698 known groups. These are root-owned daemons — `kernel_task`,
`WindowServer`, `mediaanalysisd` and similar — where `proc_pid_rusage` returns
`ri_energy_nj` only for processes the user owns. `WindowServer` and `kernel_task`
alone typically dominate real draw.

The collector is **not** at fault: `ri_energy_nj` (`ProcessCollector.swift:86`) is a
genuine kernel counter, and the delta arithmetic in `MetricEngine.swift:127–134` is
correct. The numbers are right *for what Runwell can see*. The defect is that
nothing in the stored data or the UI communicates that this is a minority of the
machine.

This is an Appendix F violation of the same family as finding #7, one level up: not
a fabricated zero for one metric, but a **confidently-presented partial total
offered as if it were the whole**. A user reading "Chrome: 0.4 W" reasonably
concludes Chrome is cheap.

### The design already solves this — it just isn't used

`SystemSnapshot.measuredAppShare(of:)` (`Domain/ApplicationGroup.swift:168–176`)
computes exactly the right thing:

```swift
let confidence = inaccessibleProcessCount == 0 ? 1.0
    : Double(groups.reduce(0) { $0 + $1.processCount })
        / Double(groups.reduce(0) { $0 + $1.processCount } + inaccessibleProcessCount)
```

It even carries the mandated wording — `shareLabel` = *"Measured application energy
share"*, with a comment insisting it must never be called "battery percentage used".

**`grep -rn 'energyShare' Sources/` returns no non-definition hits — nothing calls
it.** The correct, coverage-aware, honestly-labelled path was built and then never
wired to anything.

## 8. `coverage_confidence` is a hardcoded constant

Every one of the 167,491 bucket rows stores **exactly 0.85** — min, avg and max are
identical. Source: `MetricEngine.swift:134`

```swift
energyWatts = .derived(watts, confidence: 0.85)
```

A literal. It does not vary with `inaccessibleProcessCount`, with how many processes
in the group were readable, or with anything else. The column's own schema comment
says *"coverage travels with the aggregate, so a bucket built from partly unreadable
processes is not shown as if it were complete"* — the column does not do this.

Real coverage on this dataset is ≈0.76 and moves sample to sample (178–267
inaccessible). Storing 0.85 always is worse than storing nothing: it is a
**fabricated precision signal**, and `HistoryView.swift:463` already branches on a
threshold "below the 0.85 a fully readable energy…", i.e. UI logic is keyed to a
constant that can never change.

**Fix:** compute per-sample coverage from `inaccessibleProcessCount` and the group's
readable process count — the `measuredAppShare` formula — and persist that.

## 9. Sampling gaps are real but correctly handled

35 gaps > 5 min, nearly all 15–18 min, clustered 00:48–10:00 — the macOS dark-wake
cadence during overnight lid-close. Expected, not a defect.

Verified the gaps do **not** corrupt energy: `MetricEngine.counterDelta` uses
`max(0, current - previous)` and `interval_seconds_sum` accumulates only real
elapsed seconds (measured 5.2 s / 10.5 s per sample, matching the menu-bar and
battery-idle cadences). Observed duration totals 7.77 h against 17 h wall clock,
correctly reflecting that the app was suspended for the remainder — average watts
divides by observed time, not window length. **The finding #2 fix is working
correctly in production.**

## 10. No data corruption

Across all 167,491 rows: no negative energy, no negative CPU, no CPU above core
count, no memory above 64 GB, no negative intervals. Total CPU peaks at 24% of
1200% available — low for the day's workload, but that is the §7 coverage gap
again, not corruption.

`raw_sample` is empty: the 2-hour retention works. `app_group` (698 rows, 0.12 MB)
and `insight_event` (50 rows) are proportionate and healthy.

## 11. Revised priority

Severity order changed after this audit. **§7 outranks the storage problem** — a
1.3 GB database is embarrassing, but numbers that are wrong by 10× while presented
confidently are the thing that makes the app misleading, and it is the exact
failure mode the project's core principle exists to prevent.

| # | Issue | Severity | Effort |
|---|---|---|---|
| §7 | Energy ~10× low, coverage gap undisclosed | **Critical** | Medium — wire up `measuredAppShare`, label honestly |
| §8 | `coverage_confidence` hardcoded 0.85 | **High** | Small — compute it, migration optional |
| §1–4 | ~1.3 GB steady-state growth | High | Medium |
| §6 | `memoryPressure` never audited for foreground false-positives | Medium | Small |
| — | No app-layer test coverage | Medium | Large |

§7 and §8 share a root cause and should be fixed together: coverage is measured,
carried to exactly one unused function, and discarded everywhere it matters.

Note that §7 cannot be fixed by making the numbers bigger — the missing energy
belongs to processes Runwell fundamentally **cannot** read without elevated
privileges. The honest fix is disclosure: show measured share against total draw,
label it as Section 3.1 already mandates, and let the em-dash convention cover what
is genuinely unknowable.

---

# Part 3 — Fixes applied (2026-09-09)

Verified by reverting each fix individually and confirming its test fails with the
expected wrong value, then restoring. 81 tests before, **86 after**; clean under
`-Xswiftc -warnings-as-errors`.

## Applied

**§8 — real coverage instead of a hardcoded 0.85.**
`EnergyCoverage` gains `readableProcessCount` and `coverageConfidence`
(`Domain/ApplicationGroup.swift`), extracted from the formula that already existed
inside the unused `measuredAppShare`. `HistoryStore.record()` now persists the
snapshot's real coverage rather than `group.totalEnergyWatts.confidence`, which
traced back to a literal in `MetricEngine.swift:134`.
*Revert check:* confidence came back as 0.85 — off by 0.65 from the expected 0.25,
and by 0.10 from 1.0 under full coverage.

**§1 — idle rows are no longer written.**
A guard in the `for group in snapshot.groups` loop skips a group only when energy,
CPU and disk were all **readable and zero**. Unreadable metrics still write their
row, preserving the Appendix F distinction. Memory residency alone no longer earns
a row.
*Revert check:* 4 rows instead of 2, and `["Busy", "Idle"]` instead of `["Busy"]`.

New tests: measured-idle writes no row; unreadable still writes one; omitting idle
rows leaves aggregates unchanged; coverage reflects readable share; full coverage
stores 1.0.

## Deliberately not applied

**§6 — `memoryPressure` needs no foreground guard. The Part 2 assessment was wrong.**
`wakeupStorm` and `hiddenBackgroundLoad` guard on `!isForeground` because their
wording asserts the app is idle ("while you're not using it", "even when it looks
idle") — naming the focused app contradicts the sentence. `memoryPressure` says
"Holding 4.2 GB while system memory pressure is warning", which is true regardless
of focus, and the app in front of you is frequently the legitimate top holder.
A foreground guard would suppress correct information. The rule is already gated on
a real kernel pressure level, a top-decile cutoff and a minimum footprint.

## Still outstanding

- **§7 disclosure** — the energy *numbers* cannot be fixed (`ri_energy_nj` is not
  readable for root-owned processes), but the UI must stop presenting ~15% of the
  machine as the whole. `measuredAppShare` and `shareLabel` exist and remain unused.
  This is the highest-value remaining work.
- **§2 key hashing (migration 4)**, **§3 15m rollup**, **§4 retention bound**.
- App-layer test coverage; never run on other hardware.

## Note on the dataset

The history database was cleared shortly after this audit (57 MB → 290 KB, app not
running). Every figure in Parts 1 and 2 comes from the full 17-hour dataset and
stands, but the `insight_event` rows behind the §6 discussion are gone — that
assessment was therefore completed from the source, not re-checked against data.
A fresh baseline is needed to measure the storage fixes in production.
