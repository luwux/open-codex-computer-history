# Contributing

Contributions are welcome. Please keep the project clean-room, local-first, and
privacy-preserving.

## Development setup

Requirements:

- macOS 14 or newer
- Swift 5.10 or newer
- Node.js 22.22 or newer

Install dependencies and run the standard checks:

```bash
npm ci
npm run typecheck
npm test
npm run build
swift test --package-path collector
```

The parity command requires a locally installed original service and is not
part of CI.

## Pull requests

- Keep changes focused and include tests for behavioral changes.
- Preserve the observable protocol unless the change documents an intentional
  compatibility difference.
- Use only synthetic Fixture App data in tests, examples, and bug reports.
- Never commit event streams, local history databases, credentials, extracted
  proprietary artifacts, signing assets, or user-specific absolute paths.
- Do not include OpenAI source code or claim affiliation with OpenAI.

Before submitting, inspect the complete diff and run the standard checks above.
See `SECURITY.md` before sharing diagnostics.
