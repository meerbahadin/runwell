<div align="center">

<img src="Resources/Runwell.icon/Assets/App%20Icon%20Template%20(4).svg" width="96" alt="">

# Runwell

**A macOS battery monitor that tells you what it cannot measure.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)

</div>

---

## Read this first

**Runwell can see about two thirds of the processes on your Mac.**

macOS only reports per-process energy for processes your own user owns. `kernel_task`,
`WindowServer`, and roughly 200 other system daemons are invisible to it — not
estimated, not approximated, simply unreadable. On the development machine that
worked out to ~67% coverage, and measured app energy accounted for roughly an
eighth of real battery draw.

No permission, entitlement or privilege escalation fixes this. There is no API that
returns the number.

So Runwell does the only honest thing available: it tells you. Every energy share is
labelled as a share of *what could be measured*, the coverage figure is shown rather
than hidden, and a reading macOS refuses to give is displayed as an em dash — never
as a zero.

If you want a single confident wattage figure, Runwell is the wrong app. It will not
invent one.

---

## Why it exists

Activity Monitor gives you an "Energy Impact" number with no units, no provenance
and no way to tell a measurement from a guess. Runwell was built on the opposite
premise: **every number carries where it came from.**

| Badge | Meaning |
|---|---|
| **Measured** | Read straight from a system counter. |
| **Derived** | Computed from two or more measurements. |
| **Estimated** | Inferred from a model. Treat as approximate. |
| **Unavailable** | macOS would not say. Shown as `—`, never as `0`. |

That last row is the one that matters. A missing reading is not a reading of zero,
and an app that conflates them is lying to you quietly. This rule is load-bearing
throughout the codebase: unavailable metrics are `Optional` all the way from the
collector to the database to the view, and a metric's sample counter reaching zero
is what lets the read path say "unavailable" instead of averaging nothing and
reporting a confident `0.00 W`.

## Compared to Activity Monitor

Activity Monitor is a process table that happens to have an energy tab. Runwell is
built the other way round, and the difference shows up in three places.

**It is fast, and it stays fast.** The application list handles ~166 grouped
applications smoothly because the expensive work happens once per sampler cycle
rather than once per row per frame. Getting there meant fixing four real problems,
each measured rather than guessed:

| | Before | After |
|---|---|---|
| App icons (filesystem hit per row, per redraw) | 38 ms/frame | 0.02 ms |
| Coverage confidence (was O(n²) over all groups) | 3.44 ms/frame | 0.07 ms |
| Group filter + sort | re-ran on every read | cached per sampler cycle |
| Row updates | every row depended on every property | `Equatable`, unchanged rows skipped |

For scale: a 60 Hz frame budget is 16.7 ms. The icon lookup alone was more than twice
that, on its own, before anything was drawn.

**You can quit an entire application, not just a process.** Activity Monitor lists
helper processes as separate rows, so quitting an app that spawns a dozen of them is a
dozen separate decisions — and killing the wrong helper leaves the app running in a
broken state. Runwell groups processes by the application that owns them and acts on
the whole group. Both quit and force quit report **per process** what actually
happened: terminated, refused by policy, or asked and did not comply. No blanket
"done" over a partial failure.

Termination is also guarded rather than trigger-happy. Critical system processes are
refused outright, root-owned and other users' processes are never touched, helper
processes warn that they belong to a parent app, and force quit always requires an
explicit confirmation. Runwell will not offer to kill Runwell.

**Sampling adapts to what you are doing.** Every 2 seconds with the window open,
5 in the menu bar, 10 when idle on battery, 15 in Low Power Mode, and genuinely zero
when you switch recording off — a real paused state, not just the slowest cadence. A
battery monitor that flattens your battery is a contradiction, so the cost of
monitoring is itself a setting.

## What it does

- **Live application list** — energy, CPU, memory and disk per app, grouped by
  application rather than scattered across helper processes.
- **History** — what drained your battery earlier today, yesterday, or over the past
  week, with battery sessions grouped by day.
- **Insights** — plain-language notices when something is genuinely worth knowing:
  an app holding a power assertion while the screen is off, an unusual wakeup rate
  in the background, sustained energy use you did not ask for.
- **Uninstall** — remove an application and the support files it leaves behind.
  Everything goes to the Trash, never straight to `unlink`, and support files are
  matched by exact bundle identifier only, so it would rather miss a leftover than
  delete a file it cannot prove belongs to the app.
- **Diagnostics** — what this specific Mac can and cannot report, probed at launch
  rather than assumed.
- **Menu bar** — a compact live summary, sampled less often than the main window.

## Privacy

Everything stays on your Mac. No account, no analytics, no network calls, no
telemetry. History is a local SQLite database in
`~/Library/Application Support/Runwell/`, and "Delete All History" genuinely deletes
it — the file shrinks, rather than the rows merely being hidden.

Bundle identifiers and display names are stored. Executable paths are redacted before
they reach a row, and command-line arguments are never collected at all.

## Install

Download the latest signed `.dmg` from
[Releases](https://github.com/meerbahadin/runwell/releases), open it, and drag
Runwell to Applications. The app and the disk image are both notarized, so Gatekeeper
will open it without complaint.

Requires **macOS 15 or later**. Universal — Apple silicon and Intel.

## Build from source

```bash
git clone https://github.com/meerbahadin/runwell.git
cd runwell
swift test          # 109 tests
Scripts/build-app.sh # local dev build -> build/Runwell.app
```

`build-app.sh` produces an ad-hoc signed, host-architecture build with the bundle id
`com.runwell.Runwell.dev`, so it runs alongside a release install without sharing its
database. It is not distributable: Gatekeeper rejects ad-hoc signatures on any other
Mac, and the user sees "Runwell is damaged" with no way around it.

For a distributable build you need an Apple Developer Program membership, a
Developer ID Application certificate, and a notarytool keychain profile:

```bash
Scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
```

That builds a genuinely universal binary, signs it with the hardened runtime,
notarizes the app *and* the disk image separately, and refuses to continue if the
result is not actually universal.

## Architecture

Swift Package Manager, two targets:

- **`RunwellKit`** — collectors, metric engine, application grouping, insight rules,
  SQLite persistence and retention. No UI, no AppKit dependency in the core, fully
  tested.
- **`Runwell`** — the SwiftUI app: views, the menu-bar extra, background service and
  notifications.

Storage is tiered: raw samples for 2 hours, per-minute totals for 7 days, 15-minute
totals for 30 days, with a size ceiling above that. The 15-minute tier is rolled up
from the minute tier during retention rather than written live, and rows are keyed by
a short digest rather than a filesystem path. Together those changes took a measured
76 MB/day down to 14.6 MB/day over three days of real use, with the rolled-up tier
matching the minute tier exactly to the nanojoule.

## Known limitations

- **~67% process coverage**, as above. Permanent, not a bug.
- **No GPU metrics.** Both collectors are gated off pending a stable public
  interface. Two permanent "unavailable" rows would be worse than their absence.
- **Sandboxed apps' leftovers are partly invisible to the uninstaller.** macOS
  protects other applications' container data, so some support files cannot be seen.
  Runwell lists only what it actually found and says so, rather than requesting Full
  Disk Access — an uninstaller is not worth that privilege.
- **The app layer has no automated tests.** `RunwellKit` — the collectors, metric
  engine, grouping, insight rules and database — is covered by 109 tests.
  `AppEnvironment`, `BackgroundService` and `NotificationService` are not, and are
  covered only by daily use: the author has run Runwell as their actual battery
  monitor since the first build, and 1.0.1 shipped after ten continuous days of it.
  That catches what someone actually does; it does not catch what changes when
  someone edits the code, which is what the tests are for.

## Contributing

Issues and pull requests are welcome. One rule above the rest: **do not make the app
claim something it did not measure.** A fabricated zero, a silently coalesced
unavailable value, or a confident average over no samples will be rejected however
neat the diff is.

## License

[MIT](LICENSE) © Meer Bahadin
