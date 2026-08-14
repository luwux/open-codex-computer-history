# Reverse-engineering notes

Date: August 14, 2026

## Scope and method

This is a clean-room behavioral reconstruction. The investigation used:

- OpenAI's public Computer History documentation.
- Publicly observable UI behavior from the launch video.
- Bundle metadata, exported Swift symbols, resource names, localized strings,
  and plain-text prompt resources shipped in the locally installed ChatGPT app.
- Black-box recording and MCP smoke tests.

No code was copied from the proprietary executable, no protection was bypassed,
and no private endpoint or credential was used.

Inspected local build:

```text
ChatGPT.app: 26.803.61601
Codex Computer Use.app: 26.804.1000633
```

## Chronicle is not Computer History

The app still contains the old `codex_chronicle` sidecar. That component uses
ScreenCaptureKit, sparse screenshots, Vision OCR, and 10-minute/6-hour visual
summaries.

The released Computer History system is a separate rebuild internally named
Skysight. Public documentation explicitly says the new system uses interaction
events and does not require Screen Recording.

## Recovered component boundary

Skysight is packaged inside:

```text
ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/
  Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
```

Important exported types and symbols include:

```text
EventStreamRecorder
EventStreamJSONLWriter
EventStreamURLPolicyRecordFilter
SkysightSegmentWriter
SkysightMemoryPipeline
SkysightCodexExecSummariser
SkysightService
ComputerHistoryMCPServer
SystemFrontmostApplicationTracker
SystemFocusedUIElementObserver
AXNotificationObserver
EventTap
UIRecorder
```

The service links Accessibility, AXObserver, CGEvent, and frontmost-app
tracking. Its entitlements include an App Group shared with the desktop app.

## Recovered recorder state

The recorder stores state corresponding to:

```text
currentAppPID
frontmostAppObserver
axObserver
previousWindowRevision
previousWindowRevisionWindowID
latestURLByWindowID
mouseDown
textBuffer
textFlushTask
terminalValueChangedBuffer
pendingAXNotificationRecords
axNotificationDebounceTasks
```

This indicates an event-driven recorder with buffered typing/terminal updates,
AX-tree revisions, browser URL state keyed by window, and notification
debouncing.

## Recovered event names

The shipped binary exposes these event discriminators:

```text
session.started
session.ended
window.changed
mouse.click
mouse.context_menu
mouse.drag
keyboard.text_input
keyboard.submit
keyboard.shortcut
terminal.value_changed
selection.changed
debug.error
```

Observed payload keys include:

```text
secureInput
bundleIdentifier
button
clickCount
modifiers
target
origin
destination
keyEquivalent
selectedText
selectedRange
selectedItems
fullTree
diffFromPrevious
sessionID
segmentID
eventsPath
endedAt
endReason
eventCount
suppressedEventCount
```

The open implementation preserves this vocabulary where practical.

The exact nested constructors, IPC framing, current API version, read-only
request types, status, and settings are documented in
`docs/recovered-protocol.md`.

## Storage

The proprietary service describes:

```text
$TMPDIR/skysight/segments/<segment_timestamp>/
  events.jsonl
  metadata.json
```

Additional symbols reveal a separate `suppressed.jsonl` writer. Public
documentation says temporary event files are retained for up to 48 hours.

Generated memory resources use:

```text
~/.codex/memories/extensions/skysight/resources/
```

The open implementation uses an isolated default:

```text
~/.open-codex-computer-history/
```

## Summarization

The bundled memory pipeline has:

- 10-minute summary tasks.
- 6-hour rollup tasks.
- A dedicated `openai-memgen` provider configuration.
- Web search, plugins, apps, multi-agent, tool search, and telemetry disabled.
- Medium reasoning effort.
- A prompt-injection boundary treating every observed event as untrusted.

The generated memory frontmatter contains:

```yaml
title: ...
description: ...
applications: [bundle.identifiers]
suggestion:
  type: skill | automation
  name: ...
  description: ...
```

The body separates a compact memory, relevant prior context, non-obvious user
context, detailed recording summary, and local citations.

The open implementation uses a shorter independently written prompt with the
same security boundary and output contract.

## MCP and workflow suggestions

Exported symbols show both `ComputerHistoryMCPServer` and
`EventStreamMCPServer`. The desktop UI can create skills and automations by
passing the generated memory path and referenced `events.jsonl` files back to
Codex.

This suggests the intended retrieval pattern:

1. Search compact memories first.
2. Read only the relevant raw segment when more detail is needed.
3. Upgrade to a connector or dedicated tool for the authoritative source.
4. Use Computer Use only for unsupported UI actions or visual verification.

## Privacy controls

Recovered policy operations include:

```text
replace_all
change_default_application_behavior
change_default_url_behavior
include_url
exclude_url
```

The product supports include-only and exclude-listed behavior independently for
applications and URL domains. Private browsing and secure input are suppressed.
History can be cleared by interval, last 10 minutes, last hour, last day, app
session, or all.

## Implemented open counterpart

The open implementation now includes:

- Nested recovered event records and rotating segments.
- Full AX window traversal with revision diffs and removed-ID ranges.
- Browser URL extraction, per-window URL continuity, and localized private-mode
  filtering.
- AX notification debouncing plus text and terminal coalescing.
- Original-shape settings, pause/resume including timed pauses, clear scopes,
  and recent application-session reconstruction.
- UTC-aligned 10-minute and 6-hour summary pipeline.
- Original-name MCP tools, a native compatible Unix-socket IPC server, a
  timeline MCP View, and a SwiftUI menu-bar executable.
- An ad-hoc signed local `.app` plus opt-in LaunchAgent installation scripts.

The exact remaining evidence boundary is maintained in
`docs/completion-audit.md`.
