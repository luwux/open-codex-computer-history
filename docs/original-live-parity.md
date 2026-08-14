# Original live parity

Date: August 14, 2026

## Controlled setup

- OpenAI Computer History was explicitly enabled with user authorization.
- Original settings observed all applications and URLs with empty
  allowlist/blocklist and the menu-bar icon enabled.
- The signed `Open History Fixture.app` was the only source of synthetic test
  content.
- Inputs were limited to `synthetic note`, `synthetic secret`, Command-R, a
  radio selection, a button click, and one drag.
- The open recorder captured the same deterministic driver run.

## Original findings

The original event stream produced exactly one of each:

```text
window.changed
keyboard.text_input
keyboard.submit
selection.changed
keyboard.shortcut
mouse.click
mouse.drag
```

Verified encoding behavior:

- Normal app records omit `secureInput: false` and process identifiers.
- Window records omit internal window IDs.
- Empty modifier and selected-item arrays are omitted.
- Normal text input is persisted.
- Secure-field activity contributes only to `suppressedEventCount`; Skysight
  does not persist a `suppressed.jsonl`.
- `keyboard.text_input` and `selection.changed` omit AX payloads.
- Submit, shortcuts, clicks, drags, and window changes include AX payloads.
- Mouse click targets use the semantic role; drag endpoints include app,
  window, and semantic element context.

## Comparator result

After implementing the discovered differences,
`reverse/compare-event-streams.mjs` returned zero differences for:

- Event-kind counts.
- Top-level and nested field presence.
- Bundle ID, application name, and window title.
- Keyboard text, key equivalent, modifiers, and target.
- Selection text, range, and target.
- Mouse button, click count, target, and drag endpoints.
- AX mode and stable synthetic full-tree tokens.
- Suppressed-stream persistence behavior.

Dynamic IDs, timestamps, window-server IDs, and AX revision line numbers were
excluded by design.

## Cleanup and final state

- The original recorder was paused through the official Computer History MCP
  client.
- The official Clear Last Hour confirmation removed the complete bounded test
  recording. Computer History had been stopped before this test, so there was
  no older Computer History data in that interval.
- The test segments were removed.
- The original recorder was resumed through the official MCP client.
- Final authoritative status: `running`.
- Final observation settings: all applications and URLs observed, empty
  allowlist/blocklist, menu-bar icon enabled.
