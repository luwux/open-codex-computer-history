# Chromium / Electron accessibility mode: cost, toggling, and alternatives

Measured 2026-09-29 on an Apple M5 Max running macOS 27.0. The apps were Dia
1.50.1 (ArcCore / Chromium 154.0.8037.58), Claude desktop 2.9939.4 (Electron
44.4.3), and a separate throwaway Google Chrome 154.0.8037.58 instance with a
temp profile and a synthetic page. Every number below says whether it was
**measured** or **inferred**.

Reproduce with `scripts/perf/ax-mode-energy.sh` (see the end of this file).

## TL;DR

- AX mode costs real CPU and energy. The clearest measurement comes from the
  controlled Chrome instance on a page that keeps updating: **+51 mW
  (+132 %) energy, +2 CPU points (+22 %), +8 wakeups/s, and about +40 MB**
  with AX on. In Claude desktop, AX on measured about **+20 mW** in the
  renderer and main processes (renderer CPU +1.7 points). **Measured.**
- Setting `AXManualAccessibility` back to `false` turns AX off in Electron
  (Claude). The web AX tree went from about 1,250 nodes to 0 immediately.
  Setting `AXEnhancedUserInterface=false` turns it off in Chrome. **Measured.**
  The value you read back is **not** a reliable state check. See Q2.
- **Dia behaves differently.** Setting `AXEnhancedUserInterface` returns
  `-25208` (not implemented), and the getter for `AXManualAccessibility`
  returns `-25205`. Neither attribute changed Dia's exposed web AX tree in
  either direction. Dia's page tree was present before, during, and after
  every toggle. Dia's AX mode is therefore held by something other than these
  attributes, and only a Dia relaunch clears it. **Measured.** Why it is held
  is **inferred**; see "Latching" below.
- **Reading `AXRole` of the application element latches basic AX mode for the
  rest of the process's life** in Chrome, Electron, and ArcCore (the
  `-[BrowserCrApplication accessibilityRole]` override). Setting either
  attribute to false does not undo it. **Measured** in Chrome and **confirmed
  in source.**
- **The recorder is not the only AX client.** A freshly launched background
  Chrome had `AXEnhancedUserInterface=1` set by some other process within
  about 10 s, with no action from us. The candidates are `cua-driver` and
  Raycast, whose binaries both reference `AXManualAccessibility` and
  `AXEnhancedUserInterface`. Hammerspoon is also running. **Measured**, but
  not attributed to one process.
- Cheaper sources exist. For Dia, AppleScript gives the URL and title of the
  active tab at a median of 33 ms per call and roughly 2–10 ms of Dia CPU
  (measured). Dia's `execute javascript` needs a relaunch with
  `--enable-applescript-javascript`. Dia already runs with
  `--remote-debugging-port=9222`, so CDP `Runtime.evaluate` can return page
  text without AX mode (inferred; not measured on user tabs). Claude desktop
  has no AppleScript dictionary, and its window title is just "Claude".

## Q1: How expensive is AX mode?

### Sources

- Chrome team, [Improving the performance of Chromium accessibility](https://developer.chrome.com/blog/chromium-accessibility-performance)
  (2024-08). About 5–10 % of users have AX code enabled, mostly by accident,
  through password managers, antivirus, and other tools that use platform AX
  APIs. The degradation in core metrics is described as "quite high", and an
  "Auto Disable Accessibility" experiment was run.
- Electron [`app.setAccessibilitySupportEnabled`](https://www.electronjs.org/docs/latest/api/app)
  warns: "Rendering accessibility tree can significantly affect the
  performance of your app. It should not be enabled by default."
- Chromium [How Chrome Accessibility Works](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/accessibility/browser/how_a11y_works_2.md).
  With AX on, the renderer builds and serializes a tree, and the browser
  process keeps a cached copy. That copy duplicates DOM and layout state
  (memory), and every DOM or layout change produces tree updates over IPC
  (CPU and wakeups).
- `ui/accessibility/ax_mode.h`. `kAXModeBasic` is `kNativeAPIs|kWebContents`.
  `kAXModeComplete` adds `kInlineTextBoxes|kExtendedProperties`. The
  `AXEnhancedUserInterface` / `AXManualAccessibility` path requests
  `kAXModeComplete|kFromPlatform|kScreenReader`, which is the most expensive
  bundle.
- Side effects of `AXEnhancedUserInterface`: AppKit animates programmatic
  `AXPosition`/`AXSize` writes (about 200 ms), which makes window managers
  sluggish or leaves windows at the wrong frame. Rectangle logs "AXEnhancedUserInterface was enabled, will disable before resizing"
  ([Rectangle #912](https://github.com/rxhanson/Rectangle/issues/912)).
  Phoenix ([PR #310](https://github.com/kasper/phoenix/pull/310)) and yabai
  apply the same workaround. Firefox avoided the attribute for this reason
  ([bug 1664992](https://bugzilla.mozilla.org/show_bug.cgi?id=1664992)) and
  instead enables AX when the application's role is read.

### Measurements

Every measurement uses `proc_pid_rusage(RUSAGE_INFO_V6)` summed over the main,
GPU/utility, and renderer processes. Deltas are taken every 5–10 s so that
processes starting or exiting mid-window are still counted. Energy is
`ri_energy_nj`. `ri_billed_energy` stays near 0 for renderers because it only
covers voucher-billed work, so it is not a usable total. 1 J per 60 s ≈
16.7 mW.

**A. Controlled Chrome instance, ABAB with 4 × 60 s off and 4 × 60 s on,
toggling `AXEnhancedUserInterface`.** The page has 3,000 rows (about 15k AX
nodes and 810k characters), a 100 ms text tick, and a chat-like prepend every
500 ms. The window was visible in the background. Values are medians, with
[min–max] per 60 s window. The off and on ranges do not overlap.

| process | off energy J/60 s | on energy J/60 s | off CPU % | on CPU % | wakeups/s off → on | footprint MB off → on |
|---|---|---|---|---|---|---|
| renderer | 1.60 [1.53–2.04] | 4.18 [3.91–4.37] | 5.32 [5.23–5.48] | 6.78 [6.64–6.81] | 29.6 → 37.6 | 185 → 196 |
| browser main | 0.01 [0.01–0.58] | 0.44 [0.42–0.64] | 0.07 | 0.41 | 1.4 → 1.1 | 133 → 162 |
| GPU + utility | 0.72 [0.70–0.98] | 0.79 [0.76–0.88] | 3.38 | 3.54 | ≈ | ≈ |
| **sum** | **2.33** | **5.41** (+3.1 J/min ≈ **+51 mW**) | 8.8 | 10.7 | | **+40 MB** |

The enable transition is a separate one-time cost. In the first 20 s after
turning AX on, the Chrome browser process used 2.35 J, against about 0.04 J
for 20 s at steady state. **Measured.**

Basic mode, which is latched by reading the application's `AXRole`, cost less
than the full EUI mode. Renderer CPU went from 5.2 % to 6.0–6.9 %, browser
main from 0.06 % to 0.3–0.5 %, and footprint from 135 to 149 MB. Renderer
energy (1.5–1.9 J/60 s) stayed inside the noise. **Measured**, 2 × 60 s.

**B. Claude desktop, ABAB with 4 × 60 s each, toggling `AXManualAccessibility`.**
The user was mostly idle with CodeZ frontmost, but Claude was streaming this
agent conversation, so the noise is high.

| process | off energy J/60 s | on energy J/60 s | off CPU % | on CPU % |
|---|---|---|---|---|
| renderer | 8.09 [7.50–14.95] | 9.27 [8.95–14.30] | 17.24 [15.72–17.81] | 18.94 [17.81–19.83] |
| main | 0.08 [0.05–4.98] | 0.16 [0.16–0.48] | 0.20 | 0.35 |
| GPU + utility | 10.32 [7.04–20.02] | 12.06 [9.60–18.68] | 25.9 | 26.9 |

The renderer and main processes show about +1.3 J/min (≈ +21 mW) and +1.8
CPU points. The GPU difference falls inside the noise. Footprint showed no
measurable difference. An earlier 3 × 5 min A/B/C run with Claude frontmost
and actively streaming showed no resolvable difference at all.

**C. Dia, same ABAB.** There was no difference in any metric; for example,
renderers were 86.56 % off and 86.55 % on. As expected, the toggles do not
change Dia's AX state; see Q2. Dia itself is expensive regardless of AX: its
49 renderers use 35 J/min (≈ 580 mW, about 86 % of one core), and GPU+utility
uses 15 J/min (≈ 250 mW). Two renderers account for most of that (88 and 43
CPU-minutes over roughly 23 h). How much of Dia's load comes from AX mode
**cannot be measured without relaunching Dia**, and relaunching was out of
scope.

**Inferred scale for Dia.** Dia runs 22 pages and 49 renderers. If AX is on
across the whole browser, as the page web area that was always exposed
suggests, every visible tab that is changing pays an overhead similar to case
A, and the browser process holds a tree copy for every tab. The overhead
therefore grows with how many tabs are active.

## Q2: Does setting the attribute back to false disable AX? Is there auto-disable?

These are the relevant current Chromium sources (`main`, 2026-09):

- `chrome/browser/chrome_browser_application_mac.mm`:
  - `AXEnhancedUserInterface=true` goes through a 2 s debounce and then creates
    a scoped mode of `kAXModeComplete|kFromPlatform|kScreenReader`.
    `false` resets that scoped mode, which turns AX off.
  - `-accessibilityRole` on NSApp: when no mode is active, reading it creates
    `_scoped_accessibility_mode_general = kAXModeBasic|kFromPlatform`. With
    the `SonomaAccessibilityActivationRefinements` feature on it would be
    `kNativeAPIs` instead, but that feature is off by default. **Nothing ever
    resets this mode.** It is a one-way latch for the life of the process.
- Electron `shell/browser/mac/electron_application.mm` copies the same logic.
  Setting `AXManualAccessibility` goes through the same debounced path, so
  `false` resets it. The getter returns
  `GetAccessibilityMode() == kAXModeComplete`. Because the actual mode also
  carries `kFromPlatform|kScreenReader`, **the getter reads 0 even while AX is
  on**. Measured: Claude read `AXManualAccessibility=0` while exposing about
  1,250 web AX nodes.
- Auto-disable: the old `AutoDisableAccessibility` heuristic (3+ input events
  over 30 s with no AX API use; see [VS Code #162331](https://github.com/microsoft/vscode/issues/162331))
  is **gone** from `browser_accessibility_state_impl.cc`. What remains is
  `kProgressiveAccessibilityPhase2` (`content/common/features.cc`, **disabled
  by default**). It drops AX for WebContents that have been hidden for more
  than 5 minutes beyond the 5 most recently hidden. It is also skipped
  entirely when a screen reader is active, and the
  `AXEnhancedUserInterface` / `AXManualAccessibility` path sets
  `kScreenReader`. **In practice nothing turns AX off automatically.**

Empirical results. The web AX tree was counted by walking the tree and
counting nodes under `AXWebArea` elements. That walk never reads the
application element's role.

| app | action | web AX nodes |
|---|---|---|
| Claude | `AXManualAccessibility=true`, wait 4 s | 1,225–1,504 |
| Claude | `=false` (4 s and 24 s later) | 0 |
| Chrome (fresh) | read app `AXRole` once | 0 → 15,107 (latched) |
| Chrome | then EUI true → false | still 15,107 (latch survives) |
| Chrome (other fresh instance) | EUI true → false | tree → 0 |
| Dia | `AXManualAccessibility` true or false, EUI true or false | 124, unchanged in every state (page web area always exposed) |

Other observations:

- A freshly launched background Chrome already had
  `AXEnhancedUserInterface=1` and a full web tree within about 10 s. We had
  not touched it. Once we set it to false, nothing re-set it during a 60 s
  watch.
- Our own walks, multi-attribute reads (`AXFocusedWindow`,
  `AXFocusedUIElement`, `AXURL`, `AXDocument`), observer registration, and
  window `AXTitle` reads did **not** enable AX in a Chrome instance where AX
  was off.
- Dia's state could be latched by an app-role read from any AX client, or by
  ArcCore's own logic. ArcCore contains the same `_AXEnhancedUserInterfaceRequests`
  and `accessibilityRole` code. Which one applies is **inferred**, not proven.

## Q4: Getting URL, title, and page text without AX mode

| source | what you get | cost | caveats |
|---|---|---|---|
| Dia AppleScript `get {URL, title} of active tab of front window` | URL and title of the active tab | **median 33 ms, p90 39 ms** latency. Dia main CPU was about 2–10 ms per call (two runs of 150 calls; Dia main's idle noise is large). **Measured.** | Needs the Automation (Apple Events) permission. Use an in-process `NSAppleScript`, compiled once, or raw Apple Events rather than spawning `osascript`. |
| Dia `execute tab javascript "…"` | page text (`document.body.innerText`) | not measured | **Fails unless Dia is launched with `--enable-applescript-javascript`** (error -10006). Chrome's equivalent needs "Allow JavaScript from Apple Events". |
| Dia CDP on port 9222 (already enabled for the user's tooling) | `/json/list` returns URL and title for all 22 pages; `Runtime.evaluate` returns page text | `/json/list` took **25 ms** (measured). `Runtime.evaluate` was not measured, to avoid touching user tabs. | Any local process can drive the browser with every logged-in session. The active tab is not marked, so match it against the AppleScript URL. |
| Arc / Chrome AppleScript `URL of active tab of front window` | URL and title | similar to Dia (inferred) | Same Automation permission. |
| Claude desktop | nothing via AppleScript (no sdef). Window `AXTitle` is always "Claude". | — | Claude Code sessions are local transcripts under `~/.claude/projects/*.jsonl`. claude.ai chats live only on the server or in the web view. |
| AX burst: enable, wait about 3 s, walk, disable | page text (Claude: about 1,250–1,500 nodes and 7–8k characters of static text; walk took 0.12 s) | Three paired 20 s windows with and without a cycle showed **no difference above Claude's noise** (±4 J per 20 s while streaming). The Chrome transition cost on a 15k-node page was about 2 J browser-side. **Measured.** | Chromium debounces "on" by 2 s. The capture must **never** read the application's `AXRole`, which latches basic mode permanently. In Dia the burst is pointless because the attributes have no effect. |

## Q5: Recommendation

1. **Stop leaving AX mode on in the recorder.** Delete the fire-and-forget
   `enableWebAccessibility` (it sets true and never sets false) and never set
   `AXEnhancedUserInterface`. It is the most expensive bundle, it disables
   progressive auto-disable, and it breaks window managers.
2. **Dia: record the URL and title via AppleScript** when Dia becomes
   frontmost and on the native window `AXTitleChanged` notification, which
   does not need web AX. At most, poll every few seconds while Dia is
   frontmost. That costs about 33 ms latency and a few ms of CPU per event.
   For page text, prefer **CDP `Runtime.evaluate`** (bounded
   `innerText.slice(0, N)`) once per URL after a dwell of about 5 s, because
   port 9222 is already open. Otherwise relaunch Dia with
   `--enable-applescript-javascript` and use `execute javascript`.
3. **Claude desktop: use an AX burst.** Set `AXManualAccessibility=true`,
   wait 3 s, capture a bounded walk, then set it to `false` immediately. Do
   this only on dwell or conversation change, rate-limited to once every few
   minutes. Take Claude Code session text from `~/.claude/projects` instead.
4. **Never read `kAXRoleAttribute` on the application element** of a
   Chromium or Electron app, and audit hit-test and parent walks that could
   reach it.
5. **Other AX clients re-enable AX on their own** (cua-driver, Raycast,
   possibly Hammerspoon). Pausing the recorder does not guarantee that AX is
   off. To actually clear Dia's AX mode, the user has to relaunch Dia, ideally
   while those tools are not attaching to it. Relaunching is the user's
   decision.

## Reproduce

```sh
# alternates off/on in N equal windows, sums proc_pid_rusage over all of the
# app's processes, prints medians and ranges, and always restores AX to off
scripts/perf/ax-mode-energy.sh --bundle com.anthropic.claudefordesktop --windows 4 --seconds 60 --probe
scripts/perf/ax-mode-energy.sh --bundle com.google.Chrome --attrs eui --windows 4 --seconds 60
```

Caveats:

- Keep the target window visible. Chrome throttles occluded or hidden pages,
  often to near-zero CPU, and AX updates stop with them.
- The noise depends on what the user is doing, so report the medians and
  ranges, not a single window.
- The attribute getters do not show the real state, so use `--probe`. A probe
  walk of a large tree costs up to about 0.75 s of CPU.

State at the end of this investigation: Claude
`AXManualAccessibility=false`, with 0 web AX nodes. Dia
`AXManualAccessibility=false` and `AXEnhancedUserInterface=0` as far as the
setters go, but Dia's page AX tree is still exposed and needs a relaunch to
clear. The throwaway Chrome instance was quit.
