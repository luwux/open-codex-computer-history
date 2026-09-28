# Recovered Computer History protocol

This document records directly verified protocol facts from
`SkyComputerUseService` build `26.804.1000633`.

## Native IPC transport

Socket:

```text
~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/
  IPC/computeruse.sock
```

Transport:

1. Serialize a JSON-RPC 2.0 message as UTF-8.
2. Prefix it with a four-byte little-endian unsigned payload length.
3. Send one framed request over the Unix socket.
4. Read the same length-prefixed framing for the response.

Maximum frame size in the bundled JavaScript client is 8 MiB.

Current API version:

```text
CodexComputerUseIPC-2
```

Ping:

```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "method": "ping",
  "params": {
    "clientApiVersion": "CodexComputerUseIPC-2"
  }
}
```

All service requests use:

```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "method": "request",
  "params": {
    "clientApiVersion": "CodexComputerUseIPC-2",
    "codexTurnMetadata": null,
    "deadlineUnixMilliseconds": 0,
    "requestType": "ComputerUseIPCSkysightStatusRequest",
    "request": {}
  }
}
```

The request type is the unqualified Swift request-struct name.

## Read-only request types

```text
ComputerUseIPCSkysightStatusRequest
ComputerUseIPCSkysightGetSettingsRequest
ComputerUseIPCEventStreamStatusRequest
```

The repository's [original-ipc.mjs](../reverse/original-ipc.mjs) intentionally
exposes only ping, status, settings, EventStream status, and a combined
read-only snapshot.

## Verified status response

When Computer History is disabled:

```json
{
  "state": "stopped",
  "eventStreamRootPath": "$TMPDIR/skysight"
}
```

The complete status type has:

```text
state
eventStreamRootPath
currentSegmentEventsPath
currentSegmentMetadataPath
suppressedEventsPath
startedAt
endedAt
```

Known state strings:

```text
stopped
running
paused
```

The separate EventStream service reports:

```json
{
  "isRecording": false,
  "maxDurationSeconds": 1800
}
```

## Verified settings response

```json
{
  "observation": {
    "defaultURLBehavior": "observe",
    "allowlist": [],
    "defaultApplicationBehavior": "observe",
    "blocklist": []
  },
  "showMenuBarIcon": true
}
```

Known default behaviors:

```text
observe
do_not_observe
```

Observation rules contain:

```text
scope
bundleID
urlDomain
```

Recovered observation update operations:

```text
replaceAll
changeDefaultApplicationBehavior
changeDefaultURLBehavior
includeApplication
excludeApplication
includeURL
excludeURL
```

Recovered suppression reasons:

```text
applicationExcluded
privateBrowsingExcluded
urlExcluded
urlPolicyBlocked
```

## Event JSON model

The original constructor is:

```text
EventStreamRecord(
  id,
  timestamp,
  kind,
  app,
  window,
  mouse,
  keyboard,
  selection,
  ax,
  diagnostic
)
```

Substructures:

```text
EventStreamApp(name, secureInput, processIdentifier, bundleIdentifier)
EventStreamWindow(title, url, windowID)
EventStreamAXElement(
  role, subrole, title, description, value, placeholder, identifier
)
EventStreamMouseInteraction(
  button, clickCount, modifiers, target, origin, destination
)
EventStreamMouseInteractionDragEndpoint(app, window, element)
EventStreamKeyboardInteraction(text, keyEquivalent, modifiers, target)
EventStreamSelection(target, selectedText, selectedRange, selectedItems)
EventStreamTextRange(location, length)
EventStreamAXTree(mode, text)
EventStreamDiagnostic(message)
```

AX tree modes:

```text
fullTree
diffFromPrevious
```

Event kinds:

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

This implementation adds four presence boundaries that the original recorder
does not emit. They are written even when the frontmost app is suppressed and
carry no app, window, or AX payload:

```text
system.screen_locked
system.screen_unlocked
system.will_sleep
system.did_wake
```

Idle time is not recorded as an event; it is the gap between events.

## Segment files

```text
$TMPDIR/skysight/segments/<segment>/
  events.jsonl
  metadata.json
```

Skysight counts suppressed events in metadata but does not persist their event
bodies. The generic EventStream writer supports an optional
`suppressed.jsonl`; the observed Computer History path does not create it.

Metadata fields:

```text
id
eventsPath
startedAt
endedAt
endReason
eventCount
suppressedEventCount
```

The memory pipeline maintains task maps keyed by `bucketStart` for:

```text
tenMinuteSummaryTasks
sixHourRollupTasks
```

The open implementation aligns summaries to completed UTC 10-minute and 6-hour
buckets and persists completed or empty bucket state.

## Pause and clear scopes

Recovered pause durations:

```text
thirtyMinutes
oneHour
untilTomorrow
```

Recovered clear-history scopes and wire strings:

```text
applicationSession
interval
lastTenMinutes
lastHour
today

application_session
interval
last_ten_minutes
last_hour
last_day
all
```

## Public Computer History MCP tools

The original MCP server exposes:

```text
computer_history_pause
computer_history_resume
computer_history_status
computer_history_get_settings
computer_history_update_settings
```

The update tool replaces the complete settings object. Its description requires
calling `computer_history_get_settings` first so unchanged fields are preserved.

## Reproduction

```bash
chmod +x reverse/extract-evidence.sh
reverse/extract-evidence.sh
```

Raw evidence is written under `reverse/evidence/` and intentionally ignored by
Git because it is build-specific and large.
