# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's private vulnerability
reporting feature. Do not open a public issue for a vulnerability that may
expose recorded content, local paths, credentials, or service details.

## Sensitive diagnostic data

Computer History event streams can contain window titles, URLs, selected text,
typed text, accessibility trees, application names, and other private context.

Do not attach any of the following to an issue, pull request, discussion, or
security report:

- `events.jsonl`, `suppressed.jsonl`, or complete event-stream excerpts
- files from `~/.open-codex-computer-history/`
- original-service captures or extracted local service evidence
- configuration files containing real include/exclude policies
- screenshots or logs that reveal private activity

Prefer a minimal synthetic reproduction created with the included Fixture App.
If a small event fragment is necessary, replace all content, paths, URLs,
application identifiers, and timestamps with synthetic values before sharing.

## Deployment boundary

The MCP server and event store are designed for a local, single-user macOS
environment. Do not expose the MCP endpoint to a network without adding
authentication, transport security, access control, and deployment hardening.

## Supported versions

Security fixes are applied to the latest release on the default branch.
