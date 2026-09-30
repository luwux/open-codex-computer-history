# Open Codex Computer History

A clean-room, open implementation of the event-stream architecture behind
Computer History in the ChatGPT/Codex desktop app.

It records macOS interaction events through Accessibility and Core Graphics. It
does not take screenshots, record video, or capture audio.

## Status

Version `0.2.0` is a working clean-room reference implementation:

- Native Swift recorder for app/window changes, clicks, drags, text-input bursts,
  submits, shortcuts, terminal changes, and selections.
- Recovered nested `EventStreamRecord` schema with app, window, mouse, keyboard,
  selection, AX tree, and diagnostic payloads.
- Rotating JSONL segments compatible with the observable Computer History
  layout: `events.jsonl` and `metadata.json`, with suppressed activity counted
  but not persisted.
- App/domain include and exclude policies, private-browsing filtering, secure
  text-field filtering, and 48-hour event retention.
- Original-name MCP tools for pause, resume, status, get settings, and replace
  settings, plus search, summarization, and deletion tools.
- UTC-aligned 10-minute and 6-hour summary pipeline with persistent bucket
  deduplication, single-instance locking, and a failure circuit breaker.
- Ephemeral `codex exec` summarizer that writes local Markdown memories.
- Read-only IPC inspector for the installed proprietary service.
- Native-compatible open IPC server, a timeline MCP View, a SwiftUI menu-bar
  app, and opt-in LaunchAgent packaging.
- A signed synthetic Fixture App, deterministic AX/CGEvent driver, and
  structural JSONL comparator for the final original-vs-open recording audit.

This project does not contain OpenAI source code, signing assets, credentials, or
private service endpoints. See [docs/reverse-engineering.md](docs/reverse-engineering.md).
Recovered wire and JSON contracts are documented in
[docs/recovered-protocol.md](docs/recovered-protocol.md).
The requirement-by-requirement evidence matrix is in
[docs/completion-audit.md](docs/completion-audit.md).
The user-authorized original event-stream comparison is in
[docs/original-live-parity.md](docs/original-live-parity.md).

## Architecture

```text
macOS AXObserver + CGEventTap
             |
             v
       privacy policy
        /           \
 events.jsonl   suppressed count
        |
        v
 ephemeral codex exec summarizer
        |
        v
 memories/resources/*.md
        |
        v
local MCP tools
```

## Package and install

Build the ad-hoc signed menu-bar application:

```bash
npm run app:package
```

The result is:

```text
dist/Open Computer History.app
```

Opt in to local launch services for the menu, native IPC, summary pipeline, and
MCP endpoint:

```bash
npm run install:local
```

This writes user LaunchAgents and is not run automatically. The installed MCP
endpoint is `http://127.0.0.1:3317/mcp`.

Remove services while preserving history data:

```bash
npm run uninstall:local
```

## Requirements

- macOS 14 or newer
- Swift 5.10 or newer
- Node.js 22.22 or newer
- Codex CLI, only for AI-generated summaries

## Build

```bash
npm install
npm run collector:build
npm run typecheck
npm test
```

For a release collector:

```bash
swift build --package-path collector -c release
```

## Permissions

The recorder requires Accessibility and Input Monitoring. It does not require
Screen Recording.

```bash
collector/.build/debug/open-history permissions
```

Enable the built `open-history` binary in:

- System Settings > Privacy & Security > Accessibility
- System Settings > Privacy & Security > Input Monitoring

Verify:

```bash
collector/.build/debug/open-history status
```

Browser page URLs and titles are read through each browser's scripting
dictionary, which needs **Automation** permission per browser. macOS asks the
first time a supported browser is frontmost while recording (the app bundle
declares `NSAppleEventsUsageDescription`); the recorder asks at most once per
browser per run. If you decline, URLs fall back to the accessibility lookup
and you are not asked again; allow it later under System Settings > Privacy &
Security > Automation. To grant or check it from a terminal:

```bash
collector/.build/debug/open-history browser-tab [bundle-id]
```

If you sign the app with the hardened runtime, also add the
`com.apple.security.automation.apple-events` entitlement.

## Record

Normal text capture matches the official default:

```bash
npm run collector:record
```

Record for a bounded smoke test:

```bash
collector/.build/debug/open-history record --duration 30
```

To opt out of ordinary text persistence, set `"captureText": false` in
`config.json`. Secure fields and private browsing are always suppressed.

The CLI can explicitly force text capture:

```bash
collector/.build/debug/open-history record --capture-text
```

Password fields, excluded apps/domains, and private-browsing windows are always
suppressed and their event bodies are not persisted.

Data is stored under:

```text
~/.open-codex-computer-history/
  config.json
  segments/<timestamp>-<id>/
    events.jsonl
    metadata.json
  memories/resources/*.md
```

Override the root with `OPEN_COMPUTER_HISTORY_HOME`.

## Configure

Copy [config.example.json](config.example.json) to:

```text
~/.open-codex-computer-history/config.json
```

Policies support either excluding listed sources or including only listed
sources.

Accessibility reads are answered on the observed app's main thread, so the
recorder bounds them. Typing reads the focused element once per burst; AX
trees are captured only for events that carry them, at most every
`minimumTreeIntervalSeconds` per window while its title and URL are unchanged
(skipped events carry no `ax`). Tables, outlines, lists, and grids contribute
only their visible rows. The optional `axCapture` object in `config.json`
overrides the defaults:

```json
"axCapture": {
  "minimumTreeIntervalSeconds": 2,
  "treeTimeBudgetMilliseconds": 250,
  "messagingTimeoutMilliseconds": 250,
  "maximumChildrenPerElement": 200,
  "visibleChildrenAttributeByRole": {
    "AXTable": "AXVisibleRows",
    "AXOutline": "AXVisibleRows",
    "AXList": "AXVisibleChildren",
    "AXGrid": "AXVisibleChildren"
  }
}
```

### Web pages: captured by default and opt-in

Chromium and Electron apps build a web accessibility tree only while an
assistive client asks for it, and keep paying for it on every page change
until they quit: measured about +51 mW (+130 %) in a busy Chrome tab and
about +21 mW in the Claude desktop app
([docs/perf/chromium-ax-mode.md](docs/perf/chromium-ax-mode.md)). The
recorder therefore never switches that mode on by default and never reads
attributes of an app's application element.

| Source | Default | What it records | Cost / permission |
| --- | --- | --- | --- |
| Window title, focused element, native AX tree | on | as before; Chromium/Electron pages contribute only what the app already exposes | Accessibility |
| Browser URL and tab title (Apple Events) | on (`browserScripting`) | page URL and title for Chrome, Chromium, Brave, Edge, Vivaldi, Dia, Arc, Safari; incognito windows (window `mode`) are suppressed | one Apple Event per property on window or title change (Dia: 13–38 ms for URL and title); Automation per browser |
| Browser URL (accessibility fallback) | on | address bar or web-area URL when scripting is unavailable or denied | Accessibility |
| Page text (Chrome DevTools Protocol) | **off** (`pageText`) | `web.page_content`: main-content text of a page you stayed on | one read per URL; the browser must run with `--remote-debugging-port` |
| Web accessibility mode | **off** (`webAccessibility`) | full web AX trees in Chromium/Electron apps | the energy cost above |

Electron apps without a scripting dictionary (for example chat apps) are
recorded like any other app: window, focus, and the native tree.

```json
"browserScripting": {
  "enabled": true,
  "timeoutMilliseconds": 500,
  "refreshSeconds": 30,
  "excludedBundleIdentifiers": []
},
"pageText": {
  "source": "off",
  "port": 9222,
  "bundleIdentifiers": [],
  "dwellSeconds": 5,
  "maxCharacters": 8000,
  "recaptureMinutes": 30,
  "timeoutMilliseconds": 2000
},
"webAccessibility": "off"
```

- `browserScripting` reads `URL`, `title` (and `mode` where the dictionary
  has it) of the active tab of the front window, cached per window and title
  and re-read after `refreshSeconds`; never per keystroke.
- `pageText` with `"source": "cdp"` reads a page once its URL has been
  unchanged for `dwellSeconds` and was not read in the last
  `recaptureMinutes`: it lists `http://127.0.0.1:<port>/json/list`, connects
  to the one page target with that URL, sends a single read-only
  `Runtime.evaluate` (text of `article`, `main`, or `[role=main]`, else
  `body`, truncated to `maxCharacters`), and disconnects. `bundleIdentifiers`
  must name the browser you started with `--remote-debugging-port=<port>`;
  empty reads nothing. Private windows, excluded apps and domains, secure
  input, and `"captureText": false` are never read. Note that a remote
  debugging port lets any local process control that browser; enabling it is
  your decision. Check the setup with
  `open-history page-text [bundle-id]`.
- `webAccessibility` is `"off"` or `"manual"` (or
  `{"mode": "manual", "bundleIdentifiers": [...]}` to limit it). Manual sets
  `AXManualAccessibility` (never `AXEnhancedUserInterface`) on activation and
  clears it when recording pauses or stops.

`open-history bench <bundle-id> [iterations]` reports what each recording path
costs a running app: accessibility requests, and CPU time, energy, and wakeups
of the app's processes and of the recorder.

## MCP

Start the local MCP server:

```bash
npm run dev
```

The endpoint is `http://localhost:3000/mcp`. Available tools:

- `computer_history_pause`
- `computer_history_resume`
- `computer_history_status`
- `computer_history_get_settings`
- `computer_history_update_settings`
- `computer-history-status`
- `get-recent-computer-history`
- `search-computer-history`
- `summarize-computer-history`
- `clear-computer-history`
- `show-computer-history`
- `delete-computer-history-item` (app-private)

Example terminal validation:

```bash
npx mcp-use client connect history http://localhost:3000/mcp
npx mcp-use client history tools list
npx mcp-use client history tools call computer-history-status
npx mcp-use client history tools call get-recent-computer-history \
  '{"hours":1,"limit":20,"includeText":false}'
```

## Summaries

`summarize-computer-history` starts a temporary, read-only Codex session over
explicit event files. The raw event files are processed by the configured Codex
provider when this tool is invoked.

Generated Markdown memories remain local under `memories/resources/`.

Run one completed summary tick:

```bash
npm run pipeline:once
```

Run the persistent bucket scheduler:

```bash
npm run pipeline:run
```

The summarizer uses the recovered isolated Codex configuration and opens a
backoff circuit when the provider repeatedly fails.

## Original service inspector

The read-only inspector supports ping, status, settings, EventStream status, and
a combined snapshot:

```bash
reverse/original-ipc.mjs snapshot
```

Regenerate build-specific symbols, strings, entitlements, and IPC evidence:

```bash
reverse/extract-evidence.sh
```

The final controlled original comparison uses no personal content:

```bash
reverse/run-fixture-actions.sh
reverse/compare-event-streams.mjs \
  original-events.jsonl original-suppressed.jsonl \
  open-events.jsonl open-suppressed.jsonl
```

## Security

- Treat all recorded UI text as untrusted data. The summarizer explicitly
  rejects instructions found inside event content.
- Text and AX-tree fields are removed from MCP query results unless
  `includeText` is explicitly true.
- Local files can contain sensitive information. Protect the macOS account and
  use include-only policies for sensitive environments.
- Keep the MCP server bound locally unless you add authentication and deployment
  hardening. The event store is intentionally a local single-user design.

## Verification

Validated on August 14, 2026:

- Swift build and 12 Swift tests pass.
- TypeScript typecheck, 9 Node tests, MCP production build, and parity pass.
- `npm audit` reports zero known vulnerabilities.
- A real six-second recording produced 31 events across multiple desktop
  applications without screenshots.
- MCP discovery and status/recent/search tools passed through `mcp-use client`.
- The summarizer created a valid local Markdown memory through `codex exec`.
- Original-service IPC returned API version, status, settings, and the
  EventStream 1800-second maximum duration.
- Original-name MCP pause/resume/status/settings tools passed through a real MCP
  client, including launching the collector from stopped state.
- Segment rotation and pipeline bucket deduplication passed accelerated smoke
  tests.
- Browser URL and localized private-browsing suppression passed real smoke
  tests.
- Native wire compatibility passed by pointing the recovered original client at
  the open IPC server.
- The timeline View rendered in Widget-Declared CSP at desktop/mobile widths and
  completed app-private delete interaction.
- The ad-hoc signed `.app` passed strict `codesign` verification and launch
  smoke.
- A user-authorized original Fixture recording and the open recording passed
  the value-level event-stream comparator with zero differences.
- Original test history was cleared after the comparison.

## License

MIT. OpenAI and Codex are trademarks of OpenAI. This project is independent and
unofficial.
