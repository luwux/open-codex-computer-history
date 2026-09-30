# Recorder performance

The recorder observes other apps through the macOS Accessibility (AX) API.
Every AX request is a synchronous IPC answered on the **target app's main
thread**, so the recorder's real cost is CPU time and energy spent inside the
apps being observed (and, for Chromium/Electron, their helper processes),
plus wakeups. Latency matters only as a proxy for that work.

## Method

`open-history bench <bundle-id | pid:N> [iterations] [--json FILE]` runs each
recording path against a live app and reports, per iteration:

| Column | Meaning |
| --- | --- |
| `ax` | AX requests issued (each one runs on the target's main thread) |
| `tgt-cpu` | user + system CPU of every process whose executable is inside the app bundle (`proc_pid_rusage`, `RUSAGE_INFO_V6`) |
| `net-cpu`, `net-mJ` | the same minus the app's idle background rate over the same wall time (the `idle 1 s` row) |
| `tgt-mJ` | energy of those processes (`ri_energy_nj`, falling back to `ri_billed_energy`) |
| `wakes` | interrupt + package-idle wakeups of those processes |
| `self-cpu` | the recorder's own CPU |

`scripts/perf-bench.sh [--json] [--iterations N] [--rows N] [bundle-id ...]`
makes this reproducible: it builds release binaries, launches the repo's
fixture app in the background with an N-row (default 2000) mailbox-like list
(`OPEN_HISTORY_FIXTURE_ROWS`), benches it, then benches any running apps passed
as arguments. `--json` writes `docs/perf-results/<UTC timestamp>.json`. The
fixture result depends only on the machine, not on the user's apps; real-app
rows vary with what those apps show and do (Dia and Claude burn 0.3–1.3 CPU
seconds per second at idle on the measuring machine, so their `net` columns
are noisy).

Paths measured:

- `context` — app, focused window title/URL, focused element: what typing,
  selection, and window-change checks now read.
- `browser URL search (cold)` / `(cached)` — browser page URL lookup.
- `selection probe` — one request telling a caret move from a selection.
- `tree capture` — context + window tree (window change, click, shortcut,
  submit when not throttled).
- `tree, no visible/cap/budget` — the same traversal without visible-rows,
  per-node child cap, or time budget, to show what those bounds save.

Regression guards that need no AX permission live in
`collector/Tests/HistoryCoreTests/AXCaptureSettingsTests.swift`: event kinds
that carry trees (typing and selection never do), the event-tap mask
(no moved/dragged/flags/scroll/keyUp events), capture throttling, and config
decoding.

## Results (Apple silicon, macOS 27, 2026-09-29)

Before = code at `c992047` plus the counting wrapper; after = this branch.
Per single snapshot/capture, 10 iterations (Mail before: 3).

| Target | Path | AX calls | Target CPU ms | Net energy mJ | Wall ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Fixture, 2000 rows | before: full snapshot | 5622 | 228 | 969 | 266 |
| | after: tree capture | 75 | 17 | 53 | 15 |
| | after: context only | 3 | 0.4 | 0.2 | 0.7 |
| Mail | before: full snapshot | 5629 | 5615 | 2380 | 6563 |
| | after: tree capture | 280 | 58 | 26 | 77 |
| | after: context only | 3 | 0.35 | 0.1 | 0.6 |
| Dia | before: full snapshot | 2696 | 84 (net 21) | 169 | 50 |
| | before: light (URL BFS) | 16–848 | — | — | 2–18 |
| | after: tree capture | 254 | 26 (net 4) | 61 | 15 |
| | after: context only | 3 | 1.7 (net 0.9) | 0.3 | 0.5 |
| Claude | before: full snapshot | 7463 | 123 (net 61) | 408 | 136 |
| | after: tree capture | 742 | 49 (net 31) | 206 | 50 |
| | after: context only | 3 | 0.4 (net 0.25) | 1.2 | 0.3 |

Tree content is unchanged for Claude and Dia (Dia gains a few nodes the old
`CFHash`-based visited set dropped as collisions). Tables and lists now show
their visible rows instead of the first rows of the whole model.

### AX cost per event (requests on the target's main thread)

| Event | Before | After |
| --- | --- | --- |
| Printable keystroke | 1 full snapshot per key (Dia ≈2.7k, Claude ≈7.5k, Mail ≈5.6k) | 0; one context read (3) when a burst starts or focus may have moved, one (3) when the burst flushes |
| Return | full snapshot + another 0.15 s later | flush context reused + tree (throttled) + 1 selection probe |
| Shortcut | full snapshot | context + tree (throttled) |
| Click | full snapshot at mouse down **and** mouse up | 1 at down (element under pointer) + 4 at up; tree at most every 2 s per unchanged window |
| Drag | 2 full snapshots | click cost + 1 batch for the origin element |
| Window/title change | full snapshot per notification | 3 (context); tree only when the window signature changed |
| `AXFocusedUIElementChanged` | full snapshot, result discarded | 0 |
| `AXTitleChanged` from page elements | full snapshot | 0 (only the focused window's title is considered) |
| `AXValueChanged` (non-terminals) | full snapshot every 0.1 s while content changes | not observed |
| `AXValueChanged` (terminals) | full snapshot per change | one context + tree when output settles |
| `AXSelectedTextChanged` (caret) | full snapshot | 1 |
| Paused | observers, web AX enabling, and a full snapshot on every app switch; control polled at 2 Hz | nothing: event tap disabled, observer removed, media polling stopped, control file watched |

Recorder process: paused, 0.9 ms CPU and 1 wakeup in 15 s; running while the
user worked, 29 ms CPU and 5 wakeups in 10 s.

## Mail diagnosis

One full snapshot of Mail took 6.6–8.6 s and 5.6 s of Mail CPU. Profiling
per attribute showed every request against a message-list element costing
2–3 ms (up to 86 ms): the message `AXTable` has 1,264 children (1,263 rows)
of which 10 are visible. AppKit creates row views for accessibility clients
on demand, so enumerating off-screen rows made Mail build views for them, and
each of the ~10 attributes per node paid that again. The fix is generic:
containers listed in `visibleChildrenAttributeByRole` (tables and outlines →
`AXVisibleRows`, lists and grids → `AXVisibleChildren`) contribute only their
visible children; children per element are capped (200); a capture stops
after 250 ms; and each request times out after 250 ms instead of the system
default 6 s. With batching (one `AXUIElementCopyMultipleAttributeValues` per
node) the unbounded traversal still costs Mail 2 s of CPU, so the visible-rows
rule is what matters. All four limits are overridable under `axCapture` in
`config.json`.

## Remaining ideas

- **Chromium/Electron accessibility mode.** The recorder sets
  `AXManualAccessibility` on every Chromium/Electron app it sees and never
  clears it, so those apps keep maintaining a full AX tree (renderer → browser
  serialization on every DOM change, e.g. streaming chat output) even in the
  background. A quick A/B on Claude (50 processes, noisy) showed 502–536 ms/s
  with it off vs 538–632 ms/s on: suggestive, not conclusive. Clearing it on
  deactivation would save that but can break other assistive clients, and
  re-enabling costs a tree rebuild per activation. Worth a controlled test.
- **Claude trees** still take ~740 requests: the web area is deeply nested
  generic groups. Lower web depth/traversal limits or skipping attribute-free
  subtrees would cut it, at some loss of content.
- **Large values.** `AXValue` of big text areas (editors, terminal buffers) is
  transferred whole and truncated to 500 characters afterwards;
  `AXNumberOfCharacters` + `AXStringForRange` would bound it.
- **Off-main-thread capture.** Captures run on the recorder's main thread
  inside the event-tap callback (bounded by the 250 ms budget). Moving them to
  a serial queue would not save energy but would keep the tap responsive.
- **Mock AX layer.** Per-path AX budgets are measured by the bench, not by
  unit tests; a protocol over the AX calls would let tests assert them.
