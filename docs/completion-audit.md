# Completion audit

Date: August 14, 2026

Objective: produce a complete clean-room reverse engineering and open
implementation of Codex Computer History.

## Proven

| Area | Evidence | Status |
|---|---|---|
| Product split | Public docs and local binaries distinguish screenshot-based Chronicle from event-based Skysight | Proven |
| Native component | `SkyComputerUseService` build, bundle, entitlements, linked frameworks, running process, and socket inspected | Proven |
| IPC transport | Unix socket, 4-byte little-endian frames, JSON-RPC 2.0, 8 MiB limit, and API `CodexComputerUseIPC-2` verified against the running original | Proven |
| Read-only IPC | Original ping, Skysight status, settings, and EventStream status return successfully through `reverse/original-ipc.mjs` | Proven |
| Event schema | Swift constructor signatures recovered for record, app, window, mouse, keyboard, selection, AX tree, and diagnostic payloads | Proven |
| Event kinds | All 12 event discriminator strings recovered | Proven |
| Settings | Default behavior, rules, menu icon setting, and update operations recovered; defaults compared live | Proven |
| Recorder architecture | Frontmost app, AX observer, event tap, text/terminal buffers, URL cache, AX revision, suppression, and debounce state recovered | Proven |
| Storage | Segment paths, events, suppressed events, metadata fields, 48-hour retention, and memory resource paths recovered | Proven |
| Summarization | 10-minute and 6-hour task maps, isolated Codex configuration, output frontmatter, prompt-injection boundary, and failure modes recovered | Proven |
| MCP | Original five tool names and descriptions recovered; open tools pass a real MCP client lifecycle | Proven |
| Open event recorder | Real macOS recording verifies app/window changes, clicks, shortcuts, selections, browser URLs, AX full trees, and diffs | Proven |
| Original live event serialization | User-authorized synthetic Fixture recording compared event counts, nested fields, stable values, AX modes, and privacy behavior against the open recorder | Proven |
| Privacy | Real localized Chrome Incognito activity is routed to `suppressed.jsonl`; secure fields and private browser titles are filtered | Proven |
| Segment rotation | Accelerated multi-segment smoke verifies continuous event IDs and metadata | Proven |
| Pause/resume | CLI and MCP control verify running/paused/running/stopped; timed pause auto-resume verified | Proven |
| History clearing | Recent interval and application-session behavior covered in Swift and Node tests | Proven |
| Summary pipeline | UTC 10-minute/6-hour buckets, deduplication, lock, provider circuit, and fixture integration verified | Proven |
| Native open IPC | The recovered original protocol client connects unchanged to the open socket server | Proven |
| Timeline UI | MCP Apps View builds, renders in Widget-Declared CSP, has no horizontal overflow at 900px/375px, and delete confirmation works | Proven |
| Menu bar | SwiftUI `MenuBarExtra` builds without warnings and runs in an AppKit event loop | Proven |
| Packaging | Ad-hoc signed `Open Computer History.app` validates with `codesign` and launches | Proven |
| Local services | LaunchAgent install/uninstall scripts pass shell syntax validation; installation intentionally not executed without user request | Proven but not installed |
| Quality gates | Swift tests, Node tests, typecheck, MCP build, parity, npm audit, release build, and package dry-run pass | Proven |

## External implementation boundary

### Proprietary server-side memory model

The local client configuration and prompt contract are recovered. The
`openai-memgen` server implementation and model weights are not present on the
Mac and cannot be reverse engineered from the client bundle. The open version
reproduces the observable request configuration, safety boundary, output schema,
and scheduling behavior, not private server internals.

### Signing identity and App Group

The original uses OpenAI's Team ID and App Group. The open build intentionally
does not impersonate those identities. It uses an independent bundle ID,
ad-hoc signing, its own data root, and its own native socket while preserving
the recovered wire protocol.

## Completion decision

The user-authorized original live-event comparison completed with zero
comparator differences. Every locally observable requirement is backed by
static evidence, original IPC behavior, controlled original JSONL, open runtime
behavior, tests, or rendered UI verification.

The clean-room local reverse engineering and open implementation are complete.
OpenAI's remote model weights and private server implementation are external
services, not artifacts present in the desktop product bundle.
